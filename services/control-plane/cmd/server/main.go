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
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.uber.org/zap"

	"github.com/aminpola2001-ctrl/youtuop/services/control-plane/internal/postgres"
)

var version = "dev"

var (
	adminActionsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "control_plane_admin_actions_total",
		Help: "Total admin actions performed",
	}, []string{"action", "target_type"})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "control_plane_http_request_duration_seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "path"})
)

type Config struct {
	HTTPPort     int
	OTLPEndpoint string
}

func loadConfig() (Config, error) {
	httpPort, err := getEnvInt("HTTP_PORT", 9095)
	if err != nil {
		return Config{}, fmt.Errorf("HTTP_PORT: %w", err)
	}
	return Config{
		HTTPPort:     httpPort,
		OTLPEndpoint: getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317"),
	}, nil
}

func main() {
	log, err := zap.NewProduction()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to init logger: %v\n", err)
		os.Exit(1)
	}
	defer log.Sync() //nolint:errcheck

	log.Info("starting control-plane service", zap.String("version", version))

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

	slogLogger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))

	startupCtx, startupCancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer startupCancel()

	pgClient, err := postgres.WaitForPostgres(startupCtx, postgres.ConfigFromEnv(), slogLogger)
	if err != nil {
		log.Fatal("postgres unavailable", zap.Error(err))
	}
	defer pgClient.Close()

	if err := pgClient.Migrate(startupCtx); err != nil {
		log.Fatal("migrations failed", zap.Error(err))
	}

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
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ready")
	})

	// ── Tenant Management ─────────────────────────────────────────────────
	mux.HandleFunc("GET /v1/admin/tenants", func(w http.ResponseWriter, r *http.Request) {
		tenants, err := pgClient.ListTenants(r.Context(), "", 100, 0)
		if err != nil {
			log.Error("list tenants failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]any{"tenants": tenants, "count": len(tenants)})
	})

	mux.HandleFunc("POST /v1/admin/tenants/{id}/suspend", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		id := r.PathValue("id")
		adminID := r.Header.Get("x-user-id")
		if err := pgClient.SuspendTenant(ctx, id, adminID, "suspended_by_admin"); err != nil {
			log.Error("suspend tenant failed", zap.Error(err))
			jsonError(w, "action failed", http.StatusInternalServerError)
			return
		}
		adminActionsTotal.WithLabelValues("suspend_tenant", "tenant").Inc()
		log.Info("tenant suspended", zap.String("tenant_id", id), zap.String("admin_id", adminID))
		jsonOK(w, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("POST /v1/admin/tenants/{id}/reactivate", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		id := r.PathValue("id")
		adminID := r.Header.Get("x-user-id")
		if err := pgClient.ReactivateTenant(ctx, id, adminID); err != nil {
			log.Error("reactivate tenant failed", zap.Error(err))
			jsonError(w, "action failed", http.StatusInternalServerError)
			return
		}
		adminActionsTotal.WithLabelValues("reactivate_tenant", "tenant").Inc()
		jsonOK(w, map[string]string{"status": "ok"})
	})

	// ── User Management ───────────────────────────────────────────────────
	mux.HandleFunc("GET /v1/admin/users", func(w http.ResponseWriter, r *http.Request) {
		tenantID := r.URL.Query().Get("tenant_id")
		users, err := pgClient.ListUsers(r.Context(), tenantID, 100, 0)
		if err != nil {
			log.Error("list users failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]any{"users": users, "count": len(users)})
	})

	mux.HandleFunc("POST /v1/admin/users/{id}/ban", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		id := r.PathValue("id")
		adminID := r.Header.Get("x-user-id")
		if err := pgClient.BanUser(ctx, id, adminID, "banned_by_admin"); err != nil {
			log.Error("ban user failed", zap.Error(err))
			jsonError(w, "action failed", http.StatusInternalServerError)
			return
		}
		adminActionsTotal.WithLabelValues("ban_user", "user").Inc()
		log.Warn("user banned", zap.String("user_id", id), zap.String("admin_id", adminID))
		jsonOK(w, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("POST /v1/admin/users/{id}/force-logout", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		id := r.PathValue("id")
		adminID := r.Header.Get("x-user-id")
		count, err := pgClient.ForceLogout(ctx, id, adminID)
		if err != nil {
			log.Error("force logout failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		adminActionsTotal.WithLabelValues("force_logout", "user").Inc()
		jsonOK(w, map[string]any{"sessions_revoked": count})
	})

	// ── Kill Switches ─────────────────────────────────────────────────────
	mux.HandleFunc("GET /v1/admin/kill-switches", func(w http.ResponseWriter, r *http.Request) {
		switches, err := pgClient.ListKillSwitches(r.Context())
		if err != nil {
			log.Error("list kill switches failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]any{"kill_switches": switches})
	})

	mux.HandleFunc("POST /v1/admin/kill-switches/{name}/activate", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		name := r.PathValue("name")
		adminID := r.Header.Get("x-user-id")
		if err := pgClient.ToggleKillSwitch(ctx, name, true, adminID); err != nil {
			jsonError(w, "kill switch not found", http.StatusNotFound)
			return
		}
		adminActionsTotal.WithLabelValues("activate_kill_switch", "service").Inc()
		log.Warn("kill switch activated", zap.String("name", name), zap.String("admin_id", adminID))
		jsonOK(w, map[string]any{"name": name, "enabled": true})
	})

	mux.HandleFunc("POST /v1/admin/kill-switches/{name}/deactivate", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		name := r.PathValue("name")
		adminID := r.Header.Get("x-user-id")
		if err := pgClient.ToggleKillSwitch(ctx, name, false, adminID); err != nil {
			jsonError(w, "kill switch not found", http.StatusNotFound)
			return
		}
		adminActionsTotal.WithLabelValues("deactivate_kill_switch", "service").Inc()
		jsonOK(w, map[string]any{"name": name, "enabled": false})
	})

	// ── System Config ─────────────────────────────────────────────────────
	mux.HandleFunc("GET /v1/admin/config", func(w http.ResponseWriter, r *http.Request) {
		config, err := pgClient.ListConfig(r.Context())
		if err != nil {
			log.Error("get config failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, config)
	})

	mux.HandleFunc("PUT /v1/admin/config/{key}", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		key := r.PathValue("key")
		adminID := r.Header.Get("x-user-id")

		var body struct {
			Value json.RawMessage `json:"value"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		if err := pgClient.SetConfig(ctx, key, body.Value, adminID); err != nil {
			log.Error("set config failed", zap.String("key", key), zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		adminActionsTotal.WithLabelValues("set_config", "system").Inc()
		jsonOK(w, map[string]string{"key": key, "status": "updated"})
	})

	// ── Audit Log ─────────────────────────────────────────────────────────
	mux.HandleFunc("GET /v1/admin/audit", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		entries, err := pgClient.QueryAuditLog(r.Context(),
			q.Get("tenant_id"), q.Get("user_id"), q.Get("action"), 100)
		if err != nil {
			log.Error("query audit log failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]any{"entries": entries, "count": len(entries)})
	})

	// ── System Health ─────────────────────────────────────────────────────
	mux.HandleFunc("GET /v1/admin/health", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		health := map[string]any{"status": "ok", "timestamp": time.Now().UTC()}
		if err := pgClient.DB().PingContext(ctx); err != nil {
			health["postgres"] = "degraded"
			health["status"] = "degraded"
		} else {
			health["postgres"] = "ok"
		}
		jsonOK(w, health)
	})

	httpServer := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.HTTPPort),
		Handler:      withMetrics(mux),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
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

func withMetrics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(time.Since(start).Seconds())
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
