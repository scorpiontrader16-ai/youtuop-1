package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.uber.org/zap"

	"github.com/scorpiontrader16-ai/youtuop-1/services/feature-flags/internal/evaluator"
	"github.com/scorpiontrader16-ai/youtuop-1/services/feature-flags/internal/postgres"
)

var version = "dev"

// ── Metrics ───────────────────────────────────────────────────────────────

var (
	flagEvaluations = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "feature_flags_evaluations_total",
		Help: "Total flag evaluations",
	}, []string{"flag", "reason"})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "feature_flags_http_request_duration_seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "path"})
)

// ── Config ────────────────────────────────────────────────────────────────

type Config struct {
	HTTPPort     int
	OTLPEndpoint string
	RedisAddr    string
	RedisPass    string
}

func loadConfig() (Config, error) {
	httpPort, err := getEnvInt("HTTP_PORT", 9096)
	if err != nil {
		return Config{}, fmt.Errorf("HTTP_PORT: %w", err)
	}
	return Config{
		HTTPPort:     httpPort,
		OTLPEndpoint: getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317"),
		RedisAddr:    getEnv("REDIS_ADDR", "redis:6379"),
		RedisPass:    getEnv("REDIS_PASSWORD", ""),
	}, nil
}

func main() {
	log, err := zap.NewProduction()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to init logger: %v\n", err)
		os.Exit(1)
	}
	defer log.Sync() //nolint:errcheck

	log.Info("starting feature-flags service", zap.String("version", version))

	cfg, err := loadConfig()
	if err != nil {
		log.Fatal("invalid config", zap.Error(err))
	}

	// ── OpenTelemetry ──────────────────────────────────────────────────────
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

	slogLogger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	startupCtx, startupCancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer startupCancel()

	// ── Postgres ──────────────────────────────────────────────────────────
	pgClient, err := postgres.WaitForPostgres(startupCtx, postgres.ConfigFromEnv(), slogLogger)
	if err != nil {
		log.Fatal("postgres unavailable", zap.Error(err))
	}
	defer pgClient.Close()

	if err := pgClient.Migrate(startupCtx); err != nil {
		log.Fatal("migrations failed", zap.Error(err))
	}

	// ── Redis ─────────────────────────────────────────────────────────────
	rdb := redis.NewClient(&redis.Options{
		Addr:     cfg.RedisAddr,
		Password: cfg.RedisPass,
	})
	if err := rdb.Ping(startupCtx).Err(); err != nil {
		log.Fatal("redis unavailable", zap.Error(err))
	}

	// ── Evaluator Engine ──────────────────────────────────────────────────
	engine := evaluator.NewEngine(pgClient, rdb)

	// ── HTTP Routes ────────────────────────────────────────────────────────
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		if err := pgClient.DB().PingContext(ctx); err != nil {
			http.Error(w, "postgres not ready", http.StatusServiceUnavailable)
			return
		}
		if err := rdb.Ping(ctx).Err(); err != nil {
			http.Error(w, "redis not ready", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ready")
	})

	// ── Public Evaluation API (JWT protected) ─────────────────────────────

	// GET /v1/flags — كل الـ flags للـ tenant/plan context
	mux.HandleFunc("GET /v1/flags", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		tenantID := r.Header.Get("x-tenant-id")
		plan := r.Header.Get("x-plan")

		flags, err := engine.GetAll(ctx, tenantID, plan)
		if err != nil {
			log.Error("get all flags failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]any{"flags": flags})
	})

	// GET /v1/flags/{key} — flag واحد
	mux.HandleFunc("GET /v1/flags/{key}", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		key := r.PathValue("key")
		tenantID := r.Header.Get("x-tenant-id")
		plan := r.Header.Get("x-plan")
		userID := r.Header.Get("x-user-id")

		result, err := engine.Evaluate(ctx, key, tenantID, plan, userID)
		if err != nil {
			jsonError(w, "flag not found", http.StatusNotFound)
			return
		}

		flagEvaluations.WithLabelValues(key, result.Reason).Inc()
		jsonOK(w, result)
	})

	// ── Admin API (super_admin only — enforced by Gateway) ────────────────

	// GET /v1/admin/flags — كل الـ flags
	mux.HandleFunc("GET /v1/admin/flags", func(w http.ResponseWriter, r *http.Request) {
		flags, err := pgClient.ListFlags(r.Context())
		if err != nil {
			log.Error("list flags failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]any{"flags": flags, "count": len(flags)})
	})

	// POST /v1/admin/flags — إنشاء flag جديد
	mux.HandleFunc("POST /v1/admin/flags", func(w http.ResponseWriter, r *http.Request) {
		adminID := r.Header.Get("x-user-id")
		var req struct {
			Key          string          `json:"key"`
			Name         string          `json:"name"`
			Description  string          `json:"description"`
			Type         string          `json:"type"`
			DefaultValue json.RawMessage `json:"default_value"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		if req.Key == "" || req.Name == "" {
			jsonError(w, "key and name are required", http.StatusBadRequest)
			return
		}
		if req.Type == "" {
			req.Type = "boolean"
		}
		if req.DefaultValue == nil {
			req.DefaultValue = json.RawMessage(`false`)
		}

		flag, err := pgClient.CreateFlag(r.Context(),
			req.Key, req.Name, req.Description, req.Type, req.DefaultValue, adminID)
		if err != nil {
			log.Error("create flag failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}

		engine.InvalidateAll(r.Context())
		w.WriteHeader(http.StatusCreated)
		jsonOK(w, flag)
	})

	// PATCH /v1/admin/flags/{key} — تحديث flag
	mux.HandleFunc("PATCH /v1/admin/flags/{key}", func(w http.ResponseWriter, r *http.Request) {
		key := r.PathValue("key")
		var req struct {
			Enabled    bool `json:"enabled"`
			RolloutPct int  `json:"rollout_pct"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		if err := pgClient.UpdateFlag(r.Context(), key, req.Enabled, req.RolloutPct); err != nil {
			jsonError(w, "flag not found", http.StatusNotFound)
			return
		}
		engine.InvalidateAll(r.Context())
		log.Info("flag updated",
			zap.String("key", key),
			zap.Bool("enabled", req.Enabled),
			zap.Int("rollout_pct", req.RolloutPct),
		)
		jsonOK(w, map[string]string{"status": "ok"})
	})

	// DELETE /v1/admin/flags/{key}
	mux.HandleFunc("DELETE /v1/admin/flags/{key}", func(w http.ResponseWriter, r *http.Request) {
		key := r.PathValue("key")
		if err := pgClient.DeleteFlag(r.Context(), key); err != nil {
			jsonError(w, "flag not found", http.StatusNotFound)
			return
		}
		engine.InvalidateAll(r.Context())
		w.WriteHeader(http.StatusNoContent)
	})

	// POST /v1/admin/flags/{key}/overrides — إضافة override
	mux.HandleFunc("POST /v1/admin/flags/{key}/overrides", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		key := r.PathValue("key")
		adminID := r.Header.Get("x-user-id")

		var req struct {
			TargetType string          `json:"target_type"`
			TargetID   string          `json:"target_id"`
			Value      json.RawMessage `json:"value"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		if req.TargetType == "" || req.TargetID == "" {
			jsonError(w, "target_type and target_id are required", http.StatusBadRequest)
			return
		}
		if req.Value == nil {
			req.Value = json.RawMessage(`true`)
		}

		if err := pgClient.SetOverride(ctx, key, req.TargetType, req.TargetID, req.Value, adminID); err != nil {
			jsonError(w, "flag not found", http.StatusNotFound)
			return
		}

		// Invalidate cache للـ affected context
		if req.TargetType == "tenant" {
			engine.InvalidateContext(ctx, req.TargetID, "")
		} else {
			engine.InvalidateAll(ctx)
		}

		jsonOK(w, map[string]string{"status": "ok"})
	})

	// DELETE /v1/admin/flags/{key}/overrides — حذف override
	mux.HandleFunc("DELETE /v1/admin/flags/{key}/overrides", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		key := r.PathValue("key")
		q := r.URL.Query()
		targetType := q.Get("target_type")
		targetID := q.Get("target_id")

		if err := pgClient.DeleteOverride(ctx, key, targetType, targetID); err != nil {
			jsonError(w, "override not found", http.StatusNotFound)
			return
		}
		engine.InvalidateAll(ctx)
		w.WriteHeader(http.StatusNoContent)
	})

	httpServer := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.HTTPPort),
		Handler:      withMetrics(mux),
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	go func() {
		log.Info("HTTP server started", zap.Int("port", cfg.HTTPPort))
		if err := httpServer.ListenAndServe(); err != http.ErrServerClosed {
			log.Fatal("HTTP server failed", zap.Error(err))
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	sig := <-quit
	log.Info("shutting down", zap.String("signal", sig.String()))

	shutCtx, shutCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutCancel()
	if err := httpServer.Shutdown(shutCtx); err != nil {
		log.Error("HTTP shutdown error", zap.Error(err))
	}
	log.Info("shutdown complete")
}

// ── Helpers ───────────────────────────────────────────────────────────────

func withMetrics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).
			Observe(time.Since(start).Seconds())
	})
}

func jsonError(w http.ResponseWriter, msg string, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": msg}) //nolint:errcheck
}

func jsonOK(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}

func initTracer(endpoint string) (*sdktrace.TracerProvider, error) {
	exp, err := otlptracegrpc.New(context.Background(),
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
		return 0, fmt.Errorf("invalid value %q for %s", v, key)
	}
	return i, nil
}
