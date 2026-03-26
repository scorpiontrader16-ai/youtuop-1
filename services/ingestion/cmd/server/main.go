// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  المسار الكامل: services/ingestion/cmd/server/main.go                   ║
// ║  الحالة: ✏️ معدل — إصلاح import: إزالة pb schema، استخدام kafka.FeatureEvent ║
// ╚══════════════════════════════════════════════════════════════════════════╝

package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/sony/gobreaker"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.uber.org/zap"
	"golang.org/x/time/rate"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/health"
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"

	chwriter      "github.com/aminpola2001-ctrl/youtuop/services/ingestion/internal/clickhouse"
	"github.com/aminpola2001-ctrl/youtuop/services/ingestion/internal/coldstore"
	kafkaclient   "github.com/aminpola2001-ctrl/youtuop/services/ingestion/internal/kafka"
	"github.com/aminpola2001-ctrl/youtuop/services/ingestion/internal/postgres"
	"github.com/aminpola2001-ctrl/youtuop/services/ingestion/internal/tiering"
)

var version = "dev"

// ── Prometheus Metrics ────────────────────────────────────────────────────

var (
	httpRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "ingestion_http_requests_total",
		Help: "Total number of HTTP requests",
	}, []string{"method", "path", "status"})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "ingestion_http_request_duration_seconds",
		Help:    "HTTP request duration in seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "path"})

	grpcRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "ingestion_grpc_requests_total",
		Help: "Total number of gRPC requests",
	}, []string{"method", "status"})

	eventsProcessedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ingestion_events_processed_total",
		Help: "Total number of events processed",
	})

	eventsDroppedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ingestion_events_dropped_total",
		Help: "Total number of events dropped (buffer full)",
	})

	circuitBreakerState = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "ingestion_circuit_breaker_state",
		Help: "Circuit breaker state: 0=closed, 1=half-open, 2=open",
	}, []string{"name"})

	rateLimitRejectedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ingestion_rate_limit_rejected_total",
		Help: "Total number of requests rejected by rate limiter",
	})

	tenantMissingTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ingestion_tenant_missing_total",
		Help: "Total number of requests rejected due to missing tenant_id",
	})

	featureEventsSentTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ingestion_feature_events_sent_total",
		Help: "Total number of feature events sent to ML pipeline",
	})

	featureEventsFailedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ingestion_feature_events_failed_total",
		Help: "Total number of feature events failed to send to ML pipeline",
	})
)

// ── Circuit Breakers ──────────────────────────────────────────────────────

func newCircuitBreaker(name string, log *zap.Logger) *gobreaker.CircuitBreaker {
	return gobreaker.NewCircuitBreaker(gobreaker.Settings{
		Name:        name,
		MaxRequests: 5,
		Interval:    10 * time.Second,
		Timeout:     30 * time.Second,
		ReadyToTrip: func(counts gobreaker.Counts) bool {
			return counts.ConsecutiveFailures >= 5
		},
		OnStateChange: func(name string, from, to gobreaker.State) {
			log.Warn("circuit breaker state changed",
				zap.String("name", name),
				zap.String("from", from.String()),
				zap.String("to", to.String()),
			)
			switch to {
			case gobreaker.StateClosed:
				circuitBreakerState.WithLabelValues(name).Set(0)
			case gobreaker.StateHalfOpen:
				circuitBreakerState.WithLabelValues(name).Set(1)
			case gobreaker.StateOpen:
				circuitBreakerState.WithLabelValues(name).Set(2)
			}
		},
	})
}

var ErrRateLimited   = status.Error(codes.ResourceExhausted, "rate limit exceeded, try again later")
var ErrMissingTenant = status.Error(codes.InvalidArgument, "x-tenant-id metadata is required")

func main() {
	log, err := zap.NewProduction()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to init logger: %v\n", err)
		os.Exit(1)
	}
	defer log.Sync()

	log.Info("starting ingestion service", zap.String("version", version))

	cfg, err := loadConfig()
	if err != nil {
		log.Fatal("invalid config", zap.Error(err))
	}

	// ── OpenTelemetry ─────────────────────────────────────────────────────
	tp, err := initTracer(cfg.OTLPEndpoint)
	if err != nil {
		log.Fatal("failed to init tracer", zap.Error(err))
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		tp.Shutdown(ctx)
	}()
	otel.SetTracerProvider(tp)

	slogLogger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	startupCtx, startupCancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer startupCancel()

	// ── ClickHouse ────────────────────────────────────────────────────────
	chConn, err := chwriter.WaitForClickHouse(startupCtx, chwriter.ConfigFromEnv(), slogLogger)
	if err != nil {
		log.Warn("clickhouse unavailable — hot store disabled", zap.Error(err))
	}

	var bufWriter *chwriter.BufferedWriter
	if chConn != nil {
		defer chConn.Close()
		bufWriter = chwriter.NewBufferedWriter(chConn, chwriter.DefaultBufferConfig(), slogLogger)
		defer bufWriter.Close()
		log.Info("clickhouse hot store ready")
	}

	// ── Postgres ──────────────────────────────────────────────────────────
	pgClient, err := postgres.WaitForPostgres(startupCtx, postgres.ConfigFromEnv(), slogLogger)
	if err != nil {
		log.Warn("postgres unavailable — warm store disabled", zap.Error(err))
	}

	if pgClient != nil {
		defer pgClient.Close()
		if migrateErr := pgClient.Migrate(startupCtx); migrateErr != nil {
			log.Warn("postgres migrations failed", zap.Error(migrateErr))
		} else {
			log.Info("postgres warm store ready")
		}
	}

	// ── Cold Store ────────────────────────────────────────────────────────
	coldWriter, err := coldstore.WaitForColdStore(startupCtx, coldstore.ConfigFromEnv(), slogLogger)
	if err != nil {
		log.Warn("coldstore unavailable — cold archival disabled", zap.Error(err))
	} else {
		log.Info("coldstore (minio) ready")
	}

	// ── Tiering Job ───────────────────────────────────────────────────────
	tieringCtx, tieringCancel := context.WithCancel(context.Background())

	if pgClient != nil && coldWriter != nil {
		tj := tiering.New(pgClient, coldWriter, tiering.DefaultConfig(), slogLogger)
		go tj.Run(tieringCtx)
		log.Info("tiering job started (warm → cold)")
	} else {
		log.Warn("tiering job disabled — postgres or coldstore unavailable")
	}

	// ── Circuit Breakers ──────────────────────────────────────────────────
	redpandaCB   := newCircuitBreaker("redpanda", log)
	processingCB := newCircuitBreaker("processing-grpc", log)

	limiter := rate.NewLimiter(1000, 100)

	// ── Feature Producer (ML Streaming) ───────────────────────────────────
	featureProducer := kafkaclient.NewFeatureProducer(
		strings.Split(cfg.RedpandaBrokers, ","),
		"feature-events",
		log,
	)
	defer featureProducer.Close()

	// ── gRPC Server ───────────────────────────────────────────────────────
	grpcServer := grpc.NewServer(
		grpc.KeepaliveParams(keepalive.ServerParameters{
			MaxConnectionIdle: 5 * time.Minute,
			Time:              2 * time.Hour,
			Timeout:           20 * time.Second,
		}),
		grpc.StatsHandler(otelgrpc.NewServerHandler()),
		grpc.MaxRecvMsgSize(16*1024*1024),
		grpc.ChainUnaryInterceptor(
			tenantInterceptor(log),
			rateLimitInterceptor(limiter, log),
		),
	)

	healthSrv := health.NewServer()
	grpc_health_v1.RegisterHealthServer(grpcServer, healthSrv)
	healthSrv.SetServingStatus("", grpc_health_v1.HealthCheckResponse_SERVING)
	reflection.Register(grpcServer)

	// ── HTTP Routes ───────────────────────────────────────────────────────
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()

		type check struct {
			name string
			addr string
			cb   *gobreaker.CircuitBreaker
		}

		checks := []check{
			{"redpanda",        cfg.RedpandaBrokers, redpandaCB},
			{"processing-grpc", cfg.ProcessingAddr,  processingCB},
		}

		for _, c := range checks {
			_, cbErr := c.cb.Execute(func() (interface{}, error) {
				return nil, dialTCP(ctx, c.addr)
			})
			if cbErr != nil {
				if cbErr == gobreaker.ErrOpenState {
					http.Error(w, fmt.Sprintf("%s: upstream not reachable", c.name),
						http.StatusServiceUnavailable)
					return
				}
				http.Error(w, fmt.Sprintf("%s not ready: %v", c.name, cbErr),
					http.StatusServiceUnavailable)
				return
			}
		}

		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ready")
	})

	// ── Tenant RLS Middleware ─────────────────────────────────────────────
	tenantPGMiddleware := func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			tenantID := r.Header.Get("X-Tenant-ID")
			if tenantID != "" && pgClient != nil {
				_, err := pgClient.DB().ExecContext(r.Context(),
					"SELECT set_config('app.tenant_id', $1, false)", tenantID)
				if err != nil {
					slog.Error("set tenant_id session", "error", err)
				}
			}
			next.ServeHTTP(w, r)
		})
	}

	// ── Events Endpoint (Hot Path) ────────────────────────────────────────
	mux.Handle("/v1/events", tenantPGMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		const path = "/v1/events"
		defer func() {
			httpRequestDuration.WithLabelValues(r.Method, path).
				Observe(time.Since(start).Seconds())
		}()

		if r.Method != http.MethodPost {
			httpRequestsTotal.WithLabelValues(r.Method, path, "405").Inc()
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		if !limiter.Allow() {
			rateLimitRejectedTotal.Inc()
			httpRequestsTotal.WithLabelValues(r.Method, path, "429").Inc()
			http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
			return
		}

		tenantID := r.Header.Get("X-Tenant-ID")
		if tenantID == "" {
			tenantMissingTotal.Inc()
			httpRequestsTotal.WithLabelValues(r.Method, path, "400").Inc()
			http.Error(w, "X-Tenant-ID header is required", http.StatusBadRequest)
			return
		}

		eventID := fmt.Sprintf("evt-%d", time.Now().UnixNano())
		now := time.Now().UTC()

		// ── كتابة في ClickHouse (Hot — non-blocking) ─────────────────────
		if bufWriter != nil {
			var payloadBytes uint32
			if r.ContentLength > 0 {
				payloadBytes = uint32(r.ContentLength)
			}
			row := chwriter.EventRow{
				EventID:       eventID,
				EventType:     r.Header.Get("X-Event-Type"),
				Source:        r.Header.Get("X-Event-Source"),
				SchemaVersion: r.Header.Get("X-Schema-Version"),
				OccurredAt:    now,
				IngestedAt:    now,
				TenantID:      tenantID,
				PartitionKey:  r.Header.Get("X-Partition-Key"),
				ContentType:   r.Header.Get("Content-Type"),
				Payload:       "",
				PayloadBytes:  payloadBytes,
				TraceID:       r.Header.Get("X-Trace-ID"),
				SpanID:        r.Header.Get("X-Span-ID"),
				MetaKeys:      []string{},
				MetaValues:    []string{},
			}
			if !bufWriter.Enqueue(row) {
				eventsDroppedTotal.Inc()
			}
		}

		eventsProcessedTotal.Inc()

		// ── ML Streaming — non-blocking goroutine ─────────────────────────
		// المتغيرات تُنسخ بالقيمة قبل إطلاق الـ goroutine — لا race conditions
		go func(eID, tID, srcType string, ts int64) {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()

			evt := &kafkaclient.FeatureEvent{
				EventID:    eID,
				TenantID:   tID,
				SourceType: srcType,
				OccurredAt: ts,
			}

			if sendErr := featureProducer.SendFeatureEvent(ctx, evt); sendErr != nil {
				featureEventsFailedTotal.Inc()
				log.Warn("feature event send failed",
					zap.String("event_id", eID),
					zap.String("tenant_id", tID),
					zap.Error(sendErr),
				)
				return
			}
			featureEventsSentTotal.Inc()
		}(eventID, tenantID, r.Header.Get("X-Event-Type"), now.UnixMilli())

		httpRequestsTotal.WithLabelValues(r.Method, path, "200").Inc()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{"event_id":%q,"tenant_id":%q,"accepted":true}`, eventID, tenantID)
	})))

	httpServer := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.HTTPPort),
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", cfg.GRPCPort))
	if err != nil {
		log.Fatal("failed to listen", zap.Error(err))
	}

	go func() {
		log.Info("gRPC server started", zap.Int("port", cfg.GRPCPort))
		if serveErr := grpcServer.Serve(lis); serveErr != nil {
			log.Fatal("gRPC server failed", zap.Error(serveErr))
		}
	}()

	go func() {
		log.Info("HTTP server started", zap.Int("port", cfg.HTTPPort))
		if serveErr := httpServer.ListenAndServe(); serveErr != http.ErrServerClosed {
			log.Fatal("HTTP server failed", zap.Error(serveErr))
		}
	}()

	// ── Graceful Shutdown ─────────────────────────────────────────────────
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	sig := <-quit

	log.Info("shutting down gracefully...", zap.String("signal", sig.String()))

	tieringCancel()

	shutCtx, shutCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutCancel()

	healthSrv.SetServingStatus("", grpc_health_v1.HealthCheckResponse_NOT_SERVING)
	grpcServer.GracefulStop()

	if shutErr := httpServer.Shutdown(shutCtx); shutErr != nil {
		log.Error("HTTP shutdown error", zap.Error(shutErr))
	}

	// featureProducer.Close() يُستدعى تلقائياً عبر defer
	log.Info("shutdown complete")
}

// ── Tenant Interceptor ────────────────────────────────────────────────────

func tenantInterceptor(log *zap.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler) (interface{}, error) {
		md, ok := metadata.FromIncomingContext(ctx)
		if !ok {
			tenantMissingTotal.Inc()
			return nil, ErrMissingTenant
		}
		vals := md.Get("x-tenant-id")
		if len(vals) == 0 || vals[0] == "" {
			tenantMissingTotal.Inc()
			log.Warn("gRPC call missing x-tenant-id", zap.String("method", info.FullMethod))
			return nil, ErrMissingTenant
		}
		ctx = context.WithValue(ctx, contextKeyTenantID{}, vals[0])
		return handler(ctx, req)
	}
}

type contextKeyTenantID struct{}

func TenantIDFromContext(ctx context.Context) (string, bool) {
	v, ok := ctx.Value(contextKeyTenantID{}).(string)
	return v, ok && v != ""
}

// ── Rate Limit Interceptor ────────────────────────────────────────────────

func rateLimitInterceptor(limiter *rate.Limiter, log *zap.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler) (interface{}, error) {
		if !limiter.Allow() {
			rateLimitRejectedTotal.Inc()
			log.Warn("gRPC rate limit exceeded", zap.String("method", info.FullMethod))
			return nil, ErrRateLimited
		}
		resp, err := handler(ctx, req)
		if err != nil {
			grpcRequestsTotal.WithLabelValues(info.FullMethod, status.Code(err).String()).Inc()
		} else {
			grpcRequestsTotal.WithLabelValues(info.FullMethod, codes.OK.String()).Inc()
		}
		return resp, err
	}
}

// ── Helpers ───────────────────────────────────────────────────────────────

func dialTCP(ctx context.Context, addr string) error {
	d := &net.Dialer{}
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return err
	}
	conn.Close()
	return nil
}

// ── Config ────────────────────────────────────────────────────────────────

type Config struct {
	GRPCPort        int
	HTTPPort        int
	OTLPEndpoint    string
	RedpandaBrokers string
	ProcessingAddr  string
}

func loadConfig() (Config, error) {
	grpcPort, err := getEnvInt("GRPC_PORT", 8090)
	if err != nil {
		return Config{}, fmt.Errorf("GRPC_PORT: %w", err)
	}
	httpPort, err := getEnvInt("HTTP_PORT", 9091)
	if err != nil {
		return Config{}, fmt.Errorf("HTTP_PORT: %w", err)
	}
	return Config{
		GRPCPort:        grpcPort,
		HTTPPort:        httpPort,
		OTLPEndpoint:    getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317"),
		RedpandaBrokers: getEnv("REDPANDA_BROKERS", "redpanda:9092"),
		ProcessingAddr:  getEnv("PROCESSING_ADDR", "processing:50051"),
	}, nil
}

func initTracer(endpoint string) (*sdktrace.TracerProvider, error) {
	exp, err := otlptracegrpc.New(
		context.Background(),
		otlptracegrpc.WithEndpoint(endpoint),
		otlptracegrpc.WithInsecure(),
	)
	if err != nil {
		return nil, err
	}
	return sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	), nil
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getEnvInt(key string, fallback int) (int, error) {
	v := os.Getenv(key)
	if v == "" {
		return fallback, nil
	}
	i, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("invalid value %q for %s: must be integer", v, key)
	}
	return i, nil
}
