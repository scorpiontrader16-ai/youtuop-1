package main

import (
	"github.com/scorpiontrader16-ai/youtuop-1/services/realtime/internal/profiling"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/coder/websocket"
	"github.com/golang-jwt/jwt/v5"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"log/slog"

	"go.uber.org/zap"

	"github.com/scorpiontrader16-ai/youtuop-1/services/realtime/internal/consumer"
	"github.com/scorpiontrader16-ai/youtuop-1/services/realtime/internal/hub"
)

var version = "dev"

// ── Metrics ───────────────────────────────────────────────────────────────

var (
	wsConnections = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "realtime_websocket_connections",
		Help: "Current active WebSocket connections",
	})

	wsMessagesDelivered = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "realtime_messages_delivered_total",
		Help: "Total WebSocket messages delivered",
	}, []string{"channel"})

	wsConnectionErrors = promauto.NewCounter(prometheus.CounterOpts{
		Name: "realtime_connection_errors_total",
		Help: "Total WebSocket connection errors",
	})

	httpRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "realtime_http_request_duration_seconds",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "path"})
)

// ── Config ────────────────────────────────────────────────────────────────

type Config struct {
	HTTPPort     int
	OTLPEndpoint string
	JWTIssuer    string
	JWKSEndpoint string
}

func loadConfig() (Config, error) {
	httpPort, err := getEnvInt("HTTP_PORT", 9099)
	if err != nil {
		return Config{}, fmt.Errorf("HTTP_PORT: %w", err)
	}
	return Config{
		HTTPPort:     httpPort,
		OTLPEndpoint: getEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317"),
		JWTIssuer:    getEnv("JWT_ISSUER", "https://auth.youtuop-1.com"),
		JWKSEndpoint: getEnv("JWKS_ENDPOINT", "http://auth-stable.platform.svc.cluster.local:9092/.well-known/jwks.json"),
	}, nil
}

// ── JWT Claims ────────────────────────────────────────────────────────────

type Claims struct {
	Email      string `json:"email"`
	TenantID   string `json:"tid"`
	TenantSlug string `json:"tslug"`
	Tier       string `json:"tier"`
	Role       string `json:"role"`
	jwt.RegisteredClaims
}

func (c *Claims) UserID() string { return c.Subject }

// ── JWKS Cache ─────────────────────────────────────────────────────────────
// نستبدل ParseUnverified بـ JWKS verification — يتحقق من الـ signature فعلياً
type jwksCache struct {
	mu       sync.RWMutex
	keys     map[string]any
	endpoint string
	expiry   time.Time
}

func newJWKSCache(endpoint string) *jwksCache {
	return &jwksCache{endpoint: endpoint, keys: make(map[string]any)}
}

func (c *jwksCache) getKey(kid string) (any, error) {
	c.mu.RLock()
	if time.Now().Before(c.expiry) {
		if key, ok := c.keys[kid]; ok {
			c.mu.RUnlock()
			return key, nil
		}
	}
	c.mu.RUnlock()
	return c.refresh(kid)
}

func (c *jwksCache) refresh(kid string) (any, error) {
	resp, err := http.Get(c.endpoint) //nolint:noctx
	if err != nil {
		return nil, fmt.Errorf("fetch jwks: %w", err)
	}
	defer resp.Body.Close()
	var set struct {
		Keys []json.RawMessage `json:"keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&set); err != nil {
		return nil, fmt.Errorf("decode jwks: %w", err)
	}
	c.mu.Lock()
	c.keys = make(map[string]any)
	for _, raw := range set.Keys {
		var hdr struct {
			Kid string `json:"kid"`
			Kty string `json:"kty"`
			N   string `json:"n"`
			E   string `json:"e"`
			X   string `json:"x"`
			Y   string `json:"y"`
		}
		if err := json.Unmarshal(raw, &hdr); err != nil {
			continue
		}
		switch hdr.Kty {
		case "RSA":
			if key, err := jwkRSA(hdr.N, hdr.E); err == nil {
				c.keys[hdr.Kid] = key
			}
		case "EC":
			if key, err := jwkEC(hdr.X, hdr.Y); err == nil {
				c.keys[hdr.Kid] = key
			}
		}
	}
	c.expiry = time.Now().Add(5 * time.Minute)
	c.mu.Unlock()
	if key, ok := c.keys[kid]; ok {
		return key, nil
	}
	return nil, fmt.Errorf("kid %q not found in jwks", kid)
}

func jwkRSA(nB64, eB64 string) (*rsa.PublicKey, error) {
	nb, err := base64.RawURLEncoding.DecodeString(nB64)
	if err != nil { return nil, err }
	eb, err := base64.RawURLEncoding.DecodeString(eB64)
	if err != nil { return nil, err }
	return &rsa.PublicKey{N: new(big.Int).SetBytes(nb), E: int(new(big.Int).SetBytes(eb).Int64())}, nil
}

func jwkEC(xB64, yB64 string) (*ecdsa.PublicKey, error) {
	xb, err := base64.RawURLEncoding.DecodeString(xB64)
	if err != nil { return nil, err }
	yb, err := base64.RawURLEncoding.DecodeString(yB64)
	if err != nil { return nil, err }
	return &ecdsa.PublicKey{Curve: elliptic.P256(), X: new(big.Int).SetBytes(xb), Y: new(big.Int).SetBytes(yb)}, nil
}

func main() {
	log, err := zap.NewProduction()
	if err != nil {

	// GAP-11: Continuous profiling
	profiling.Init(slog.Default())

	// GAP-11: Continuous profiling
	profiling.Init(slog.Default())

	// GAP-11: Continuous profiling
	profiling.Init(slog.Default())

	// GAP-11: Continuous profiling
	profiling.Init(slog.Default())

	// GAP-11: Continuous profiling
	profiling.Init(slog.Default())
		fmt.Fprintf(os.Stderr, "failed to init logger: %v\n", err)
		os.Exit(1)
	}
	defer log.Sync() //nolint:errcheck

	log.Info("starting realtime service", zap.String("version", version))

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

	// ── Hub ───────────────────────────────────────────────────────────────
	h := hub.New(log)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go h.Run(ctx)

	// ── Redpanda Consumer ─────────────────────────────────────────────────

	consumerCfg := consumer.ConfigFromEnv()
	kConsumer, err := consumer.New(consumerCfg, h, log)
	if err != nil {
		log.Fatal("failed to create kafka consumer", zap.Error(err))
	}
	go kConsumer.Run(ctx)

	// ── HTTP Routes ────────────────────────────────────────────────────────
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, `{"status":"ready","connections":%d,"tenants":%d}`,
			h.ConnectedClients(), h.ConnectedTenants())
	})

	// ── WebSocket Endpoint ────────────────────────────────────────────────
	// /ws?token=<jwt>
	mux.HandleFunc("/ws", makeWSHandler(cfg, h, log))

	httpServer := &http.Server{
		Addr:         fmt.Sprintf(":%d", cfg.HTTPPort),
		Handler:      withMetrics(mux),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 0, // WebSocket — لا timeout للـ write
		IdleTimeout:  120 * time.Second,
	}

	go func() {
		log.Info("HTTP+WebSocket server started", zap.Int("port", cfg.HTTPPort))
		if err := httpServer.ListenAndServe(); err != http.ErrServerClosed {
			log.Fatal("server failed", zap.Error(err))
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	sig := <-quit
	log.Info("shutting down", zap.String("signal", sig.String()))
	cancel()

	shutCtx, shutCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutCancel()
	if err := httpServer.Shutdown(shutCtx); err != nil {
		log.Error("HTTP shutdown error", zap.Error(err))
	}
	log.Info("shutdown complete")
}

// ── WebSocket Handler ─────────────────────────────────────────────────────

func makeWSHandler(cfg Config, h *hub.Hub, log *zap.Logger) http.HandlerFunc {
	cache := newJWKSCache(cfg.JWKSEndpoint)
	return func(w http.ResponseWriter, r *http.Request) {
		// 1. Extract and validate JWT
		token := r.URL.Query().Get("token")
		if token == "" {
			token = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		}
		if token == "" {
			http.Error(w, "missing token", http.StatusUnauthorized)
			return
		}

		claims, err := validateJWT(token, cfg.JWTIssuer, cache)
		if err != nil {
			log.Warn("invalid JWT", zap.Error(err))
			http.Error(w, "invalid token", http.StatusUnauthorized)
			wsConnectionErrors.Inc()
			return
		}

		// 2. Upgrade to WebSocket
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			OriginPatterns: []string{
				"app.youtuop-1.com",
				"developers.youtuop-1.com",
				"localhost:*",
			},
		})
		if err != nil {
			log.Error("websocket upgrade failed", zap.Error(err))
			wsConnectionErrors.Inc()
			return
		}

		// 3. Register client
		connCtx, connCancel := context.WithCancel(r.Context())
		defer connCancel()

		client := h.RegisterClient(connCtx, claims.UserID(), claims.TenantID, conn)
		defer h.UnregisterClient(client)

		wsConnections.Inc()
		defer wsConnections.Dec()

		log.Info("websocket client connected",
			zap.String("user_id", claims.UserID()),
			zap.String("tenant_id", claims.TenantID),
			zap.String("client_id", client.ID),
		)

		// 4. Send welcome message
		welcome := map[string]any{
			"type":      "connected",
			"client_id": client.ID,
			"tenant_id": claims.TenantID,
			"channels":  []string{"markets", "alerts", "agents", "system"},
		}
		if err := h.SendToClient(client, welcome); err != nil {
			log.Warn("send welcome failed", zap.Error(err))
		}

		// 5. Read loop — يستقبل subscription requests من الـ client
		for {
			_, data, err := conn.Read(connCtx)
			if err != nil {
				break
			}

			var msg struct {
				Type    string `json:"type"`
				Channel string `json:"channel"`
			}
			if err := json.Unmarshal(data, &msg); err != nil {
				continue
			}

			switch msg.Type {
			case "subscribe":
				client.Subscribe(msg.Channel)
				h.SendToClient(client, map[string]any{ //nolint:errcheck
					"type":    "subscribed",
					"channel": msg.Channel,
				})
			case "unsubscribe":
				client.Unsubscribe(msg.Channel)
			case "pong":
				// keep-alive response — ignore
			}
		}

		log.Info("websocket client disconnected",
			zap.String("client_id", client.ID),
			zap.String("tenant_id", claims.TenantID),
		)
	}
}

// validateJWT — يتحقق من الـ JWT signature عبر JWKS من auth service
// يدعم RS256 و ES256 — يرفض أي method آخر بما فيه "none"
func validateJWT(tokenStr, issuer string, cache *jwksCache) (*Claims, error) {
	t, err := jwt.ParseWithClaims(tokenStr, &Claims{}, func(t *jwt.Token) (any, error) {
		switch t.Method.(type) {
		case *jwt.SigningMethodRSA:
		case *jwt.SigningMethodECDSA:
		default:
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		kid, _ := t.Header["kid"].(string)
		return cache.getKey(kid)
	}, jwt.WithIssuer(issuer), jwt.WithExpirationRequired())
	if err != nil {
		return nil, fmt.Errorf("invalid token: %w", err)
	}
	claims, ok := t.Claims.(*Claims)
	if !ok || !t.Valid {
		return nil, errors.New("malformed claims")
	}
	if claims.TenantID == "" {
		return nil, errors.New("missing tenant_id claim")
	}
	if claims.Subject == "" {
		return nil, errors.New("missing sub claim")
	}
	return claims, nil
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
