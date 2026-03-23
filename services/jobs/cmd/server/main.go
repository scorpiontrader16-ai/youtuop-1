package main

import (
    "context"
    "encoding/json"
    "fmt"
    "log/slog"
    "net"
    "net/http"
    "os"
    "os/signal"
    "syscall"
    "time"

    "github.com/go-redis/redis/v8"
    "github.com/hibiken/asynq"
    "github.com/jackc/pgx/v5/pgxpool"
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
            Name: "jobs_http_requests_total",
            Help: "Total number of HTTP requests",
        },
        []string{"method", "path", "status"},
    )
    httpRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "jobs_http_request_duration_seconds",
            Help:    "HTTP request duration in seconds",
            Buckets: prometheus.DefBuckets,
        },
        []string{"method", "path"},
    )
    asynqProcessedTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "jobs_asynq_processed_total",
            Help: "Total number of processed tasks",
        },
        []string{"task_type", "status"},
    )
)

func main() {
    logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
    slog.SetDefault(logger)

    shutdownTracer, err := initTracer()
    if err != nil {
        slog.Error("failed to init tracer", "error", err)
    }
    defer shutdownTracer(context.Background())

    // Postgres
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

    // Redis
    redisAddr := os.Getenv("REDIS_ADDR")
    if redisAddr == "" {
        redisAddr = "redis.platform.svc.cluster.local:6379"
    }
    redisClient := redis.NewClient(&redis.Options{
        Addr: redisAddr,
    })
    if err := redisClient.Ping(context.Background()).Err(); err != nil {
        slog.Error("failed to connect redis", "error", err)
        os.Exit(1)
    }

    // Asynq client
    asynqClient := asynq.NewClient(asynq.RedisClientOpt{Addr: redisAddr})
    defer asynqClient.Close()

    // Asynq server
    asynqSrv := asynq.NewServer(
        asynq.RedisClientOpt{Addr: redisAddr},
        asynq.Config{
            Concurrency: 10,
            Queues: map[string]int{
                "critical": 6,
                "default":  3,
                "low":      1,
            },
            Logger: &asynqLogger{},
            ErrorHandler: asynq.ErrorHandlerFunc(func(ctx context.Context, task *asynq.Task, err error) {
                slog.Error("asynq task failed", "type", task.Type(), "error", err)
                asynqProcessedTotal.WithLabelValues(task.Type(), "failed").Inc()
            }),
        },
    )

    // Register task handlers
    mux := asynq.NewServeMux()
    mux.HandleFunc("email:send", handleEmailSend)
    mux.HandleFunc("report:generate", handleReportGenerate)
    mux.HandleFunc("webhook:deliver", handleWebhookDeliver)

    go func() {
        if err := asynqSrv.Run(mux); err != nil {
            slog.Error("asynq server error", "error", err)
        }
    }()

    // Cron scheduler goroutine
    go runCronScheduler(pool, asynqClient)

    // HTTP server
    httpMux := http.NewServeMux()
    setupHTTPHandlers(httpMux, pool, asynqClient)

    httpPort := os.Getenv("HTTP_PORT")
    if httpPort == "" {
        httpPort = "9097"
    }
    httpSrv := &http.Server{
        Addr:    ":" + httpPort,
        Handler: otelhttp.NewHandler(httpMux, "jobs-http"),
    }

    // gRPC health server
    grpcPort := os.Getenv("GRPC_PORT")
    if grpcPort == "" {
        grpcPort = "8097"
    }
    grpcSrv := grpc.NewServer()
    grpc_health_v1.RegisterHealthServer(grpcSrv, &healthServer{})

    // Start servers
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
    asynqSrv.Shutdown()
    slog.Info("shutdown complete")
}

func setupHTTPHandlers(mux *http.ServeMux, pool *pgxpool.Pool, asynqClient *asynq.Client) {
    // Health
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
        if err := asynqClient.Ping(); err != nil {
            w.WriteHeader(http.StatusServiceUnavailable)
            w.Write([]byte("asynq not ready"))
            return
        }
        w.WriteHeader(http.StatusOK)
        w.Write([]byte("ready"))
    })

    // Submit job
    mux.HandleFunc("POST /api/v1/jobs", func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        tenantID := r.Header.Get("X-Tenant-ID")
        if tenantID == "" {
            httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, "400").Inc()
            http.Error(w, "missing tenant id", http.StatusBadRequest)
            return
        }

        var req struct {
            JobType     string                 `json:"job_type"`
            JobName     string                 `json:"job_name"`
            Payload     map[string]interface{} `json:"payload"`
            Priority    int                    `json:"priority"`
            ScheduledAt *time.Time             `json:"scheduled_at,omitempty"`
        }
        if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
            httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, "400").Inc()
            http.Error(w, "invalid request", http.StatusBadRequest)
            return
        }

        var jobID int64
        err := pool.QueryRow(r.Context(),
            `INSERT INTO background_jobs (tenant_id, job_type, job_name, payload, priority, scheduled_for, status)
             VALUES ($1, $2, $3, $4, $5, $6, 'pending')
             RETURNING id`,
            tenantID, req.JobType, req.JobName, req.Payload, req.Priority, req.ScheduledAt,
        ).Scan(&jobID)
        if err != nil {
            slog.Error("failed to insert job", "error", err)
            httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, "500").Inc()
            http.Error(w, "failed to create job", http.StatusInternalServerError)
            return
        }

        // Enqueue to Asynq immediately if not scheduled in the future
        if req.ScheduledAt == nil || req.ScheduledAt.Before(time.Now().Add(5*time.Second)) {
            task := asynq.NewTask(req.JobType, []byte(req.JobName))
            info, err := asynqClient.Enqueue(task, asynq.Queue("default"))
            if err != nil {
                slog.Error("failed to enqueue", "error", err)
            } else {
                slog.Info("enqueued task", "id", info.ID, "type", req.JobType)
            }
        }

        duration := time.Since(start).Seconds()
        httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)
        httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, "202").Inc()

        w.WriteHeader(http.StatusAccepted)
        json.NewEncoder(w).Encode(map[string]interface{}{"job_id": jobID, "status": "accepted"})
    })

    // List jobs
    mux.HandleFunc("GET /api/v1/jobs", func(w http.ResponseWriter, r *http.Request) {
        tenantID := r.Header.Get("X-Tenant-ID")
        if tenantID == "" {
            http.Error(w, "missing tenant id", http.StatusBadRequest)
            return
        }
        rows, err := pool.Query(r.Context(),
            `SELECT id, job_type, job_name, status, created_at FROM background_jobs
             WHERE tenant_id = $1 ORDER BY created_at DESC LIMIT 100`,
            tenantID,
        )
        if err != nil {
            http.Error(w, "db error", http.StatusInternalServerError)
            return
        }
        defer rows.Close()
        var jobs []map[string]interface{}
        for rows.Next() {
            var id int64
            var jobType, jobName, status string
            var createdAt time.Time
            if err := rows.Scan(&id, &jobType, &jobName, &status, &createdAt); err != nil {
                continue
            }
            jobs = append(jobs, map[string]interface{}{
                "id": id, "type": jobType, "name": jobName, "status": status, "created_at": createdAt,
            })
        }
        json.NewEncoder(w).Encode(jobs)
    })

    // Create cron job
    mux.HandleFunc("POST /api/v1/cron", func(w http.ResponseWriter, r *http.Request) {
        tenantID := r.Header.Get("X-Tenant-ID")
        if tenantID == "" {
            http.Error(w, "missing tenant id", http.StatusBadRequest)
            return
        }
        var req struct {
            JobType  string                 `json:"job_type"`
            JobName  string                 `json:"job_name"`
            Schedule string                 `json:"schedule"` // cron expression
            Payload  map[string]interface{} `json:"payload"`
        }
        if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
            http.Error(w, "invalid request", http.StatusBadRequest)
            return
        }
        // Calculate next run (simplified, should use cron parser)
        nextRun := time.Now().Add(1 * time.Minute) // placeholder
        _, err := pool.Exec(r.Context(),
            `INSERT INTO cron_jobs (tenant_id, job_type, job_name, schedule, payload, next_run_at)
             VALUES ($1, $2, $3, $4, $5, $6)`,
            tenantID, req.JobType, req.JobName, req.Schedule, req.Payload, nextRun,
        )
        if err != nil {
            http.Error(w, "failed to create cron job", http.StatusInternalServerError)
            return
        }
        w.WriteHeader(http.StatusCreated)
        json.NewEncoder(w).Encode(map[string]string{"status": "created"})
    })

    // List cron jobs
    mux.HandleFunc("GET /api/v1/cron", func(w http.ResponseWriter, r *http.Request) {
        tenantID := r.Header.Get("X-Tenant-ID")
        if tenantID == "" {
            http.Error(w, "missing tenant id", http.StatusBadRequest)
            return
        }
        rows, err := pool.Query(r.Context(),
            `SELECT id, job_type, job_name, schedule, enabled, next_run_at FROM cron_jobs
             WHERE tenant_id = $1 ORDER BY created_at DESC`,
            tenantID,
        )
        if err != nil {
            http.Error(w, "db error", http.StatusInternalServerError)
            return
        }
        defer rows.Close()
        var jobs []map[string]interface{}
        for rows.Next() {
            var id int64
            var jobType, jobName, schedule string
            var enabled bool
            var nextRunAt *time.Time
            if err := rows.Scan(&id, &jobType, &jobName, &schedule, &enabled, &nextRunAt); err != nil {
                continue
            }
            jobs = append(jobs, map[string]interface{}{
                "id": id, "type": jobType, "name": jobName, "schedule": schedule,
                "enabled": enabled, "next_run_at": nextRunAt,
            })
        }
        json.NewEncoder(w).Encode(jobs)
    })

    // Metrics
    mux.Handle("GET /metrics", promhttp.Handler())
}

// Cron scheduler
func runCronScheduler(pool *pgxpool.Pool, client *asynq.Client) {
    ticker := time.NewTicker(1 * time.Minute)
    defer ticker.Stop()
    for range ticker.C {
        ctx := context.Background()
        rows, err := pool.Query(ctx,
            `SELECT id, tenant_id, job_type, job_name, payload, schedule
             FROM cron_jobs WHERE enabled = true AND next_run_at <= NOW()`,
        )
        if err != nil {
            slog.Error("cron scheduler query failed", "error", err)
            continue
        }
        for rows.Next() {
            var id int64
            var tenantID, jobType, jobName, schedule string
            var payload []byte
            if err := rows.Scan(&id, &tenantID, &jobType, &jobName, &payload, &schedule); err != nil {
                continue
            }
            // Enqueue task
            task := asynq.NewTask(jobType, []byte(jobName))
            info, err := client.Enqueue(task, asynq.Queue("default"))
            if err != nil {
                slog.Error("cron enqueue failed", "error", err)
                continue
            }
            slog.Info("cron job enqueued", "id", info.ID, "type", jobType)

            // Update next_run_at (simplified, should use cron parser)
            nextRun := time.Now().Add(1 * time.Minute)
            _, err = pool.Exec(ctx,
                `UPDATE cron_jobs SET last_run_at = NOW(), next_run_at = $1 WHERE id = $2`,
                nextRun, id,
            )
            if err != nil {
                slog.Error("failed to update cron next_run", "error", err)
            }
        }
        rows.Close()
    }
}

// Task handlers
func handleEmailSend(ctx context.Context, t *asynq.Task) error {
    slog.Info("processing email send", "payload", string(t.Payload()))
    asynqProcessedTotal.WithLabelValues("email:send", "success").Inc()
    return nil
}

func handleReportGenerate(ctx context.Context, t *asynq.Task) error {
    slog.Info("processing report generation", "payload", string(t.Payload()))
    asynqProcessedTotal.WithLabelValues("report:generate", "success").Inc()
    return nil
}

func handleWebhookDeliver(ctx context.Context, t *asynq.Task) error {
    slog.Info("processing webhook delivery", "payload", string(t.Payload()))
    asynqProcessedTotal.WithLabelValues("webhook:deliver", "success").Inc()
    return nil
}

// Asynq logger adapter
type asynqLogger struct{}

func (l *asynqLogger) Debug(args ...interface{})                 { slog.Debug("asynq", "msg", args) }
func (l *asynqLogger) Debugf(format string, args ...interface{}) { slog.Debug("asynq", "msg", fmt.Sprintf(format, args...)) }
func (l *asynqLogger) Info(args ...interface{})                  { slog.Info("asynq", "msg", args) }
func (l *asynqLogger) Infof(format string, args ...interface{})  { slog.Info("asynq", "msg", fmt.Sprintf(format, args...)) }
func (l *asynqLogger) Warn(args ...interface{})                  { slog.Warn("asynq", "msg", args) }
func (l *asynqLogger) Warnf(format string, args ...interface{})  { slog.Warn("asynq", "msg", fmt.Sprintf(format, args...)) }
func (l *asynqLogger) Error(args ...interface{})                 { slog.Error("asynq", "msg", args) }
func (l *asynqLogger) Errorf(format string, args ...interface{}) { slog.Error("asynq", "msg", fmt.Sprintf(format, args...)) }
func (l *asynqLogger) Fatal(args ...interface{})                 { slog.Error("asynq", "msg", args); os.Exit(1) }
func (l *asynqLogger) Fatalf(format string, args ...interface{}) { slog.Error("asynq", "msg", fmt.Sprintf(format, args...)); os.Exit(1) }

// gRPC health server
type healthServer struct {
    grpc_health_v1.UnimplementedHealthServer
}

func (s *healthServer) Check(ctx context.Context, req *grpc_health_v1.HealthCheckRequest) (*grpc_health_v1.HealthCheckResponse, error) {
    return &grpc_health_v1.HealthCheckResponse{Status: grpc_health_v1.HealthCheckResponse_SERVING}, nil
}

func (s *healthServer) Watch(req *grpc_health_v1.HealthCheckRequest, stream grpc_health_v1.Health_WatchServer) error {
    return stream.Send(&grpc_health_v1.HealthCheckResponse{Status: grpc_health_v1.HealthCheckResponse_SERVING})
}

// Tracer init
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
            semconv.ServiceName("jobs"),
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
