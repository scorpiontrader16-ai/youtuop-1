package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/scorpiontrader16-ai/AmniX-Finance/internal/platform/profiling"
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

	"github.com/scorpiontrader16-ai/AmniX-Finance/services/notifications/internal/postgres"
	resendclient "github.com/scorpiontrader16-ai/AmniX-Finance/services/notifications/internal/resend"
)

var version = "dev"

// ── Metrics ───────────────────────────────────────────────────────────────

var (
	emailsSent = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "notifications_emails_sent_total",
		Help: "Total emails sent",
	}, []string{"template", "status"})

	inAppCreated = promauto.NewCounter(prometheus.CounterOpts{
		Name: "notifications_in_app_created_total",
		Help: "Total in-app notifications created",
	})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "notifications_http_request_duration_seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "path"})
)

// ── Config ────────────────────────────────────────────────────────────────

type Config struct {
	HTTPPort     int
	OTLPEndpoint string
	ResendAPIKey string
	FromName     string
	FromEmail    string
}

func loadConfig() (Config, error) {
	httpPort, err := getEnvInt("HTTP_PORT", 9094)
	if err != nil {
		return Config{}, fmt.Errorf("HTTP_PORT: %w", err)
	}
	return Config{
		HTTPPort:     httpPort,
		OTLPEndpoint: getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317"),
		ResendAPIKey: getEnv("RESEND_API_KEY", ""),
		FromName:     getEnv("EMAIL_FROM_NAME", "youtuop Platform"),
		FromEmail:    getEnv("EMAIL_FROM_ADDR", "noreply@amnixfinance.com"),
	}, nil
}

func main() {
	log, err := zap.NewProduction()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to init logger: %v\n", err)
		os.Exit(1)
	}
	defer log.Sync() //nolint:errcheck

	log.Info("starting notifications service", zap.String("version", version))

	cfg, err := loadConfig()
	if err != nil {
		log.Fatal("invalid config", zap.Error(err))
	}
	if cfg.ResendAPIKey == "" {
		log.Fatal("RESEND_API_KEY is required")
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

	// GAP-11: Continuous profiling
	profiling.Init(slogLogger, "platform.notifications")


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

	// ── Resend Client ─────────────────────────────────────────────────────
	emailClient := resendclient.New(cfg.ResendAPIKey, cfg.FromName, cfg.FromEmail)

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

	// ── Internal email sending (called by other services) ─────────────────
	mux.HandleFunc("POST /internal/notifications/email",
		makeSendEmailHandler(pgClient, emailClient, log))

	// ── In-app notifications ───────────────────────────────────────────────
	mux.HandleFunc("POST /internal/notifications/in-app",
		makeCreateInAppHandler(pgClient, log))

	// ── Public API (JWT protected via Gateway) ────────────────────────────
	mux.HandleFunc("GET /v1/notifications",
		makeListNotificationsHandler(pgClient, log))

	mux.HandleFunc("GET /v1/notifications/count",
		makeUnreadCountHandler(pgClient, log))

	mux.HandleFunc("POST /v1/notifications/{id}/read",
		makeMarkReadHandler(pgClient, log))

	mux.HandleFunc("POST /v1/notifications/read-all",
		makeMarkAllReadHandler(pgClient, log))

	mux.HandleFunc("GET /v1/notifications/preferences",
		makeGetPreferencesHandler(pgClient, log))

	mux.HandleFunc("PUT /v1/notifications/preferences",
		makeUpdatePreferencesHandler(pgClient, log))

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

// ── Handlers ──────────────────────────────────────────────────────────────

type sendEmailRequest struct {
	TenantID     *string        `json:"tenant_id"`
	UserID       *string        `json:"user_id"`
	To           string         `json:"to"`
	TemplateName string         `json:"template_name"`
	Data         map[string]any `json:"data"`
}

func makeSendEmailHandler(pg *postgres.Client, ec *resendclient.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()

		var req sendEmailRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		if req.To == "" || req.TemplateName == "" {
			jsonError(w, "to and template_name are required", http.StatusBadRequest)
			return
		}

		// جيب الـ template من DB
		tmpl, err := pg.GetTemplate(ctx, req.TemplateName)
		if err != nil {
			log.Warn("template not found", zap.String("name", req.TemplateName))
			jsonError(w, "template not found", http.StatusNotFound)
			return
		}

		// Render subject
		subject := ""
		if tmpl.Subject != nil {
			subject, err = resendclient.RenderText(*tmpl.Subject, req.Data)
			if err != nil {
				log.Error("render subject failed", zap.Error(err))
				jsonError(w, "template render failed", http.StatusInternalServerError)
				return
			}
		}

		// Render body
		htmlBody, err := resendclient.RenderHTML(tmpl.BodyHTML, req.Data)
		if err != nil {
			log.Error("render html failed", zap.Error(err))
			jsonError(w, "template render failed", http.StatusInternalServerError)
			return
		}
		textBody, err := resendclient.RenderText(tmpl.BodyText, req.Data)
		if err != nil {
			log.Error("render text failed", zap.Error(err))
			jsonError(w, "template render failed", http.StatusInternalServerError)
			return
		}

		// Send via Resend
		result, sendErr := ec.Send(ctx, req.To, subject, htmlBody, textBody)

		// Log the result
		status := "sent"
		if sendErr != nil {
			status = "failed"
		}
		resendID := ""
		if result != nil {
			resendID = result.ID
		}
		pg.LogEmail(ctx, req.TenantID, req.UserID, resendID, req.TemplateName, req.To, subject, status, sendErr) //nolint:errcheck

		if sendErr != nil {
			log.Error("send email failed",
				zap.String("template", req.TemplateName),
				zap.String("to", req.To),
				zap.Error(sendErr),
			)
			emailsSent.WithLabelValues(req.TemplateName, "failed").Inc()
			jsonError(w, "email send failed", http.StatusInternalServerError)
			return
		}

		emailsSent.WithLabelValues(req.TemplateName, "sent").Inc()
		log.Info("email sent",
			zap.String("template", req.TemplateName),
			zap.String("to", req.To),
			zap.String("resend_id", resendID),
		)
		jsonOK(w, map[string]string{"id": resendID, "status": "sent"})
	}
}

type createInAppRequest struct {
	TenantID string         `json:"tenant_id"`
	UserID   string         `json:"user_id"`
	Type     string         `json:"type"`
	Title    string         `json:"title"`
	Body     string         `json:"body"`
	Data     map[string]any `json:"data"`
}

func makeCreateInAppHandler(pg *postgres.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req createInAppRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		if req.TenantID == "" || req.UserID == "" || req.Title == "" {
			jsonError(w, "tenant_id, user_id, title are required", http.StatusBadRequest)
			return
		}

		n, err := pg.CreateNotification(r.Context(),
			req.TenantID, req.UserID, req.Type,
			req.Title, req.Body, req.Data,
		)
		if err != nil {
			log.Error("create in-app notification failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}

		inAppCreated.Inc()
		jsonOK(w, n)
	}
}

func makeListNotificationsHandler(pg *postgres.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := r.Header.Get("x-user-id")
		if userID == "" {
			jsonError(w, "missing user context", http.StatusBadRequest)
			return
		}
		notifs, err := pg.ListUnread(r.Context(), userID, 50)
		if err != nil {
			log.Error("list notifications failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]any{"notifications": notifs})
	}
}

func makeUnreadCountHandler(pg *postgres.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := r.Header.Get("x-user-id")
		if userID == "" {
			jsonError(w, "missing user context", http.StatusBadRequest)
			return
		}
		count, err := pg.UnreadCount(r.Context(), userID)
		if err != nil {
			log.Error("unread count failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]int{"unread": count})
	}
}

func makeMarkReadHandler(pg *postgres.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := r.Header.Get("x-user-id")
		notifID := r.PathValue("id")
		if userID == "" || notifID == "" {
			jsonError(w, "missing context", http.StatusBadRequest)
			return
		}
		if err := pg.MarkRead(r.Context(), notifID, userID); err != nil {
			jsonError(w, "not found", http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

func makeMarkAllReadHandler(pg *postgres.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := r.Header.Get("x-user-id")
		if userID == "" {
			jsonError(w, "missing user context", http.StatusBadRequest)
			return
		}
		if err := pg.MarkAllRead(r.Context(), userID); err != nil {
			log.Error("mark all read failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

func makeGetPreferencesHandler(pg *postgres.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := r.Header.Get("x-user-id")
		tenantID := r.Header.Get("x-tenant-id")
		if userID == "" || tenantID == "" {
			jsonError(w, "missing user context", http.StatusBadRequest)
			return
		}
		prefs, err := pg.GetPreferences(r.Context(), userID, tenantID)
		if err != nil {
			log.Error("get preferences failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, prefs)
	}
}

func makeUpdatePreferencesHandler(pg *postgres.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := r.Header.Get("x-user-id")
		tenantID := r.Header.Get("x-tenant-id")
		if userID == "" || tenantID == "" {
			jsonError(w, "missing user context", http.StatusBadRequest)
			return
		}

		var prefs postgres.NotificationPreferences
		if err := json.NewDecoder(r.Body).Decode(&prefs); err != nil {
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		prefs.UserID = userID
		prefs.TenantID = tenantID

		if err := pg.UpsertPreferences(r.Context(), &prefs); err != nil {
			log.Error("update preferences failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}
		jsonOK(w, prefs)
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
