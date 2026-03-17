package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
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
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"
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

	circuitBreakerState = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "ingestion_circuit_breaker_state",
		Help: "Circuit breaker state: 0=closed, 1=half-open, 2=open",
	}, []string{"name"})

	rateLimitRejectedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ingestion_rate_limit_rejected_total",
		Help: "Total number of requests rejected by rate limiter",
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

// ── Structured Errors ─────────────────────────────────────────────────────

var (
	ErrRateLimited    = status.Error(codes.ResourceExhausted, "rate limit exceeded, try again later")
	ErrCircuitOpen    = status.Error(codes.Unavailable, "service temporarily unavailable, circuit open")
	// Reserved for upstream and payload errors — used by future handlers
	ErrUpstreamDown   = status.Error(codes.Unavailable, "upstream dependency not reachable")   //nolint:unused
	ErrInvalidPayload = status.Error(codes.InvalidArgument, "invalid request payload")         //nolint:unused
)

func main() {
	log, err := zap.NewProduction()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to init logger: %v\n", err)
		os.Exit(1)
	}
	defer log.Sync() //nolint:errcheck

	log.Info("starting ingestion service", zap.String("version", version))

	cfg, err := loadConfig()
	if err != nil {
		log.Fatal("invalid config", zap.Error(err))
	}

	tp, err := initTracer(cfg.OTLPEndpoint)
	if err != nil {
		log.Fatal("failed to init tracer", zap.Error(err))
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		tp.Shutdown(ctx) //nolint:errcheck
	}()
	otel.SetTracerProvider(tp)

	// Circuit breakers
	redpandaCB := newCircuitBreaker("redpanda", log)
	processingCB := newCircuitBreaker("processing-grpc", log)

	// Rate limiter: 1000 req/s with burst of 100
	limiter := rate.NewLimiter(1000, 100)

	grpcServer := grpc.NewServer(
		grpc.KeepaliveParams(keepalive.ServerParameters{
			MaxConnectionIdle: 5 * time.Minute,
			Time:              2 * time.Hour,
			Timeout:           20 * time.Second,
		}),
		grpc.StatsHandler(otelgrpc.NewServerHandler()),
		grpc.MaxRecvMsgSize(16*1024*1024),
		grpc.ChainUnaryInterceptor(
			rateLimitInterceptor(limiter, log),
		),
	)

	healthSrv := health.NewServer()
	grpc_health_v1.RegisterHealthServer(grpcServer, healthSrv)
	healthSrv.SetServingStatus("", grpc_health_v1.HealthCheckResponse_SERVING)
	reflection.Register(grpcServer)

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())

	// ── Liveness ──────────────────────────────────────────────────────────
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	// ── Readiness ─────────────────────────────────────────────────────────
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()

		type check struct {
			name string
			addr string
			cb   *gobreaker.CircuitBreaker
		}

		checks := []check{
			{"redpanda", cfg.RedpandaBrokers, redpandaCB},
			{"processing-grpc", cfg.ProcessingAddr, processingCB},
		}

		for _, c := range checks {
			_, cbErr := c.cb.Execute(func() (interface{}, error) {
				return nil, dialTCP(ctx, c.addr)
			})
			if cbErr != nil {
				if cbErr == gobreaker.ErrOpenState {
					http.Error(w,
						fmt.Sprintf("%s circuit open", c.name),
						http.StatusServiceUnavailable,
					)
					return
				}
				http.Error(w,
					fmt.Sprintf("%s not ready: %v", c.name, cbErr),
					http.StatusServiceUnavailable,
				)
				return
			}
		}

		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ready")
	})

	// ── Events endpoint with rate limiting + metrics ───────────────────────
	mux.HandleFunc("/v1/events", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		path := "/v1/events"
		defer func() {
			httpRequestDuration.WithLabelValues(r.Method, path).Observe(time.Since(start).Seconds())
		}()

		if r.Method != http.MethodPost {
			httpRequestsTotal.WithLabelValues(r.Method, path, "405").Inc()
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		// Rate limiting
		if !limiter.Allow() {
			rateLimitRejectedTotal.Inc()
			httpRequestsTotal.WithLabelValues(r.Method, path, "429").Inc()
			http.Error(w, ErrRateLimited.Error(), http.StatusTooManyRequests)
			return
		}

		eventsProcessedTotal.Inc()
		httpRequestsTotal.WithLabelValues(r.Method, path, "200").Inc()

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{"event_id":"evt-%d","accepted":true}`, time.Now().UnixNano())
	})

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

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Info("shutting down gracefully...")
	shutCtx, shutCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutCancel()

	healthSrv.SetServingStatus("", grpc_health_v1.HealthCheckResponse_NOT_SERVING)
	grpcServer.GracefulStop()
	if shutErr := httpServer.Shutdown(shutCtx); shutErr != nil {
		log.Error("HTTP shutdown error", zap.Error(shutErr))
	}
	log.Info("shutdown complete")
}

// ── Rate Limit Interceptor ────────────────────────────────────────────────

func rateLimitInterceptor(limiter *rate.Limiter, log *zap.Logger) grpc.UnaryServerInterceptor {
	return func(
		ctx context.Context,
		req interface{},
		info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (interface{}, error) {
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
	grpcPort, err := getEnvInt("GRPC_PORT", 8080)
	if err != nil {
		return Config{}, fmt.Errorf("GRPC_PORT: %w", err)
	}
	httpPort, err := getEnvInt("HTTP_PORT", 9090)
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
