package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
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

	"github.com/scorpiontrader16-ai/youtuop-1/services/developer-portal/internal/apikey"
	"github.com/scorpiontrader16-ai/youtuop-1/services/developer-portal/internal/postgres"
	"github.com/scorpiontrader16-ai/youtuop-1/services/developer-portal/internal/webhook"
)

var version = "dev"

// ── Metrics ───────────────────────────────────────────────────────────────

var (
	apiKeysCreated = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "developer_portal_api_keys_created_total",
		Help: "Total API keys created",
	}, []string{"environment"})

	webhooksCreated = promauto.NewCounter(prometheus.CounterOpts{
		Name: "developer_portal_webhooks_created_total",
		Help: "Total webhooks created",
	})

	webhookDeliveries = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "developer_portal_webhook_deliveries_total",
		Help: "Total webhook delivery attempts",
	}, []string{"status"})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "developer_portal_http_request_duration_seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "path"})
)

// ── Config ────────────────────────────────────────────────────────────────

type Config struct {
	HTTPPort     int
	OTLPEndpoint string
	PortalURL    string
}

func loadConfig() (Config, error) {
	httpPort, err := getEnvInt("HTTP_PORT", 9097)
	if err != nil {
		return Config{}, fmt.Errorf("HTTP_PORT: %w", err)
	}
	return Config{
		HTTPPort:     httpPort,
		OTLPEndpoint: getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317"),
		PortalURL:    getEnv("PORTAL_URL", "https://developers.youtuop-1.com"),
	}, nil
}

func main() {
	log, err := zap.NewProduction()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to init logger: %v\n", err)
		os.Exit(1)
	}
	defer log.Sync() //nolint:errcheck

	log.Info("starting developer-portal service", zap.String("version", version))

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

	slogLogger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

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

	// ── API Keys ──────────────────────────────────────────────────────────

	// GET /v1/developer/keys — قائمة الـ API keys
	mux.HandleFunc("GET /v1/developer/keys", func(w http.ResponseWriter, r *http.Request) {
		userID := r.Header.Get("x-user-id")
		tenantID := r.Header.Get("x-tenant-id")
		keys, err := pgClient.ListAPIKeys(r.Context(), userID, tenantID)
		if err != nil {
			log.Error("list api keys failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]any{"keys": keys, "count": len(keys)})
	})

	// POST /v1/developer/keys — إنشاء API key جديد
	mux.HandleFunc("POST /v1/developer/keys", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		userID := r.Header.Get("x-user-id")
		tenantID := r.Header.Get("x-tenant-id")
		plan := r.Header.Get("x-plan")

		var req struct {
			Name        string   `json:"name"`
			Description string   `json:"description"`
			Environment string   `json:"environment"`
			Scopes      []string `json:"scopes"`
			ExpiresAt   *string  `json:"expires_at"`
			RateLimit   int      `json:"rate_limit"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		if req.Name == "" {
			jsonError(w, "name is required", http.StatusBadRequest)
			return
		}
		if req.Environment == "" {
			req.Environment = "production"
		}

		// Sandbox فقط للـ pro+ plans
		if req.Environment == "sandbox" && plan == "basic" {
			jsonError(w, "sandbox environment requires pro plan or higher", http.StatusForbidden)
			return
		}

		// Default rate limit حسب الـ plan
		if req.RateLimit == 0 {
			req.RateLimit = planDefaultRateLimit(plan)
		}

		// Default scopes
		if len(req.Scopes) == 0 {
			req.Scopes = []string{"markets:read"}
		}

		// Generate secure key
		gen, err := apikey.Generate(req.Environment)
		if err != nil {
			log.Error("generate api key failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}

		// Parse expiry
		var expiresAt *time.Time
		if req.ExpiresAt != nil {
			t, err := time.Parse(time.RFC3339, *req.ExpiresAt)
			if err != nil {
				jsonError(w, "invalid expires_at format (RFC3339 required)", http.StatusBadRequest)
				return
			}
			expiresAt = &t
		}

		key, err := pgClient.CreateAPIKey(ctx,
			userID, tenantID, req.Name, req.Description,
			req.Environment, gen.KeyPrefix, gen.KeyHash,
			req.Scopes, expiresAt, req.RateLimit,
		)
		if err != nil {
			log.Error("create api key failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}

		apiKeysCreated.WithLabelValues(req.Environment).Inc()
		log.Info("api key created",
			zap.String("tenant_id", tenantID),
			zap.String("environment", req.Environment),
			zap.String("key_prefix", gen.KeyPrefix),
		)

		// الـ raw key بيتبعت مرة واحدة فقط — مش بيتحفظ في الـ DB
		w.WriteHeader(http.StatusCreated)
		jsonOK(w, map[string]any{
			"id":          key.ID,
			"key":         gen.RawKey, // ← هنا بس يتبعت
			"key_prefix":  gen.KeyPrefix,
			"name":        key.Name,
			"environment": key.Environment,
			"scopes":      key.Scopes,
			"rate_limit":  key.RateLimit,
			"expires_at":  key.ExpiresAt,
			"created_at":  key.CreatedAt,
			"warning":     "Store this key securely — it will not be shown again",
		})
	})

	// DELETE /v1/developer/keys/{id} — إلغاء API key
	mux.HandleFunc("DELETE /v1/developer/keys/{id}", func(w http.ResponseWriter, r *http.Request) {
		keyID := r.PathValue("id")
		userID := r.Header.Get("x-user-id")
		if err := pgClient.RevokeAPIKey(r.Context(), keyID, userID); err != nil {
			jsonError(w, "key not found", http.StatusNotFound)
			return
		}
		log.Info("api key revoked",
			zap.String("key_id", keyID),
			zap.String("user_id", userID),
		)
		w.WriteHeader(http.StatusNoContent)
	})

	// ── Webhooks ──────────────────────────────────────────────────────────

	// GET /v1/developer/webhooks
	mux.HandleFunc("GET /v1/developer/webhooks", func(w http.ResponseWriter, r *http.Request) {
		tenantID := r.Header.Get("x-tenant-id")
		webhooks, err := pgClient.ListWebhooks(r.Context(), tenantID)
		if err != nil {
			log.Error("list webhooks failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]any{"webhooks": webhooks, "count": len(webhooks)})
	})

	// POST /v1/developer/webhooks — إنشاء webhook
	mux.HandleFunc("POST /v1/developer/webhooks", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		userID := r.Header.Get("x-user-id")
		tenantID := r.Header.Get("x-tenant-id")

		var req struct {
			Name       string   `json:"name"`
			URL        string   `json:"url"`
			Events     []string `json:"events"`
			RetryCount int      `json:"retry_count"`
			TimeoutMS  int      `json:"timeout_ms"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		if req.Name == "" || req.URL == "" {
			jsonError(w, "name and url are required", http.StatusBadRequest)
			return
		}
		if len(req.Events) == 0 {
			jsonError(w, "at least one event type is required", http.StatusBadRequest)
			return
		}
		if req.RetryCount == 0 {
			req.RetryCount = 3
		}
		if req.TimeoutMS == 0 {
			req.TimeoutMS = 5000
		}

		// Generate webhook secret using crypto/rand
		secretBytes := make([]byte, 32)
		if _, randErr := rand.Read(secretBytes); randErr != nil {
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		h := sha256.Sum256(secretBytes)
		secretHash := hex.EncodeToString(h[:])
		secretDisplay := "whsec_" + hex.EncodeToString(secretBytes) // للـ display فقط

		wh, err := pgClient.CreateWebhook(ctx,
			tenantID, userID, req.Name, req.URL,
			secretHash, req.Events, req.RetryCount, req.TimeoutMS,
		)
		if err != nil {
			log.Error("create webhook failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}

		webhooksCreated.Inc()
		log.Info("webhook created",
			zap.String("tenant_id", tenantID),
			zap.String("url", req.URL),
		)

		w.WriteHeader(http.StatusCreated)
		jsonOK(w, map[string]any{
			"id":      wh.ID,
			"name":    wh.Name,
			"url":     wh.URL,
			"events":  wh.Events,
			"secret":  secretDisplay, // ← مرة واحدة فقط
			"enabled": wh.Enabled,
			"warning": "Store the webhook secret securely — it will not be shown again",
		})
	})

	// DELETE /v1/developer/webhooks/{id}
	mux.HandleFunc("DELETE /v1/developer/webhooks/{id}", func(w http.ResponseWriter, r *http.Request) {
		webhookID := r.PathValue("id")
		tenantID := r.Header.Get("x-tenant-id")
		if err := pgClient.DeleteWebhook(r.Context(), webhookID, tenantID); err != nil {
			jsonError(w, "webhook not found", http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})

	// POST /v1/developer/webhooks/{id}/test — إرسال test event
	mux.HandleFunc("POST /v1/developer/webhooks/{id}/test", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		webhookID := r.PathValue("id")
		tenantID := r.Header.Get("x-tenant-id")

		secretHash, err := pgClient.GetWebhookSecret(ctx, webhookID, tenantID)
		if err != nil {
			jsonError(w, "webhook not found", http.StatusNotFound)
			return
		}

		// Get webhook URL
		webhooks, err := pgClient.ListWebhooks(ctx, tenantID)
		if err != nil {
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}

		var targetURL string
		for _, wh := range webhooks {
			if wh.ID == webhookID {
				targetURL = wh.URL
				break
			}
		}
		if targetURL == "" {
			jsonError(w, "webhook not found", http.StatusNotFound)
			return
		}

		testEvent := &webhook.Event{
			ID:        "test_" + webhookID,
			Type:      "webhook.test",
			TenantID:  tenantID,
			CreatedAt: time.Now(),
			Data: map[string]any{
				"message": "This is a test event from youtuop Developer Portal",
			},
		}

		result := webhook.Deliver(ctx, targetURL, secretHash, testEvent)

		status := "success"
		if !result.Success {
			status = "failed"
		}
		webhookDeliveries.WithLabelValues(status).Inc()

		jsonOK(w, map[string]any{
			"success":     result.Success,
			"status_code": result.StatusCode,
			"duration_ms": result.DurationMS,
			"attempt":     result.Attempt,
			"error":       result.Error,
		})
	})

	// GET /v1/developer/webhooks/events — كل الـ event types المتاحة
	mux.HandleFunc("GET /v1/developer/webhooks/events", func(w http.ResponseWriter, r *http.Request) {
		types, err := pgClient.ListEventTypes(r.Context())
		if err != nil {
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]any{"event_types": types})
	})

	// ── Usage Analytics ───────────────────────────────────────────────────

	// GET /v1/developer/usage — usage statistics
	mux.HandleFunc("GET /v1/developer/usage", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		tenantID := r.Header.Get("x-tenant-id")
		q := r.URL.Query()

		from := time.Now().AddDate(0, 0, -30) // default: آخر 30 يوم
		to := time.Now()

		if v := q.Get("from"); v != "" {
			if t, err := time.Parse(time.RFC3339, v); err == nil {
				from = t
			}
		}
		if v := q.Get("to"); v != "" {
			if t, err := time.Parse(time.RFC3339, v); err == nil {
				to = t
			}
		}

		stats, err := pgClient.GetUsageStats(ctx, tenantID, from, to)
		if err != nil {
			log.Error("get usage stats failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}

		topEndpoints, err := pgClient.GetTopEndpoints(ctx, tenantID, from, to, 10)
		if err != nil {
			log.Warn("get top endpoints failed", zap.Error(err))
			topEndpoints = []map[string]any{}
		}

		jsonOK(w, map[string]any{
			"period": map[string]any{
				"from": from,
				"to":   to,
			},
			"summary":       stats,
			"top_endpoints": topEndpoints,
		})
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

// ── Helpers ───────────────────────────────────────────────────────────────

func planDefaultRateLimit(plan string) int {
	switch plan {
	case "enterprise":
		return 10000
	case "business":
		return 5000
	case "pro":
		return 1000
	default:
		return 100
	}
}

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
