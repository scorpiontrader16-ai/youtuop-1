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
	logger.Info("waiting for postgres...")
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
	c.logger.Info("control-plane migrations applied")
	return nil
}

func (c *Client) DB() *sql.DB  { return c.db }
func (c *Client) Close() error { return c.db.Close() }

// ── Domain Types ──────────────────────────────────────────────────────────

type Tenant struct {
	ID        string
	Name      string
	Slug      string
	Status    string
	Plan      string
	CreatedAt time.Time
}

type User struct {
	ID           string
	Email        string
	FirstName    *string
	LastName     *string
	Status       string
	FailedLogins int
	LastLoginAt  *time.Time
	CreatedAt    time.Time
}

type KillSwitch struct {
	ID          string
	Name        string
	Description *string
	Enabled     bool
	Scope       string
	EnabledBy   *string
	EnabledAt   *time.Time
}

type SystemConfig struct {
	Key         string
	Value       json.RawMessage
	Description *string
	UpdatedAt   time.Time
}

// ── Tenant Management ─────────────────────────────────────────────────────

func (c *Client) ListTenants(ctx context.Context, status string, limit, offset int) ([]*Tenant, error) {
	q := `SELECT id, name, slug, status, plan, created_at FROM tenants`
	args := []any{}
	if status != "" {
		q += ` WHERE status = $1`
		args = append(args, status)
	}
	q += ` ORDER BY created_at DESC LIMIT $` + fmt.Sprint(len(args)+1) + ` OFFSET $` + fmt.Sprint(len(args)+2)
	args = append(args, limit, offset)

	rows, err := c.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tenants []*Tenant
	for rows.Next() {
		t := &Tenant{}
		if err := rows.Scan(&t.ID, &t.Name, &t.Slug, &t.Status, &t.Plan, &t.CreatedAt); err != nil {
			return nil, err
		}
		tenants = append(tenants, t)
	}
	return tenants, rows.Err()
}

func (c *Client) SuspendTenant(ctx context.Context, tenantID, adminUserID, reason string) error {
	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck

	_, err = tx.ExecContext(ctx, `
		UPDATE tenants SET status = 'suspended', updated_at = NOW()
		WHERE id = $1 AND status = 'active'`, tenantID)
	if err != nil {
		return err
	}

	// Audit log
	_, err = tx.ExecContext(ctx, `
		SELECT write_audit($1, $2, 'tenant.suspended', 'tenant', $1, NULL, NULL, NULL, NULL, 'success', $3)`,
		tenantID, adminUserID, reason)
	if err != nil {
		return err
	}

	return tx.Commit()
}

func (c *Client) ReactivateTenant(ctx context.Context, tenantID, adminUserID string) error {
	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck

	_, err = tx.ExecContext(ctx, `
		UPDATE tenants SET status = 'active', updated_at = NOW()
		WHERE id = $1 AND status = 'suspended'`, tenantID)
	if err != nil {
		return err
	}

	_, err = tx.ExecContext(ctx, `
		SELECT write_audit($1, $2, 'tenant.reactivated', 'tenant', $1, NULL, NULL, NULL, NULL, 'success', NULL)`,
		tenantID, adminUserID)
	if err != nil {
		return err
	}

	return tx.Commit()
}

// ── User Management ───────────────────────────────────────────────────────

func (c *Client) ListUsers(ctx context.Context, tenantID string, limit, offset int) ([]*User, error) {
	const q = `
		SELECT u.id, u.email, u.first_name, u.last_name, u.status,
		       u.failed_logins, u.last_login_at, u.created_at
		FROM users u
		JOIN user_tenants ut ON ut.user_id = u.id
		WHERE ut.tenant_id = $1
		ORDER BY u.created_at DESC
		LIMIT $2 OFFSET $3`

	rows, err := c.db.QueryContext(ctx, q, tenantID, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var users []*User
	for rows.Next() {
		u := &User{}
		if err := rows.Scan(
			&u.ID, &u.Email, &u.FirstName, &u.LastName, &u.Status,
			&u.FailedLogins, &u.LastLoginAt, &u.CreatedAt,
		); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

func (c *Client) ForceLogout(ctx context.Context, targetUserID, adminUserID string) (int64, error) {
	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback() //nolint:errcheck

	tag, err := tx.ExecContext(ctx, `
		UPDATE sessions SET revoked = TRUE, revoked_at = NOW(), revoke_reason = 'admin_force_logout'
		WHERE user_id = $1 AND NOT revoked`, targetUserID)
	if err != nil {
		return 0, err
	}

	n, _ := tag.RowsAffected()
	_, err = tx.ExecContext(ctx, `
		SELECT write_audit(NULL, $1, 'user.force_logout', 'user', $2, NULL, NULL, NULL, NULL, 'success', NULL)`,
		adminUserID, targetUserID)
	if err != nil {
		return 0, err
	}

	return n, tx.Commit()
}

func (c *Client) BanUser(ctx context.Context, targetUserID, adminUserID, reason string) error {
	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck

	_, err = tx.ExecContext(ctx,
		`UPDATE users SET status = 'banned', updated_at = NOW() WHERE id = $1`,
		targetUserID)
	if err != nil {
		return err
	}

	// Force logout كمان
	tx.ExecContext(ctx, `
		UPDATE sessions SET revoked = TRUE, revoked_at = NOW(), revoke_reason = 'user_banned'
		WHERE user_id = $1 AND NOT revoked`, targetUserID) //nolint:errcheck

	_, err = tx.ExecContext(ctx, `
		SELECT write_audit(NULL, $1, 'user.banned', 'user', $2, NULL, NULL, NULL, NULL, 'success', $3)`,
		adminUserID, targetUserID, reason)
	if err != nil {
		return err
	}

	return tx.Commit()
}

// ── Kill Switches ─────────────────────────────────────────────────────────

func (c *Client) ListKillSwitches(ctx context.Context) ([]*KillSwitch, error) {
	rows, err := c.db.QueryContext(ctx, `
		SELECT id, name, description, enabled, scope, enabled_by, enabled_at
		FROM kill_switches ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var switches []*KillSwitch
	for rows.Next() {
		k := &KillSwitch{}
		if err := rows.Scan(
			&k.ID, &k.Name, &k.Description, &k.Enabled,
			&k.Scope, &k.EnabledBy, &k.EnabledAt,
		); err != nil {
			return nil, err
		}
		switches = append(switches, k)
	}
	return switches, rows.Err()
}

func (c *Client) ToggleKillSwitch(ctx context.Context, name string, enable bool, adminUserID string) error {
	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck

	var enabledAt *time.Time
	if enable {
		now := time.Now()
		enabledAt = &now
	}

	tag, err := tx.ExecContext(ctx, `
		UPDATE kill_switches SET
			enabled    = $2,
			enabled_by = $3,
			enabled_at = $4
		WHERE name = $1`,
		name, enable, adminUserID, enabledAt)
	if err != nil {
		return err
	}
	if n, _ := tag.RowsAffected(); n == 0 {
		return ErrNotFound
	}

	action := "kill_switch.disabled"
	if enable {
		action = "kill_switch.enabled"
	}
	_, err = tx.ExecContext(ctx, `
		SELECT write_audit(NULL, $1, $2, 'kill_switch', $3, NULL, NULL, NULL, NULL, 'success', NULL)`,
		adminUserID, action, name)
	if err != nil {
		return err
	}

	return tx.Commit()
}

// ── System Config ─────────────────────────────────────────────────────────

func (c *Client) GetConfig(ctx context.Context, key string) (*SystemConfig, error) {
	cfg := &SystemConfig{}
	err := c.db.QueryRowContext(ctx,
		`SELECT key, value, description, updated_at FROM system_config WHERE key = $1`, key,
	).Scan(&cfg.Key, &cfg.Value, &cfg.Description, &cfg.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return cfg, err
}

func (c *Client) ListConfig(ctx context.Context) ([]*SystemConfig, error) {
	rows, err := c.db.QueryContext(ctx,
		`SELECT key, value, description, updated_at FROM system_config ORDER BY key`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var configs []*SystemConfig
	for rows.Next() {
		cfg := &SystemConfig{}
		if err := rows.Scan(&cfg.Key, &cfg.Value, &cfg.Description, &cfg.UpdatedAt); err != nil {
			return nil, err
		}
		configs = append(configs, cfg)
	}
	return configs, rows.Err()
}

func (c *Client) SetConfig(ctx context.Context, key string, value json.RawMessage, adminUserID string) error {
	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck

	_, err = tx.ExecContext(ctx, `
		INSERT INTO system_config (key, value, updated_by, updated_at)
		VALUES ($1, $2, $3, NOW())
		ON CONFLICT (key) DO UPDATE SET
			value      = EXCLUDED.value,
			updated_by = EXCLUDED.updated_by,
			updated_at = NOW()`,
		key, string(value), adminUserID)
	if err != nil {
		return err
	}

	_, err = tx.ExecContext(ctx, `
		SELECT write_audit(NULL, $1, 'config.updated', 'system_config', $2, NULL, $3::jsonb, NULL, NULL, 'success', NULL)`,
		adminUserID, key, string(value))
	if err != nil {
		return err
	}

	return tx.Commit()
}

// ── Audit Log Query ───────────────────────────────────────────────────────

type AuditEntry struct {
	ID         int64
	TenantID   *string
	UserID     *string
	Action     string
	Resource   string
	ResourceID *string
	Status     string
	IPAddress  *string
	TraceID    *string
	CreatedAt  time.Time
}

func (c *Client) QueryAuditLog(ctx context.Context, tenantID, userID, action string, limit int) ([]*AuditEntry, error) {
	q := `SELECT id, tenant_id, user_id, action, resource, resource_id, status, ip_address, trace_id, created_at
	      FROM audit_log WHERE 1=1`
	args := []any{}

	if tenantID != "" {
		args = append(args, tenantID)
		q += fmt.Sprintf(" AND tenant_id = $%d", len(args))
	}
	if userID != "" {
		args = append(args, userID)
		q += fmt.Sprintf(" AND user_id = $%d", len(args))
	}
	if action != "" {
		args = append(args, action)
		q += fmt.Sprintf(" AND action = $%d", len(args))
	}

	args = append(args, limit)
	q += fmt.Sprintf(" ORDER BY created_at DESC LIMIT $%d", len(args))

	rows, err := c.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var entries []*AuditEntry
	for rows.Next() {
		e := &AuditEntry{}
		if err := rows.Scan(
			&e.ID, &e.TenantID, &e.UserID, &e.Action, &e.Resource,
			&e.ResourceID, &e.Status, &e.IPAddress, &e.TraceID, &e.CreatedAt,
		); err != nil {
			return nil, err
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

// ── Impersonation ─────────────────────────────────────────────────────────

func (c *Client) StartImpersonation(ctx context.Context, adminUserID, targetUserID, tenantID, reason, ip string) (string, error) {
	id := uuid.NewString()
	_, err := c.db.ExecContext(ctx, `
		INSERT INTO impersonation_log (id, admin_user_id, target_user_id, tenant_id, reason, ip_address)
		VALUES ($1, $2, $3, $4, $5, $6)`,
		id, adminUserID, targetUserID, tenantID, reason, ip)
	if err != nil {
		return "", err
	}

	c.db.ExecContext(ctx, `
		SELECT write_audit($1, $2, 'user.impersonation_started', 'user', $3, NULL, NULL, $4, NULL, 'success', NULL)`,
		tenantID, adminUserID, targetUserID, ip) //nolint:errcheck

	return id, nil
}

func (c *Client) EndImpersonation(ctx context.Context, sessionID string) error {
	_, err := c.db.ExecContext(ctx,
		`UPDATE impersonation_log SET ended_at = NOW() WHERE id = $1`, sessionID)
	return err
}

// ── Helpers ───────────────────────────────────────────────────────────────

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
