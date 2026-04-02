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

var ErrNotFound = errors.New("not found")

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
	// PostgreSQL password must be injected from ExternalSecrets (AWS Secrets Manager)
	// Never use hardcoded or default passwords — fail fast at startup to prevent
	// security issues from weak credentials reaching production.
	password := getEnv("POSTGRES_PASSWORD", "")
	if password == "" {
		panic("CRITICAL: POSTGRES_PASSWORD environment variable is required but not set")
	}
	return Config{
		Host:         getEnv("POSTGRES_HOST", "localhost"),
		Port:         getEnvInt("POSTGRES_PORT", 5432),
		Database:     getEnv("POSTGRES_DB", "platform"),
		User:         getEnv("POSTGRES_USER", "platform"),
		Password:     password,
		SSLMode:      getEnv("POSTGRES_SSL_MODE", "require"),
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
	c.logger.Info("feature-flags migrations applied")
	return nil
}

func (c *Client) DB() *sql.DB  { return c.db }
func (c *Client) Close() error { return c.db.Close() }

// ── Domain Types ──────────────────────────────────────────────────────────

type FeatureFlag struct {
	ID           string
	Key          string
	Name         string
	Description  *string
	Type         string
	DefaultValue json.RawMessage
	Enabled      bool
	RolloutPct   int
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

type FlagOverride struct {
	ID         string
	FlagID     string
	TargetType string
	TargetID   string
	Value      json.RawMessage
	Enabled    bool
	CreatedAt  time.Time
}

// EvalResult نتيجة تقييم الـ flag
type EvalResult struct {
	Key    string
	Value  json.RawMessage
	Reason string // default | override | rollout | disabled
}

// ── Feature Flags CRUD ────────────────────────────────────────────────────

func (c *Client) ListFlags(ctx context.Context) ([]*FeatureFlag, error) {
	const q = `
		SELECT id, key, name, description, type, default_value,
		       enabled, rollout_pct, created_at, updated_at
		FROM feature_flags
		ORDER BY key`

	rows, err := c.db.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var flags []*FeatureFlag
	for rows.Next() {
		f := &FeatureFlag{}
		if err := rows.Scan(
			&f.ID, &f.Key, &f.Name, &f.Description, &f.Type,
			&f.DefaultValue, &f.Enabled, &f.RolloutPct,
			&f.CreatedAt, &f.UpdatedAt,
		); err != nil {
			return nil, err
		}
		flags = append(flags, f)
	}
	return flags, rows.Err()
}

func (c *Client) GetFlag(ctx context.Context, key string) (*FeatureFlag, error) {
	const q = `
		SELECT id, key, name, description, type, default_value,
		       enabled, rollout_pct, created_at, updated_at
		FROM feature_flags WHERE key = $1`

	f := &FeatureFlag{}
	err := c.db.QueryRowContext(ctx, q, key).Scan(
		&f.ID, &f.Key, &f.Name, &f.Description, &f.Type,
		&f.DefaultValue, &f.Enabled, &f.RolloutPct,
		&f.CreatedAt, &f.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return f, err
}

func (c *Client) CreateFlag(ctx context.Context, key, name, description, flagType string,
	defaultValue json.RawMessage, createdBy string,
) (*FeatureFlag, error) {
	const q = `
		INSERT INTO feature_flags (id, key, name, description, type, default_value, created_by)
		VALUES ($1,$2,$3,$4,$5,$6,$7)
		RETURNING id, key, name, description, type, default_value,
		          enabled, rollout_pct, created_at, updated_at`

	f := &FeatureFlag{}
	err := c.db.QueryRowContext(ctx, q,
		uuid.NewString(), key, name, nullStr(description), flagType, defaultValue, createdBy,
	).Scan(
		&f.ID, &f.Key, &f.Name, &f.Description, &f.Type,
		&f.DefaultValue, &f.Enabled, &f.RolloutPct,
		&f.CreatedAt, &f.UpdatedAt,
	)
	return f, err
}

func (c *Client) UpdateFlag(ctx context.Context, key string, enabled bool, rolloutPct int) error {
	tag, err := c.db.ExecContext(ctx, `
		UPDATE feature_flags SET enabled = $2, rollout_pct = $3
		WHERE key = $1`,
		key, enabled, rolloutPct,
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

func (c *Client) DeleteFlag(ctx context.Context, key string) error {
	tag, err := c.db.ExecContext(ctx,
		`DELETE FROM feature_flags WHERE key = $1`, key)
	if err != nil {
		return err
	}
	n, _ := tag.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// ── Overrides ─────────────────────────────────────────────────────────────

func (c *Client) SetOverride(ctx context.Context,
	flagKey, targetType, targetID string, value json.RawMessage, createdBy string,
) error {
	const q = `
		INSERT INTO flag_overrides (id, flag_id, target_type, target_id, value, created_by)
		SELECT $1, id, $2, $3, $4, $5
		FROM feature_flags WHERE key = $6
		ON CONFLICT (flag_id, target_type, target_id) DO UPDATE SET
			value   = EXCLUDED.value,
			enabled = TRUE`

	tag, err := c.db.ExecContext(ctx, q,
		uuid.NewString(), targetType, targetID, value, createdBy, flagKey,
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

func (c *Client) DeleteOverride(ctx context.Context, flagKey, targetType, targetID string) error {
	_, err := c.db.ExecContext(ctx, `
		UPDATE flag_overrides SET enabled = FALSE
		WHERE flag_id = (SELECT id FROM feature_flags WHERE key = $1)
		AND target_type = $2 AND target_id = $3`,
		flagKey, targetType, targetID,
	)
	return err
}

// ── Evaluation ────────────────────────────────────────────────────────────

// GetFlagsForContext يجيب كل الـ flags مع overrides للـ tenant + plan
// هاي الـ method الأساسية اللي الـ SDK بيستخدمها
func (c *Client) GetFlagsForContext(ctx context.Context, tenantID, plan string) ([]*EvalResult, error) {
	const q = `
		SELECT
			ff.key,
			COALESCE(
				-- tenant override أولاً
				(SELECT value FROM flag_overrides fo
				 WHERE fo.flag_id = ff.id
				   AND fo.target_type = 'tenant'
				   AND fo.target_id   = $1
				   AND fo.enabled     = TRUE
				 LIMIT 1),
				-- plan override تانياً
				(SELECT value FROM flag_overrides fo
				 WHERE fo.flag_id = ff.id
				   AND fo.target_type = 'plan'
				   AND fo.target_id   = $2
				   AND fo.enabled     = TRUE
				 LIMIT 1),
				-- default value أخيراً
				ff.default_value
			) AS resolved_value,
			CASE
				WHEN (SELECT COUNT(1) FROM flag_overrides fo
				      WHERE fo.flag_id = ff.id AND fo.target_type = 'tenant'
				        AND fo.target_id = $1 AND fo.enabled = TRUE) > 0
				THEN 'override'
				WHEN (SELECT COUNT(1) FROM flag_overrides fo
				      WHERE fo.flag_id = ff.id AND fo.target_type = 'plan'
				        AND fo.target_id = $2 AND fo.enabled = TRUE) > 0
				THEN 'override'
				WHEN ff.enabled = FALSE THEN 'disabled'
				ELSE 'default'
			END AS reason
		FROM feature_flags ff
		ORDER BY ff.key`

	rows, err := c.db.QueryContext(ctx, q, tenantID, plan)
	if err != nil {
		return nil, fmt.Errorf("get flags for context: %w", err)
	}
	defer rows.Close()

	var results []*EvalResult
	for rows.Next() {
		r := &EvalResult{}
		if err := rows.Scan(&r.Key, &r.Value, &r.Reason); err != nil {
			return nil, err
		}
		results = append(results, r)
	}
	return results, rows.Err()
}

// EvaluateFlag يقيّم flag واحد لـ context معين
func (c *Client) EvaluateFlag(ctx context.Context, key, tenantID, plan string) (*EvalResult, error) {
	const q = `
		SELECT
			ff.key,
			COALESCE(
				(SELECT value FROM flag_overrides fo
				 WHERE fo.flag_id = ff.id AND fo.target_type = 'tenant'
				   AND fo.target_id = $2 AND fo.enabled = TRUE LIMIT 1),
				(SELECT value FROM flag_overrides fo
				 WHERE fo.flag_id = ff.id AND fo.target_type = 'plan'
				   AND fo.target_id = $3 AND fo.enabled = TRUE LIMIT 1),
				ff.default_value
			),
			CASE
				WHEN (SELECT COUNT(1) FROM flag_overrides fo
				      WHERE fo.flag_id = ff.id AND fo.target_type = 'tenant'
				        AND fo.target_id = $2 AND fo.enabled = TRUE) > 0 THEN 'override'
				WHEN (SELECT COUNT(1) FROM flag_overrides fo
				      WHERE fo.flag_id = ff.id AND fo.target_type = 'plan'
				        AND fo.target_id = $3 AND fo.enabled = TRUE) > 0 THEN 'override'
				WHEN ff.enabled = FALSE THEN 'disabled'
				ELSE 'default'
			END
		FROM feature_flags ff WHERE ff.key = $1`

	r := &EvalResult{}
	err := c.db.QueryRowContext(ctx, q, key, tenantID, plan).Scan(
		&r.Key, &r.Value, &r.Reason,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return r, err
}

// LogEvaluation يسجّل تقييم للـ analytics (sampling — مش كل request)
func (c *Client) LogEvaluation(ctx context.Context, key, tenantID, userID, reason string, value json.RawMessage) {
	c.db.ExecContext(ctx, `
		INSERT INTO flag_evaluations (flag_key, tenant_id, user_id, result, reason)
		VALUES ($1, $2, $3, $4, $5)`,
		key, nullStr(tenantID), nullStr(userID), value, reason,
	) //nolint:errcheck — best effort logging
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
