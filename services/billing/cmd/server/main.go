package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
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

	"github.com/scorpiontrader16-ai/youtuop-1/services/billing/internal/postgres"
	stripeclient "github.com/scorpiontrader16-ai/youtuop-1/services/billing/internal/stripe"
	"github.com/scorpiontrader16-ai/youtuop-1/services/billing/internal/webhook"
)

var version = "dev"

// ── Metrics ───────────────────────────────────────────────────────────────

var (
	subscriptionCreated = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "billing_subscription_created_total",
		Help: "Total subscriptions created",
	}, []string{"plan"})

	webhookProcessed = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "billing_webhook_processed_total",
		Help: "Total Stripe webhooks processed",
	}, []string{"event_type", "status"})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "billing_http_request_duration_seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "path"})
)

// ── Config ────────────────────────────────────────────────────────────────

type Config struct {
	HTTPPort            int
	OTLPEndpoint        string
	StripeSecretKey     string
	StripeWebhookSecret string
	StripePriceBasic    string
	StripePricePro      string
	StripePriceBusiness string
	StripePriceEnterprise string
	FrontendURL         string
}

func loadConfig() (Config, error) {
	httpPort, err := getEnvInt("HTTP_PORT", 9093)
	if err != nil {
		return Config{}, fmt.Errorf("HTTP_PORT: %w", err)
	}
	return Config{
		HTTPPort:              httpPort,
		OTLPEndpoint:          getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317"),
		StripeSecretKey:       getEnv("STRIPE_SECRET_KEY", ""),
		StripeWebhookSecret:   getEnv("STRIPE_WEBHOOK_SECRET", ""),
		StripePriceBasic:      getEnv("STRIPE_PRICE_BASIC", ""),
		StripePricePro:        getEnv("STRIPE_PRICE_PRO", ""),
		StripePriceBusiness:   getEnv("STRIPE_PRICE_BUSINESS", ""),
		StripePriceEnterprise: getEnv("STRIPE_PRICE_ENTERPRISE", ""),
		FrontendURL:           getEnv("FRONTEND_URL", "https://app.youtuop-1.com"),
	}, nil
}

func main() {
	log, err := zap.NewProduction()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to init logger: %v\n", err)
		os.Exit(1)
	}
	defer log.Sync() //nolint:errcheck

	log.Info("starting billing service", zap.String("version", version))

	cfg, err := loadConfig()
	if err != nil {
		log.Fatal("invalid config", zap.Error(err))
	}

	if cfg.StripeSecretKey == "" {
		log.Fatal("STRIPE_SECRET_KEY is required")
	}
	if cfg.StripeWebhookSecret == "" {
		log.Fatal("STRIPE_WEBHOOK_SECRET is required")
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

	// ── Stripe ────────────────────────────────────────────────────────────
	stripeClient := stripeclient.New(cfg.StripeSecretKey, stripeclient.PriceIDs{
		Basic:      cfg.StripePriceBasic,
		Pro:        cfg.StripePricePro,
		Business:   cfg.StripePriceBusiness,
		Enterprise: cfg.StripePriceEnterprise,
	})

	// ── Webhook Handler ────────────────────────────────────────────────────
	webhookHandler := webhook.New(pgClient, log)

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
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ready")
	})

	// ── Stripe Webhook (PUBLIC — no JWT) ──────────────────────────────────
	mux.HandleFunc("POST /v1/billing/webhooks/stripe",
		makeStripeWebhookHandler(cfg.StripeWebhookSecret, webhookHandler, log))

	// ── Protected Endpoints (JWT required — enforced by Gateway) ──────────
	mux.HandleFunc("POST /v1/billing/subscriptions",
		makeCreateSubscriptionHandler(pgClient, stripeClient, log))

	mux.HandleFunc("GET /v1/billing/subscriptions",
		makeGetSubscriptionHandler(pgClient, log))

	mux.HandleFunc("POST /v1/billing/subscriptions/upgrade",
		makeUpgradeSubscriptionHandler(pgClient, stripeClient, log))

	mux.HandleFunc("POST /v1/billing/subscriptions/cancel",
		makeCancelSubscriptionHandler(pgClient, stripeClient, log))

	mux.HandleFunc("GET /v1/billing/invoices",
		makeListInvoicesHandler(pgClient, log))

	mux.HandleFunc("POST /v1/billing/portal",
		makePortalHandler(pgClient, stripeClient, cfg.FrontendURL, log))

	mux.HandleFunc("GET /v1/billing/usage",
		makeUsageSummaryHandler(pgClient, log))

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

// ── Handlers ──────────────────────────────────────────────────────────────

// makeStripeWebhookHandler — PUBLIC endpoint — Stripe بيبعت هنا مباشرة
// بيتحقق من الـ signature قبل أي معالجة
func makeStripeWebhookHandler(webhookSecret string, h *webhook.Handler, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		const maxBodySize = 65536 // 64KB
		r.Body = http.MaxBytesReader(w, r.Body, maxBodySize)

		payload, err := io.ReadAll(r.Body)
		if err != nil {
			log.Warn("webhook read body failed", zap.Error(err))
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}

		sigHeader := r.Header.Get("Stripe-Signature")
		event, err := stripeclient.ConstructWebhookEvent(payload, sigHeader, webhookSecret)
		if err != nil {
			log.Warn("webhook signature verification failed",
				zap.Error(err),
				zap.String("sig_header", sigHeader),
			)
			webhookProcessed.WithLabelValues("unknown", "signature_failed").Inc()
			http.Error(w, "invalid signature", http.StatusBadRequest)
			return
		}

		if err := h.Process(r.Context(), event, payload); err != nil {
			log.Error("webhook processing failed",
				zap.String("event_id", event.ID),
				zap.String("event_type", string(event.Type)),
				zap.Error(err),
			)
			webhookProcessed.WithLabelValues(string(event.Type), "error").Inc()
			// Stripe بيعيد المحاولة لو رجعنا 5xx
			http.Error(w, "processing failed", http.StatusInternalServerError)
			return
		}

		webhookProcessed.WithLabelValues(string(event.Type), "success").Inc()
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, `{"received":true}`)
	}
}

func makeCreateSubscriptionHandler(pg *postgres.Client, sc *stripeclient.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()

		// الـ tenant_id جاي من JWT claim عبر Gateway header
		tenantID := r.Header.Get("x-tenant-id")
		if tenantID == "" {
			jsonError(w, "missing tenant context", http.StatusBadRequest)
			return
		}

		var req struct {
			Plan string `json:"plan"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		if req.Plan == "" {
			jsonError(w, "plan is required", http.StatusBadRequest)
			return
		}

		// الـ tenant ID جاي من JWT claim عبر Gateway header
		tenantDBID := tenantID
		tenantName := r.Header.Get("x-tenant-slug") // للـ Stripe customer name
		if tenantName == "" {
			tenantName = tenantDBID
		}

		// جيب أو أنشئ Stripe customer
		stripeCustomerID, err := pg.GetStripeCustomerID(ctx, tenantDBID)
		if err != nil {
			// ينشئ customer جديد
			email := r.Header.Get("x-user-email")
			if email == "" {
				email = "billing@" + r.Header.Get("x-tenant-slug") + ".youtuop.com"
			}
			stripeCustomerID, err = sc.CreateCustomer(ctx, tenantDBID, tenantName, email)
			if err != nil {
				log.Error("create stripe customer failed", zap.Error(err))
				jsonError(w, "internal error", http.StatusInternalServerError)
				return
			}
			if err := pg.SetStripeCustomerID(ctx, tenantDBID, stripeCustomerID); err != nil {
				log.Warn("save stripe customer id failed", zap.Error(err))
			}
		}

		// أنشئ local subscription أولاً
		sub, err := pg.CreateSubscription(ctx, tenantDBID, req.Plan)
		if err != nil {
			log.Error("create local subscription failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}

		// أنشئ Stripe subscription
		stripeSub, err := sc.CreateSubscription(ctx, stripeCustomerID, req.Plan, 14)
		if err != nil {
			log.Error("create stripe subscription failed", zap.Error(err))
			jsonError(w, "stripe error", http.StatusInternalServerError)
			return
		}

		// اربط الـ Stripe subscription بالـ local subscription
		priceID, _ := sc.PriceIDForPlan(req.Plan)
		if err := pg.AttachStripeSubscription(ctx, sub.ID, stripeSub.ID, priceID); err != nil {
			log.Warn("attach stripe subscription failed", zap.Error(err))
		}

		subscriptionCreated.WithLabelValues(req.Plan).Inc()
		log.Info("subscription created",
			zap.String("tenant_id", tenantDBID),
			zap.String("plan", req.Plan),
			zap.String("stripe_sub_id", stripeSub.ID),
		)

		jsonOK(w, map[string]any{
			"subscription_id":        sub.ID,
			"stripe_subscription_id": stripeSub.ID,
			"plan":                   req.Plan,
			"status":                 sub.Status,
			"trial_end":              sub.TrialEnd,
		})
	}
}

func makeGetSubscriptionHandler(pg *postgres.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := r.Header.Get("x-tenant-id")
		if tenantID == "" {
			jsonError(w, "missing tenant context", http.StatusBadRequest)
			return
		}
		sub, err := pg.GetActiveSubscription(r.Context(), tenantID)
		if err != nil {
			jsonError(w, "no active subscription", http.StatusNotFound)
			return
		}
		jsonOK(w, sub)
	}
}

func makeUpgradeSubscriptionHandler(pg *postgres.Client, sc *stripeclient.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		tenantID := r.Header.Get("x-tenant-id")
		if tenantID == "" {
			jsonError(w, "missing tenant context", http.StatusBadRequest)
			return
		}

		var req struct {
			NewPlan string `json:"new_plan"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}

		sub, err := pg.GetActiveSubscription(ctx, tenantID)
		if err != nil {
			jsonError(w, "no active subscription", http.StatusNotFound)
			return
		}
		if sub.StripeSubscriptionID == nil {
			jsonError(w, "subscription not connected to Stripe", http.StatusBadRequest)
			return
		}

		_, err = sc.UpdateSubscriptionPlan(ctx, *sub.StripeSubscriptionID, req.NewPlan)
		if err != nil {
			log.Error("upgrade subscription failed", zap.Error(err))
			jsonError(w, "stripe error", http.StatusInternalServerError)
			return
		}

		log.Info("subscription upgraded",
			zap.String("tenant_id", tenantID),
			zap.String("new_plan", req.NewPlan),
		)
		jsonOK(w, map[string]string{"status": "upgrading", "new_plan": req.NewPlan})
	}
}

func makeCancelSubscriptionHandler(pg *postgres.Client, sc *stripeclient.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		tenantID := r.Header.Get("x-tenant-id")
		if tenantID == "" {
			jsonError(w, "missing tenant context", http.StatusBadRequest)
			return
		}

		sub, err := pg.GetActiveSubscription(ctx, tenantID)
		if err != nil {
			jsonError(w, "no active subscription", http.StatusNotFound)
			return
		}
		if sub.StripeSubscriptionID == nil {
			jsonError(w, "subscription not connected to Stripe", http.StatusBadRequest)
			return
		}

		if err := sc.CancelSubscription(ctx, *sub.StripeSubscriptionID, false); err != nil {
			log.Error("cancel subscription failed", zap.Error(err))
			jsonError(w, "stripe error", http.StatusInternalServerError)
			return
		}

		log.Info("subscription cancellation scheduled",
			zap.String("tenant_id", tenantID),
		)
		jsonOK(w, map[string]string{"status": "cancel_at_period_end"})
	}
}

func makeListInvoicesHandler(pg *postgres.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := r.Header.Get("x-tenant-id")
		if tenantID == "" {
			jsonError(w, "missing tenant context", http.StatusBadRequest)
			return
		}
		invoices, err := pg.ListInvoices(r.Context(), tenantID, 20)
		if err != nil {
			log.Error("list invoices failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]any{"invoices": invoices})
	}
}

func makePortalHandler(pg *postgres.Client, sc *stripeclient.Client, frontendURL string, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		tenantID := r.Header.Get("x-tenant-id")
		if tenantID == "" {
			jsonError(w, "missing tenant context", http.StatusBadRequest)
			return
		}

		customerID, err := pg.GetStripeCustomerID(ctx, tenantID)
		if err != nil {
			jsonError(w, "no billing account found", http.StatusNotFound)
			return
		}

		portalURL, err := sc.CreatePortalSession(ctx, customerID, frontendURL+"/settings/billing")
		if err != nil {
			log.Error("create portal session failed", zap.Error(err))
			jsonError(w, "stripe error", http.StatusInternalServerError)
			return
		}

		jsonOK(w, map[string]string{"url": portalURL})
	}
}

func makeUsageSummaryHandler(pg *postgres.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := r.Header.Get("x-tenant-id")
		if tenantID == "" {
			jsonError(w, "missing tenant context", http.StatusBadRequest)
			return
		}

		now := time.Now()
		from := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)

		summary, err := pg.GetUsageSummary(r.Context(), tenantID, from, now)
		if err != nil {
			log.Error("get usage summary failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]any{
			"period_start": from,
			"period_end":   now,
			"usage":        summary,
		})
	}
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
