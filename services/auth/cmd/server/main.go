package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
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

	appjwt "github.com/aminpola2001-ctrl/youtuop/services/auth/internal/jwt"
	"github.com/aminpola2001-ctrl/youtuop/services/auth/internal/postgres"
	"github.com/aminpola2001-ctrl/youtuop/services/auth/internal/rbac"
)

var version = "dev"

// ── Metrics ───────────────────────────────────────────────────────────────

var (
	loginTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "auth_login_total",
		Help: "Total login attempts",
	}, []string{"status"})

	tokenIssued = promauto.NewCounter(prometheus.CounterOpts{
		Name: "auth_token_issued_total",
		Help: "Total JWT tokens issued",
	})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "auth_http_request_duration_seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "path"})
)

// ── Config ────────────────────────────────────────────────────────────────

type Config struct {
	HTTPPort          int
	OTLPEndpoint      string
	KeycloakURL       string
	KeycloakRealm     string
	KeycloakClientID  string
	JWTIssuer         string
	JWTPrivateKeyPath string
}

func loadConfig() (Config, error) {
	httpPort, err := getEnvInt("HTTP_PORT", 9092)
	if err != nil {
		return Config{}, fmt.Errorf("HTTP_PORT: %w", err)
	}
	return Config{
		HTTPPort:          httpPort,
		OTLPEndpoint:      getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317"),
		KeycloakURL:       getEnv("KEYCLOAK_URL", "http://keycloak:8080"),
		KeycloakRealm:     getEnv("KEYCLOAK_REALM", "youtuop"),
		KeycloakClientID:  getEnv("KEYCLOAK_CLIENT_ID", "youtuop-backend"),
		JWTIssuer:         getEnv("JWT_ISSUER", "https://auth.youtuop-1.com"),
		JWTPrivateKeyPath: getEnv("JWT_PRIVATE_KEY_PATH", "/secrets/jwt/private.pem"),
	}, nil
}

func main() {
	log, err := zap.NewProduction()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to init logger: %v\n", err)
		os.Exit(1)
	}
	defer log.Sync() //nolint:errcheck

	log.Info("starting auth service", zap.String("version", version))

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
		Addr:     getEnv("REDIS_ADDR", "redis:6379"),
		Password: getEnv("REDIS_PASSWORD", ""),
	})
	if err := rdb.Ping(startupCtx).Err(); err != nil {
		log.Fatal("redis unavailable", zap.Error(err))
	}

	// ── JWT Service ────────────────────────────────────────────────────────
	privateKeyPEM, err := os.ReadFile(cfg.JWTPrivateKeyPath)
	if err != nil {
		log.Fatal("reading JWT private key",
			zap.Error(err),
			zap.String("path", cfg.JWTPrivateKeyPath),
		)
	}
	jwtSvc, err := appjwt.NewService(privateKeyPEM, cfg.JWTIssuer)
	if err != nil {
		log.Fatal("creating JWT service", zap.Error(err))
	}

	// ── RBAC Engine ────────────────────────────────────────────────────────
	rbacEngine := rbac.NewEngine(pgClient, rdb)

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

	// JWKS — الـ services التانية بتجيب الـ public key من هنا
	mux.HandleFunc("GET /.well-known/jwks.json", func(w http.ResponseWriter, _ *http.Request) {
		jwks, err := jwtSvc.JWKS()
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "public, max-age=3600")
		w.Write(jwks) //nolint:errcheck
	})

	mux.HandleFunc("POST /v1/auth/login",   makeLoginHandler(cfg, pgClient, jwtSvc, rbacEngine, log))
	mux.HandleFunc("POST /v1/auth/refresh", makeRefreshHandler(pgClient, log))
	mux.HandleFunc("POST /v1/auth/logout",  makeLogoutHandler(pgClient, jwtSvc, log))

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

type loginRequest struct {
	Code        string `json:"code"`
	RedirectURI string `json:"redirect_uri"`
	TenantSlug  string `json:"tenant_slug"`
}

type tokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
	TokenType    string `json:"token_type"`
}

type keycloakTokens struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
}

type keycloakUserInfo struct {
	Sub        string `json:"sub"`
	Email      string `json:"email"`
	GivenName  string `json:"given_name"`
	FamilyName string `json:"family_name"`
	Picture    string `json:"picture"`
}

func makeLoginHandler(
	cfg Config,
	pg *postgres.Client,
	jwtSvc *appjwt.Service,
	rbacEngine *rbac.Engine,
	log *zap.Logger,
) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()

		var req loginRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			loginTotal.WithLabelValues("bad_request").Inc()
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}

		// 1. Resolve tenant
		tenant, err := pg.GetTenantBySlug(ctx, req.TenantSlug)
		if err != nil {
			loginTotal.WithLabelValues("tenant_not_found").Inc()
			jsonError(w, "tenant not found", http.StatusForbidden)
			return
		}

		// 2. Exchange code with Keycloak
		kcTokens, err := exchangeCode(ctx, cfg, req.Code, req.RedirectURI)
		if err != nil {
			log.Warn("keycloak exchange failed", zap.Error(err))
			loginTotal.WithLabelValues("keycloak_error").Inc()
			jsonError(w, "authentication failed", http.StatusUnauthorized)
			return
		}

		// 3. Get user info
		kcUser, err := getKeycloakUserInfo(ctx, cfg, kcTokens.AccessToken)
		if err != nil {
			log.Warn("keycloak userinfo failed", zap.Error(err))
			loginTotal.WithLabelValues("userinfo_error").Inc()
			jsonError(w, "failed to get user info", http.StatusUnauthorized)
			return
		}

		// 4. Upsert user
		user, err := pg.UpsertByKeycloakID(ctx,
			kcUser.Sub, kcUser.Email,
			kcUser.GivenName, kcUser.FamilyName, kcUser.Picture,
		)
		if err != nil {
			log.Error("upsert user failed", zap.Error(err))
			loginTotal.WithLabelValues("db_error").Inc()
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}

		// 5. Get or assign role
		role, err := pg.GetUserRole(ctx, user.ID, tenant.ID)
		if err != nil {
			role = "viewer"
			if assignErr := pg.AssignRole(ctx, user.ID, tenant.ID, role); assignErr != nil {
				log.Warn("assign default role failed", zap.Error(assignErr))
			}
		}

		// 6. Load permissions (role + plan)
		perms, err := rbacEngine.GetPermissions(ctx, user.ID, tenant.ID, tenant.Plan)
		if err != nil {
			log.Error("load permissions failed", zap.Error(err))
			perms = []string{}
		}

		// 7. Create session
		sessionID, err := pg.CreateSession(ctx,
			user.ID, tenant.ID,
			r.Header.Get("X-Device-Fingerprint"),
			r.RemoteAddr,
			r.Header.Get("User-Agent"),
			time.Now().Add(appjwt.RefreshTokenTTL),
		)
		if err != nil {
			log.Error("create session failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}

		// 8. Issue youtuop JWT — M8 + M9 + M10 في token واحد
		token, err := jwtSvc.IssueAccessToken(appjwt.IssueInput{
			UserID:      user.ID,
			Email:       user.Email,
			SessionID:   sessionID,
			TenantID:    tenant.ID,
			TenantSlug:  tenant.Slug,
			Plan:        tenant.Plan,
			Role:        role,
			Permissions: perms,
		})
		if err != nil {
			log.Error("JWT issuance failed", zap.Error(err))
			jsonError(w, "internal error", http.StatusInternalServerError)
			return
		}

		// 9. Store refresh token (hashed)
		rawRefresh := generateToken()
		if storeErr := pg.StoreRefreshToken(ctx, sessionID,
			postgres.HashToken(rawRefresh),
			time.Now().Add(appjwt.RefreshTokenTTL),
		); storeErr != nil {
			log.Warn("store refresh token failed", zap.Error(storeErr))
		}

		loginTotal.WithLabelValues("success").Inc()
		tokenIssued.Inc()
		log.Info("user logged in",
			zap.String("user_id", user.ID),
			zap.String("tenant", tenant.Slug),
			zap.String("role", role),
		)

		jsonOK(w, tokenResponse{
			AccessToken:  token,
			RefreshToken: rawRefresh,
			ExpiresIn:    int(appjwt.AccessTokenTTL.Seconds()),
			TokenType:    "Bearer",
		})
	}
}

func makeRefreshHandler(pg *postgres.Client, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			RefreshToken string `json:"refresh_token"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			jsonError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		_, err := pg.ConsumeRefreshToken(r.Context(), postgres.HashToken(body.RefreshToken))
		if err != nil {
			log.Warn("refresh token invalid", zap.Error(err))
			jsonError(w, "invalid or expired refresh token", http.StatusUnauthorized)
			return
		}
		// TODO: load session + reissue access token
		http.Error(w, "not implemented", http.StatusNotImplemented)
	}
}

func makeLogoutHandler(pg *postgres.Client, jwtSvc *appjwt.Service, log *zap.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		if !strings.HasPrefix(authHeader, "Bearer ") {
			jsonError(w, "missing authorization", http.StatusUnauthorized)
			return
		}
		claims, err := jwtSvc.Validate(strings.TrimPrefix(authHeader, "Bearer "))
		if err != nil {
			jsonError(w, "invalid token", http.StatusUnauthorized)
			return
		}
		// claims.UserID() يرجع RegisteredClaims.Subject
		if revokeErr := pg.RevokeSession(r.Context(), claims.SessionID, claims.UserID(), "logout"); revokeErr != nil {
			log.Warn("revoke session failed", zap.Error(revokeErr))
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

// ── Keycloak ──────────────────────────────────────────────────────────────

func exchangeCode(ctx context.Context, cfg Config, code, redirectURI string) (*keycloakTokens, error) {
	tokenURL := fmt.Sprintf("%s/realms/%s/protocol/openid-connect/token",
		cfg.KeycloakURL, cfg.KeycloakRealm)

	data := url.Values{}
	data.Set("grant_type", "authorization_code")
	data.Set("client_id", cfg.KeycloakClientID)
	data.Set("client_secret", os.Getenv("KEYCLOAK_CLIENT_SECRET"))
	data.Set("code", code)
	data.Set("redirect_uri", redirectURI)

	req, err := http.NewRequestWithContext(ctx, "POST", tokenURL, strings.NewReader(data.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return nil, fmt.Errorf("keycloak request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("keycloak %d: %s", resp.StatusCode, string(body))
	}

	var tokens keycloakTokens
	return &tokens, json.NewDecoder(resp.Body).Decode(&tokens)
}

func getKeycloakUserInfo(ctx context.Context, cfg Config, accessToken string) (*keycloakUserInfo, error) {
	userInfoURL := fmt.Sprintf("%s/realms/%s/protocol/openid-connect/userinfo",
		cfg.KeycloakURL, cfg.KeycloakRealm)

	req, err := http.NewRequestWithContext(ctx, "GET", userInfoURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)

	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var u keycloakUserInfo
	return &u, json.NewDecoder(resp.Body).Decode(&u)
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

func generateToken() string {
	b := make([]byte, 32)
	rand.Read(b) //nolint:errcheck
	return base64.RawURLEncoding.EncodeToString(b)
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
