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

    "github.com/jackc/pgx/v5/pgxpool"
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

type server struct {
    db *pgxpool.Pool
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
    pool, err := pgxpool.New(context.Background(), pgConn)
    if err != nil {
        slog.Error("failed to connect postgres", "error", err)
        os.Exit(1)
    }
    defer pool.Close()

    s := &server{db: pool}

    mux := http.NewServeMux()

    // Health checks
    mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusOK)
        w.Write([]byte("ok"))
    })
    mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
        if err := pool.Ping(context.Background()); err != nil {
            w.WriteHeader(http.StatusServiceUnavailable)
            w.Write([]byte("postgres not ready"))
            return
        }
        w.WriteHeader(http.StatusOK)
        w.Write([]byte("ready"))
    })

    // ========== LEGAL PAGES (served from mounted volume) ==========
    mux.HandleFunc("GET /legal/terms", func(w http.ResponseWriter, r *http.Request) {
        http.ServeFile(w, r, "/app/legal/terms.html")
    })
    mux.HandleFunc("GET /legal/privacy", func(w http.ResponseWriter, r *http.Request) {
        http.ServeFile(w, r, "/app/legal/privacy.html")
    })
    mux.HandleFunc("GET /legal/cookies", func(w http.ResponseWriter, r *http.Request) {
        http.ServeFile(w, r, "/app/legal/cookies.html")
    })
    mux.HandleFunc("GET /legal/dpa", func(w http.ResponseWriter, r *http.Request) {
        http.ServeFile(w, r, "/app/legal/dpa.html")
    })

    // ========== COMPLIANCE & LEGAL ENDPOINTS ==========
    mux.HandleFunc("GET /api/v1/legal/holds", s.handleLegalHolds)
    mux.HandleFunc("POST /api/v1/legal/holds", s.handleLegalHolds)
    mux.HandleFunc("POST /api/v1/compliance/reports/mifid", s.handleGenerateMifidReport)
    mux.HandleFunc("POST /api/v1/disclaimers/accept", s.handleAcceptDisclaimer)

    // Metrics
    mux.Handle("GET /metrics", promhttp.Handler())

    // Wrap with otel
    handler := otelhttp.NewHandler(mux, "control-plane-http")

    httpPort := os.Getenv("HTTP_PORT")
    if httpPort == "" {
        httpPort = "9093"
    }
    httpSrv := &http.Server{
        Addr:    ":" + httpPort,
        Handler: handler,
    }

    grpcPort := os.Getenv("GRPC_PORT")
    if grpcPort == "" {
        grpcPort = "8093"
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

// ========== HANDLERS ==========

func (s *server) handleLegalHolds(w http.ResponseWriter, r *http.Request) {
    tenantID := r.Header.Get("X-Tenant-ID")
    if tenantID == "" {
        http.Error(w, "missing tenant id", http.StatusBadRequest)
        return
    }

    switch r.Method {
    case http.MethodGet:
        rows, err := s.db.Query(r.Context(),
            `SELECT id, entity_type, entity_id, reason, status, created_by, created_at, released_at
             FROM legal_holds
             WHERE tenant_id = $1
             ORDER BY created_at DESC`,
            tenantID,
        )
        if err != nil {
            slog.Error("failed to query legal holds", "error", err)
            http.Error(w, "database error", http.StatusInternalServerError)
            return
        }
        defer rows.Close()

        var holds []map[string]interface{}
        for rows.Next() {
            var id int64
            var entityType, entityID, reason, status, createdBy string
            var createdAt, releasedAt *time.Time
            if err := rows.Scan(&id, &entityType, &entityID, &reason, &status, &createdBy, &createdAt, &releasedAt); err != nil {
                continue
            }
            hold := map[string]interface{}{
                "id":          id,
                "entity_type": entityType,
                "entity_id":   entityID,
                "reason":      reason,
                "status":      status,
                "created_by":  createdBy,
                "created_at":  createdAt,
                "released_at": releasedAt,
            }
            holds = append(holds, hold)
        }
        json.NewEncoder(w).Encode(holds)

    case http.MethodPost:
        var req struct {
            EntityType string `json:"entity_type"`
            EntityID   string `json:"entity_id"`
            Reason     string `json:"reason"`
        }
        if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
            http.Error(w, "invalid request", http.StatusBadRequest)
            return
        }
        userID := r.Header.Get("X-User-ID")
        if userID == "" {
            userID = "system"
        }
        _, err := s.db.Exec(r.Context(),
            `INSERT INTO legal_holds (tenant_id, entity_type, entity_id, reason, status, created_by)
             VALUES ($1, $2, $3, $4, 'active', $5)`,
            tenantID, req.EntityType, req.EntityID, req.Reason, userID,
        )
        if err != nil {
            slog.Error("failed to create legal hold", "error", err)
            http.Error(w, "failed to create hold", http.StatusInternalServerError)
            return
        }
        w.WriteHeader(http.StatusCreated)
        json.NewEncoder(w).Encode(map[string]string{"status": "created"})
    }
}

func (s *server) handleGenerateMifidReport(w http.ResponseWriter, r *http.Request) {
    tenantID := r.Header.Get("X-Tenant-ID")
    if tenantID == "" {
        http.Error(w, "missing tenant id", http.StatusBadRequest)
        return
    }
    userID := r.Header.Get("X-User-ID")
    if userID == "" {
        userID = "system"
    }
    var req struct {
        PeriodStart time.Time `json:"period_start"`
        PeriodEnd   time.Time `json:"period_end"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "invalid request", http.StatusBadRequest)
        return
    }

    // Generate report data (simplified for demo)
    reportData := map[string]interface{}{
        "summary":      "MiFID II Best Execution Report",
        "period_start": req.PeriodStart,
        "period_end":   req.PeriodEnd,
        "metrics": map[string]interface{}{
            "total_orders": 0,
            "executed":     0,
        },
    }
    dataJSON, _ := json.Marshal(reportData)

    _, err := s.db.Exec(r.Context(),
        `INSERT INTO regulatory_reports (tenant_id, report_type, period_start, period_end, report_data, generated_by, status)
         VALUES ($1, 'mifid_best_execution', $2, $3, $4, $5, 'generated')`,
        tenantID, req.PeriodStart, req.PeriodEnd, dataJSON, userID,
    )
    if err != nil {
        slog.Error("failed to generate mifid report", "error", err)
        http.Error(w, "failed to generate report", http.StatusInternalServerError)
        return
    }
    w.WriteHeader(http.StatusAccepted)
    json.NewEncoder(w).Encode(map[string]string{"status": "report generation started"})
}

func (s *server) handleAcceptDisclaimer(w http.ResponseWriter, r *http.Request) {
    tenantID := r.Header.Get("X-Tenant-ID")
    if tenantID == "" {
        http.Error(w, "missing tenant id", http.StatusBadRequest)
        return
    }
    userID := r.Header.Get("X-User-ID")
    if userID == "" {
        userID = "anonymous"
    }

    var req struct {
        DisclaimerType string `json:"disclaimer_type"`
        Version        string `json:"version"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "invalid request", http.StatusBadRequest)
        return
    }

    ip := r.Header.Get("X-Forwarded-For")
    if ip == "" {
        ip = r.RemoteAddr
    }
    ua := r.UserAgent()

    _, err := s.db.Exec(r.Context(),
        `INSERT INTO disclaimer_acceptances (user_id, tenant_id, disclaimer_type, version, ip_address, user_agent)
         VALUES ($1, $2, $3, $4, $5, $6)`,
        userID, tenantID, req.DisclaimerType, req.Version, ip, ua,
    )
    if err != nil {
        slog.Error("failed to record disclaimer acceptance", "error", err)
        http.Error(w, "failed to record acceptance", http.StatusInternalServerError)
        return
    }
    w.WriteHeader(http.StatusCreated)
    json.NewEncoder(w).Encode(map[string]string{"status": "accepted"})
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
            semconv.ServiceName("control-plane"),
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
