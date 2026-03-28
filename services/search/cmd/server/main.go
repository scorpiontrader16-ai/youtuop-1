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

    "github.com/elastic/go-elasticsearch/v8"
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

    "github.com/scorpiontrader16-ai/youtuop-1/services/search/internal/elastic"
    "github.com/scorpiontrader16-ai/youtuop-1/services/search/internal/postgres"
)

var version = "dev"

// Prometheus metrics
var (
    httpRequestsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "search_http_requests_total",
            Help: "Total number of HTTP requests",
        },
        []string{"method", "path", "status"},
    )
    httpRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "search_http_request_duration_seconds",
            Help:    "HTTP request duration in seconds",
            Buckets: prometheus.DefBuckets,
        },
        []string{"method", "path"},
    )
)

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
    pgClient, err := postgres.NewClient(context.Background(), pgConn)
    if err != nil {
        slog.Error("failed to connect postgres", "error", err)
        os.Exit(1)
    }
    defer pgClient.Close()

    esURL := os.Getenv("ELASTICSEARCH_URL")
    if esURL == "" {
        esURL = "http://elasticsearch.monitoring.svc.cluster.local:9200"
    }
    esCfg := elasticsearch.Config{
        Addresses: []string{esURL},
    }
    esClient, err := elastic.NewClient(esCfg)
    if err != nil {
        slog.Error("failed to connect elasticsearch", "error", err)
        os.Exit(1)
    }

    mux := http.NewServeMux()

    mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusOK)
        w.Write([]byte("ok"))
    })

    mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
        if err := pgClient.Pool().Ping(context.Background()); err != nil {
            w.WriteHeader(http.StatusServiceUnavailable)
            w.Write([]byte("postgres not ready"))
            return
        }
        _, err := esClient.Info()
        if err != nil {
            w.WriteHeader(http.StatusServiceUnavailable)
            w.Write([]byte("elasticsearch not ready"))
            return
        }
        w.WriteHeader(http.StatusOK)
        w.Write([]byte("ready"))
    })

    mux.HandleFunc("POST /api/v1/search/{index}", func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        index := r.PathValue("index")
        var req elastic.SearchRequest
        if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
            httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, "400").Inc()
            http.Error(w, "invalid request", http.StatusBadRequest)
            return
        }
        req.Index = index

        result, err := esClient.Search(r.Context(), req)
        duration := time.Since(start).Seconds()
        httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)

        if err != nil {
            slog.Error("search error", "error", err)
            httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, "500").Inc()
            http.Error(w, "search failed", http.StatusInternalServerError)
            return
        }

        httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, "200").Inc()
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(result)
    })

    mux.Handle("GET /metrics", promhttp.Handler())

    handler := otelhttp.NewHandler(mux, "search-http")

    httpPort := os.Getenv("HTTP_PORT")
    if httpPort == "" {
        httpPort = "9095"
    }
    httpSrv := &http.Server{
        Addr:    ":" + httpPort,
        Handler: handler,
    }

    grpcPort := os.Getenv("GRPC_PORT")
    if grpcPort == "" {
        grpcPort = "8095"
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
            semconv.ServiceName("search"),
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
