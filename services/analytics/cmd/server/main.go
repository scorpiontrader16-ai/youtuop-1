package main

import (
    "context"
    "encoding/json"
    "log/slog"
    "net"
    "net/http"
    "os"
    "os/signal"
    "syscall"
    "time"

    "github.com/jackc/pgx/v5"
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
    "github.com/prometheus/client_golang/prometheus/promhttp"
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.21.0"
    "google.golang.org/grpc"
    "google.golang.org/grpc/health/grpc_health_v1"
)

var version = "dev"

// Prometheus metrics
var (
    httpRequestsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "analytics_http_requests_total",
            Help: "Total number of HTTP requests",
        },
        []string{"method", "path", "status"},
    )
    httpRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "analytics_http_request_duration_seconds",
            Help:    "HTTP request duration in seconds",
            Buckets: prometheus.DefBuckets,
        },
        []string{"method", "path"},
    )
)

type Event struct {
    UserID     string                 `json:"user_id"`
    SessionID  string                 `json:"session_id,omitempty"`
    EventType  string                 `json:"event_type"`
    EventName  string                 `json:"event_name"`
    Properties map[string]interface{} `json:"properties,omitempty"`
    Timestamp  time.Time              `json:"timestamp,omitempty"`
}

func main() {
    logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
    slog.SetDefault(logger)

    shutdown, err := initTracer()
    if err != nil {
        slog.Error("failed to init tracer", "error", err)
    }
    defer shutdown(context.Background())

    pgConn := os.Getenv("POSTGRES_CONN")
    if pgConn == "" {
        pgConn = "postgres://postgres:postgres@postgres.platform.svc.cluster.local:5432/platform?sslmode=disable"
    }
    pg, err := pgx.Connect(context.Background(), pgConn)
    if err != nil {
        slog.Error("failed to connect postgres", "error", err)
        os.Exit(1)
    }
    defer pg.Close(context.Background())

    mux := http.NewServeMux()

    // Health checks
    mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusOK)
        w.Write([]byte("ok"))
    })
    mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
        if err := pg.Ping(context.Background()); err != nil {
            w.WriteHeader(http.StatusServiceUnavailable)
            w.Write([]byte("postgres not ready"))
            return
        }
        w.WriteHeader(http.StatusOK)
        w.Write([]byte("ready"))
    })

    // Track event endpoint
    mux.HandleFunc("POST /api/v1/analytics/track", func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        tenantID := r.Header.Get("X-Tenant-ID")
        if tenantID == "" {
            httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, "400").Inc()
            http.Error(w, "missing tenant id", http.StatusBadRequest)
            return
        }

        var ev Event
        if err := json.NewDecoder(r.Body).Decode(&ev); err != nil {
            httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, "400").Inc()
            http.Error(w, "invalid request", http.StatusBadRequest)
            return
        }
        if ev.Timestamp.IsZero() {
            ev.Timestamp = time.Now().UTC()
        }

        ip := r.Header.Get("X-Forwarded-For")
        if ip == "" {
            ip = r.RemoteAddr
        }
        ua := r.UserAgent()

        _, err := pg.Exec(r.Context(),
            `INSERT INTO analytics_events (tenant_id, user_id, session_id, event_type, event_name, properties, timestamp, ip_address, user_agent)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
            tenantID, ev.UserID, ev.SessionID, ev.EventType, ev.EventName, ev.Properties, ev.Timestamp, ip, ua,
        )
        if err != nil {
            slog.Error("failed to record event", "error", err)
            httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, "500").Inc()
            http.Error(w, "failed to record event", http.StatusInternalServerError)
            return
        }

        duration := time.Since(start).Seconds()
        httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)
        httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, "202").Inc()

        w.WriteHeader(http.StatusAccepted)
        json.NewEncoder(w).Encode(map[string]string{"status": "tracked"})
    })

    // Metrics endpoint
    mux.Handle("GET /metrics", promhttp.Handler())

    // Wrap with otel
    handler := otelhttp.NewHandler(mux, "analytics-http")

    httpPort := os.Getenv("HTTP_PORT")
    if httpPort == "" {
        httpPort = "9096"
    }
    httpSrv := &http.Server{
        Addr:    ":" + httpPort,
        Handler: handler,
    }

    grpcPort := os.Getenv("GRPC_PORT")
    if grpcPort == "" {
        grpcPort = "8096"
    }
    grpcSrv := grpc.NewServer()
    grpc_health_v1.RegisterHealthServer(grpcSrv, &healthServer{})

    go func() {
        slog.Info("starting HTTP server", "port", httpPort)
        if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
            slog.Error("http server error", "error", err)
        }
    }()
    go func() {
        slog.Info("starting gRPC server", "port", grpcPort)
        lis, err := net.Listen("tcp", ":"+grpcPort)
        if err != nil {
            slog.Error("grpc listen error", "error", err)
            return
        }
        if err := grpcSrv.Serve(lis); err != nil {
            slog.Error("grpc server error", "error", err)
        }
    }()

    quit := make(chan os.Signal, 1)
    signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
    <-quit
    slog.Info("shutting down servers...")
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    httpSrv.Shutdown(ctx)
    grpcSrv.GracefulStop()
    slog.Info("shutdown complete")
}

func initTracer() (func(context.Context) error, error) {
    endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if endpoint == "" {
        return func(context.Context) error { return nil }, nil
    }

    ctx := context.Background()
    exporter, err := otlptracegrpc.New(ctx,
        otlptracegrpc.WithEndpoint(endpoint),
        otlptracegrpc.WithInsecure(),
    )
    if err != nil {
        return nil, err
    }

    res, err := resource.New(ctx,
        resource.WithAttributes(
            semconv.ServiceName("analytics"),
            semconv.ServiceVersion(version),
        ),
        resource.WithFromEnv(),
        resource.WithTelemetrySDK(),
    )
    if err != nil {
        return nil, err
    }

    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter),
        sdktrace.WithResource(res),
    )
    otel.SetTracerProvider(tp)
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{},
        propagation.Baggage{},
    ))

    return tp.Shutdown, nil
}

type healthServer struct {
    grpc_health_v1.UnimplementedHealthServer
}

func (s *healthServer) Check(ctx context.Context, req *grpc_health_v1.HealthCheckRequest) (*grpc_health_v1.HealthCheckResponse, error) {
    return &grpc_health_v1.HealthCheckResponse{Status: grpc_health_v1.HealthCheckResponse_SERVING}, nil
}

func (s *healthServer) Watch(req *grpc_health_v1.HealthCheckRequest, stream grpc_health_v1.Health_WatchServer) error {
    return stream.Send(&grpc_health_v1.HealthCheckResponse{Status: grpc_health_v1.HealthCheckResponse_SERVING})
}
