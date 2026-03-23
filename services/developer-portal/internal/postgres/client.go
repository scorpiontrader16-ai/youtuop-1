package postgres

import (
	"context"
	"database/sql"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"

	"github.com/google/uuid"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

var ErrNotFound  = errors.New("not found")
var ErrDuplicate = errors.New("duplicate")

// ── Config ────────────────────────────────────────────────────────────────

type Config struct {
	Host         string
	Port         int
	Database     string
	User         string
	Password     string
	SSLMode      string
	MaxOpenConns int
	MaxIdleConns int
	ConnLifetime time.Duration
}

func ConfigFromEnv() Config {
	return Config{
		Host:         getEnv("POSTGRES_HOST", "localhost"),
		Port:         getEnvInt("POSTGRES_PORT", 5432),
		Database:     getEnv("POSTGRES_DB", "platform"),
		User:         getEnv("POSTGRES_USER", "platform"),
		Password:     getEnv("POSTGRES_PASSWORD", "platform"),
		SSLMode:      getEnv("POSTGRES_SSL_MODE", "disable"),
		MaxOpenConns: getEnvInt("POSTGRES_MAX_OPEN_CONNS", 10),
		MaxIdleConns: getEnvInt("POSTGRES_MAX_IDLE_CONNS", 3),
		ConnLifetime: time.Hour,
	}
}

func (c Config) DSN() string {
	return fmt.Sprintf(
		"host=%s port=%d dbname=%s user=%s password=%s sslmode=%s",
		c.Host, c.Port, c.Database, c.User, c.Password, c.SSLMode,
	)
}

// ── Client ────────────────────────────────────────────────────────────────

type Client struct {
	db     *sql.DB
	logger *slog.Logger
}

func New(ctx context.Context, cfg Config, logger *slog.Logger) (*Client, error) {
	if logger == nil {
		logger = slog.Default()
	}
	db, err := sql.Open("pgx", cfg.DSN())
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}
	db.SetMaxOpenConns(cfg.MaxOpenConns)
	db.SetMaxIdleConns(cfg.MaxIdleConns)
	db.SetConnMaxLifetime(cfg.ConnLifetime)
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}
	logger.Info("postgres connected", "host", cfg.Host, "database", cfg.Database)
	return &Client{db: db, logger: logger}, nil
}

func WaitForPostgres(ctx context.Context, cfg Config, logger *slog.Logger) (*Client, error) {
	if logger == nil {
		logger = slog.Default()
	}
	var lastErr error
	for attempt := 1; attempt <= 30; attempt++ {
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("context cancelled: %w", ctx.Err())
		default:
		}
		c, err := New(ctx, cfg, logger)
		if err == nil {
			return c, nil
		}
		lastErr = err
		logger.Warn("postgres not ready", "attempt", attempt, "error", err)
		time.Sleep(2 * time.Second)
	}
	return nil, fmt.Errorf("postgres not ready after 60s: %w", lastErr)
}

func (c *Client) Migrate(ctx context.Context) error {
	goose.SetLogger(goose.NopLogger())
	goose.SetBaseFS(migrationsFS)
	if err := goose.SetDialect("postgres"); err != nil {
		return fmt.Errorf("set goose dialect: %w", err)
	}
	if err := goose.UpContext(ctx, c.db, "migrations"); err != nil {
		return fmt.Errorf("run migrations: %w", err)
	}
	c.logger.Info("developer-portal migrations applied")
	return nil
}

func (c *Client) DB() *sql.DB  { return c.db }
func (c *Client) Close() error { return c.db.Close() }

func (c *Client) SetTenantContext(ctx context.Context, tenantID string) error {
	_, err := c.db.ExecContext(ctx, "SELECT set_config('app.tenant_id', $1, true)", tenantID)
	return err
}

// ── Domain Types ──────────────────────────────────────────────────────────

type APIKey struct {
	ID           string
	UserID       string
	TenantID     string
	KeyPrefix    string
	Name         string
	Description  *string
	Scopes       []string
	Environment  string
	RateLimit    int
	RequestCount int64
	ExpiresAt    *time.Time
	LastUsed     *time.Time
	Revoked      bool
	CreatedAt    time.Time
}

type WebhookEndpoint struct {
	ID         string
	TenantID   string
	UserID     string
	Name       string
	URL        string
	Events     []string
	Enabled    bool
	RetryCount int
	TimeoutMS  int
	CreatedAt  time.Time
	UpdatedAt  time.Time
}

type UsageStats struct {
	TotalCalls    int64
	SuccessCalls  int64
	ErrorCalls    int64
	AvgDurationMS int
	TotalBytesOut int64
}

// ── API Keys ──────────────────────────────────────────────────────────────

func (c *Client) CreateAPIKey(ctx context.Context,
	userID, tenantID, name, description, environment, keyPrefix, keyHash string,
	scopes []string, expiresAt *time.Time, rateLimit int,
) (*APIKey, error) {
	const q = `
		INSERT INTO api_keys
			(id, user_id, tenant_id, name, description, environment,
			 key_prefix, key_hash, scopes, expires_at, rate_limit)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
		RETURNING id, user_id, tenant_id, key_prefix, name, description,
		          scopes, environment, rate_limit, request_count,
		          expires_at, last_used, revoked, created_at`

	k := &APIKey{}
	err := c.db.QueryRowContext(ctx, q,
		uuid.NewString(), userID, tenantID, name, nullStr(description),
		environment, keyPrefix, keyHash, scopes, expiresAt, rateLimit,
	).Scan(
		&k.ID, &k.UserID, &k.TenantID, &k.KeyPrefix, &k.Name, &k.Description,
		(*[]string)(nil), &k.Environment, &k.RateLimit, &k.RequestCount,
		&k.ExpiresAt, &k.LastUsed, &k.Revoked, &k.CreatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("create api key: %w", err)
	}
	k.Scopes = scopes
	return k, nil
}

func (c *Client) ListAPIKeys(ctx context.Context, userID, tenantID string) ([]*APIKey, error) {
	const q = `
		SELECT id, user_id, tenant_id, key_prefix, name, description,
		       scopes, environment, rate_limit, request_count,
		       expires_at, last_used, revoked, created_at
		FROM api_keys
		WHERE user_id = $1 AND tenant_id = $2 AND NOT revoked
		ORDER BY created_at DESC`

	rows, err := c.db.QueryContext(ctx, q, userID, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var keys []*APIKey
	for rows.Next() {
		k := &APIKey{}
		if err := rows.Scan(
			&k.ID, &k.UserID, &k.TenantID, &k.KeyPrefix, &k.Name, &k.Description,
			(*[]string)(nil), &k.Environment, &k.RateLimit, &k.RequestCount,
			&k.ExpiresAt, &k.LastUsed, &k.Revoked, &k.CreatedAt,
		); err != nil {
			return nil, err
		}
		keys = append(keys, k)
	}
	return keys, rows.Err()
}

func (c *Client) RevokeAPIKey(ctx context.Context, keyID, userID string) error {
	tag, err := c.db.ExecContext(ctx, `
		UPDATE api_keys SET revoked = TRUE
		WHERE id = $1 AND user_id = $2 AND NOT revoked`,
		keyID, userID,
	)
	if err != nil {
		return err
	}
	n, _ := tag.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// IncrementUsage يزيد عداد الـ requests بشكل atomic
func (c *Client) IncrementUsage(ctx context.Context, keyHash string) error {
	_, err := c.db.ExecContext(ctx, `
		UPDATE api_keys
		SET request_count = request_count + 1, last_used = NOW()
		WHERE key_hash = $1 AND NOT revoked`,
		keyHash,
	)
	return err
}

// ValidateAPIKey يتحقق من الـ key ويرجع الـ tenant info
func (c *Client) ValidateAPIKey(ctx context.Context, keyHash string) (userID, tenantID, environment string, scopes []string, err error) {
	err = c.db.QueryRowContext(ctx, `
		SELECT user_id, tenant_id, environment, scopes
		FROM api_keys
		WHERE key_hash = $1
		  AND NOT revoked
		  AND (expires_at IS NULL OR expires_at > NOW())`,
		keyHash,
	).Scan(&userID, &tenantID, &environment, (*[]string)(nil))

	if errors.Is(err, sql.ErrNoRows) {
		return "", "", "", nil, ErrNotFound
	}
	return
}

// ── Webhooks ──────────────────────────────────────────────────────────────

func (c *Client) CreateWebhook(ctx context.Context,
	tenantID, userID, name, url, secretHash string,
	events []string, retryCount, timeoutMS int,
) (*WebhookEndpoint, error) {
	const q = `
		INSERT INTO webhook_endpoints
			(id, tenant_id, user_id, name, url, secret_hash, events, retry_count, timeout_ms)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		RETURNING id, tenant_id, user_id, name, url, events,
		          enabled, retry_count, timeout_ms, created_at, updated_at`

	w := &WebhookEndpoint{}
	err := c.db.QueryRowContext(ctx, q,
		uuid.NewString(), tenantID, userID, name, url,
		secretHash, events, retryCount, timeoutMS,
	).Scan(
		&w.ID, &w.TenantID, &w.UserID, &w.Name, &w.URL,
		(*[]string)(nil), &w.Enabled, &w.RetryCount, &w.TimeoutMS,
		&w.CreatedAt, &w.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("create webhook: %w", err)
	}
	w.Events = events
	return w, nil
}

func (c *Client) ListWebhooks(ctx context.Context, tenantID string) ([]*WebhookEndpoint, error) {
	const q = `
		SELECT id, tenant_id, user_id, name, url, events,
		       enabled, retry_count, timeout_ms, created_at, updated_at
		FROM webhook_endpoints
		WHERE tenant_id = $1
		ORDER BY created_at DESC`

	rows, err := c.db.QueryContext(ctx, q, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var webhooks []*WebhookEndpoint
	for rows.Next() {
		w := &WebhookEndpoint{}
		if err := rows.Scan(
			&w.ID, &w.TenantID, &w.UserID, &w.Name, &w.URL,
			(*[]string)(nil), &w.Enabled, &w.RetryCount, &w.TimeoutMS,
			&w.CreatedAt, &w.UpdatedAt,
		); err != nil {
			return nil, err
		}
		webhooks = append(webhooks, w)
	}
	return webhooks, rows.Err()
}

func (c *Client) GetWebhookSecret(ctx context.Context, webhookID, tenantID string) (string, error) {
	var secretHash string
	err := c.db.QueryRowContext(ctx,
		`SELECT secret_hash FROM webhook_endpoints WHERE id = $1 AND tenant_id = $2`,
		webhookID, tenantID,
	).Scan(&secretHash)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return secretHash, err
}

func (c *Client) GetActiveWebhooksForEvent(ctx context.Context, tenantID, eventType string) ([]*WebhookEndpoint, error) {
	const q = `
		SELECT id, tenant_id, user_id, name, url, events,
		       enabled, retry_count, timeout_ms, created_at, updated_at
		FROM webhook_endpoints
		WHERE tenant_id = $1
		  AND enabled = TRUE
		  AND ($2 = ANY(events) OR '*' = ANY(events))`

	rows, err := c.db.QueryContext(ctx, q, tenantID, eventType)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var webhooks []*WebhookEndpoint
	for rows.Next() {
		w := &WebhookEndpoint{}
		if err := rows.Scan(
			&w.ID, &w.TenantID, &w.UserID, &w.Name, &w.URL,
			(*[]string)(nil), &w.Enabled, &w.RetryCount, &w.TimeoutMS,
			&w.CreatedAt, &w.UpdatedAt,
		); err != nil {
			return nil, err
		}
		webhooks = append(webhooks, w)
	}
	return webhooks, rows.Err()
}

func (c *Client) DeleteWebhook(ctx context.Context, webhookID, tenantID string) error {
	tag, err := c.db.ExecContext(ctx,
		`DELETE FROM webhook_endpoints WHERE id = $1 AND tenant_id = $2`,
		webhookID, tenantID,
	)
	if err != nil {
		return err
	}
	n, _ := tag.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func (c *Client) LogWebhookDelivery(ctx context.Context,
	webhookID, eventType string, payload json.RawMessage,
	statusCode int, body string, durationMS int64, attempt int,
	success bool, deliveryErr string,
) error {
	var errPtr *string
	if deliveryErr != "" {
		errPtr = &deliveryErr
	}
	_, err := c.db.ExecContext(ctx, `
		INSERT INTO webhook_deliveries
			(webhook_id, event_type, payload, response_status, response_body,
			 duration_ms, attempt, success, error)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
		webhookID, eventType, payload, statusCode, body,
		durationMS, attempt, success, errPtr,
	)
	return err
}

// ── Usage Analytics ───────────────────────────────────────────────────────

func (c *Client) RecordUsage(ctx context.Context,
	apiKeyID, tenantID, endpoint, method string,
	statusCode, durationMS, bytesIn, bytesOut int,
	ipAddress string,
) error {
	_, err := c.db.ExecContext(ctx, `
		INSERT INTO api_usage
			(api_key_id, tenant_id, endpoint, method, status_code,
			 duration_ms, bytes_in, bytes_out, ip_address)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
		apiKeyID, tenantID, endpoint, method, statusCode,
		durationMS, bytesIn, bytesOut, nullStr(ipAddress),
	)
	return err
}

func (c *Client) GetUsageStats(ctx context.Context, tenantID string, from, to time.Time) (*UsageStats, error) {
	const q = `
		SELECT
			COUNT(*)                                                          AS total_calls,
			COUNT(*) FILTER (WHERE status_code < 400)                        AS success_calls,
			COUNT(*) FILTER (WHERE status_code >= 400)                       AS error_calls,
			COALESCE(AVG(duration_ms)::INTEGER, 0)                           AS avg_duration_ms,
			COALESCE(SUM(bytes_out), 0)                                      AS total_bytes_out
		FROM api_usage
		WHERE tenant_id = $1 AND recorded_at BETWEEN $2 AND $3`

	s := &UsageStats{}
	err := c.db.QueryRowContext(ctx, q, tenantID, from, to).Scan(
		&s.TotalCalls, &s.SuccessCalls, &s.ErrorCalls,
		&s.AvgDurationMS, &s.TotalBytesOut,
	)
	return s, err
}

func (c *Client) GetTopEndpoints(ctx context.Context, tenantID string, from, to time.Time, limit int) ([]map[string]any, error) {
	const q = `
		SELECT endpoint, COUNT(*) AS calls,
		       AVG(duration_ms)::INTEGER AS avg_ms,
		       COUNT(*) FILTER (WHERE status_code >= 400) AS errors
		FROM api_usage
		WHERE tenant_id = $1 AND recorded_at BETWEEN $2 AND $3
		GROUP BY endpoint
		ORDER BY calls DESC
		LIMIT $4`

	rows, err := c.db.QueryContext(ctx, q, tenantID, from, to, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []map[string]any
	for rows.Next() {
		var endpoint string
		var calls, errors int64
		var avgMS int
		if err := rows.Scan(&endpoint, &calls, &avgMS, &errors); err != nil {
			return nil, err
		}
		results = append(results, map[string]any{
			"endpoint": endpoint,
			"calls":    calls,
			"avg_ms":   avgMS,
			"errors":   errors,
		})
	}
	return results, rows.Err()
}

// ── Webhook Event Types ───────────────────────────────────────────────────

func (c *Client) ListEventTypes(ctx context.Context) ([]map[string]string, error) {
	rows, err := c.db.QueryContext(ctx,
		`SELECT name, description, category FROM webhook_event_types ORDER BY category, name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var types []map[string]string
	for rows.Next() {
		var name, description, category string
		if err := rows.Scan(&name, &description, &category); err != nil {
			return nil, err
		}
		types = append(types, map[string]string{
			"name": name, "description": description, "category": category,
		})
	}
	return types, rows.Err()
}

// ── Helpers ───────────────────────────────────────────────────────────────

func nullStr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getEnvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return def
}
