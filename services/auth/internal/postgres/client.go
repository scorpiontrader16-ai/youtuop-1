package postgres

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"embed"
	"encoding/hex"
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
		MaxOpenConns: getEnvInt("POSTGRES_MAX_OPEN_CONNS", 20),
		MaxIdleConns: getEnvInt("POSTGRES_MAX_IDLE_CONNS", 5),
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
	c.logger.Info("auth migrations applied")
	return nil
}

func (c *Client) DB() *sql.DB  { return c.db }
func (c *Client) Close() error { return c.db.Close() }

// SetTenantContext يضبط الـ RLS — لازم يتعمل قبل أي query على tenant data
func (c *Client) SetTenantContext(ctx context.Context, tenantID string) error {
	_, err := c.db.ExecContext(ctx, "SELECT set_config('app.tenant_id', $1, true)", tenantID)
	return err
}

// ── Errors ────────────────────────────────────────────────────────────────

var ErrNotFound  = errors.New("not found")
var ErrDuplicate = errors.New("duplicate")

// ── User ──────────────────────────────────────────────────────────────────

type User struct {
	ID            string
	Email         string
	EmailVerified bool
	KeycloakID    *string
	FirstName     *string
	LastName      *string
	AvatarURL     *string
	Status        string
	FailedLogins  int
	LockedUntil   *time.Time
	CreatedAt     time.Time
	UpdatedAt     time.Time
	LastLoginAt   *time.Time
}

func (u *User) IsLocked() bool {
	return u.LockedUntil != nil && u.LockedUntil.After(time.Now())
}

// UpsertByKeycloakID — idempotent، آمن يتعمل على كل login
func (c *Client) UpsertByKeycloakID(ctx context.Context, keycloakID, email, firstName, lastName, avatarURL string) (*User, error) {
	const q = `
		INSERT INTO users (keycloak_id, email, email_verified, first_name, last_name, avatar_url, last_login_at)
		VALUES ($1, $2, TRUE, $3, $4, $5, NOW())
		ON CONFLICT (keycloak_id) DO UPDATE SET
			email         = EXCLUDED.email,
			first_name    = EXCLUDED.first_name,
			last_name     = EXCLUDED.last_name,
			avatar_url    = EXCLUDED.avatar_url,
			last_login_at = NOW(),
			failed_logins = 0,
			locked_until  = NULL
		RETURNING id, email, email_verified, keycloak_id, first_name, last_name,
		          avatar_url, status, failed_logins, locked_until,
		          created_at, updated_at, last_login_at`

	u := &User{}
	err := c.db.QueryRowContext(ctx, q,
		keycloakID, email, nullStr(firstName), nullStr(lastName), nullStr(avatarURL),
	).Scan(
		&u.ID, &u.Email, &u.EmailVerified, &u.KeycloakID,
		&u.FirstName, &u.LastName, &u.AvatarURL,
		&u.Status, &u.FailedLogins, &u.LockedUntil,
		&u.CreatedAt, &u.UpdatedAt, &u.LastLoginAt,
	)
	if err != nil {
		return nil, fmt.Errorf("upsert user: %w", err)
	}
	return u, nil
}

func (c *Client) GetUserByID(ctx context.Context, id string) (*User, error) {
	const q = `
		SELECT id, email, email_verified, keycloak_id, first_name, last_name,
		       avatar_url, status, failed_logins, locked_until, created_at, updated_at, last_login_at
		FROM users WHERE id = $1 AND status != 'banned'`
	u := &User{}
	err := c.db.QueryRowContext(ctx, q, id).Scan(
		&u.ID, &u.Email, &u.EmailVerified, &u.KeycloakID,
		&u.FirstName, &u.LastName, &u.AvatarURL,
		&u.Status, &u.FailedLogins, &u.LockedUntil,
		&u.CreatedAt, &u.UpdatedAt, &u.LastLoginAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return u, err
}

// ── Tenant ────────────────────────────────────────────────────────────────

type Tenant struct {
	ID        string
	Name      string
	Slug      string
	Status    string
	Plan      string
	CreatedAt time.Time
	UpdatedAt time.Time
}

func (c *Client) GetTenantBySlug(ctx context.Context, slug string) (*Tenant, error) {
	const q = `
		SELECT id, name, slug, status, plan, created_at, updated_at
		FROM tenants WHERE slug = $1 AND status = 'active'`
	t := &Tenant{}
	err := c.db.QueryRowContext(ctx, q, slug).Scan(
		&t.ID, &t.Name, &t.Slug, &t.Status, &t.Plan, &t.CreatedAt, &t.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return t, err
}

func (c *Client) GetTenantByID(ctx context.Context, id string) (*Tenant, error) {
	const q = `
		SELECT id, name, slug, status, plan, created_at, updated_at
		FROM tenants WHERE id = $1 AND status = 'active'`
	t := &Tenant{}
	err := c.db.QueryRowContext(ctx, q, id).Scan(
		&t.ID, &t.Name, &t.Slug, &t.Status, &t.Plan, &t.CreatedAt, &t.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return t, err
}

// ── User-Tenant Membership ────────────────────────────────────────────────

func (c *Client) GetUserRole(ctx context.Context, userID, tenantID string) (string, error) {
	var role string
	err := c.db.QueryRowContext(ctx,
		`SELECT role FROM user_tenants WHERE user_id = $1 AND tenant_id = $2`,
		userID, tenantID,
	).Scan(&role)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return role, err
}

func (c *Client) AssignRole(ctx context.Context, userID, tenantID, role string) error {
	_, err := c.db.ExecContext(ctx, `
		INSERT INTO user_tenants (user_id, tenant_id, role)
		VALUES ($1, $2, $3)
		ON CONFLICT (user_id, tenant_id) DO UPDATE SET role = $3`,
		userID, tenantID, role,
	)
	return err
}

// ── Sessions ──────────────────────────────────────────────────────────────

func (c *Client) CreateSession(ctx context.Context, userID, tenantID, deviceFP, ip, ua string, expiresAt time.Time) (string, error) {
	id := uuid.NewString()
	_, err := c.db.ExecContext(ctx, `
		INSERT INTO sessions (id, user_id, tenant_id, device_fingerprint, ip_address, user_agent, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		id, userID, tenantID, nullStr(deviceFP), nullStr(ip), nullStr(ua), expiresAt,
	)
	if err != nil {
		return "", fmt.Errorf("create session: %w", err)
	}
	return id, nil
}

func (c *Client) RevokeSession(ctx context.Context, sessionID, userID, reason string) error {
	tag, err := c.db.ExecContext(ctx, `
		UPDATE sessions SET revoked = TRUE, revoked_at = NOW(), revoke_reason = $3
		WHERE id = $1 AND user_id = $2 AND NOT revoked`,
		sessionID, userID, reason,
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

// ── Refresh Tokens ────────────────────────────────────────────────────────

// HashToken — SHA-256 للـ raw token قبل ما يتحفظ في الـ DB
func HashToken(raw string) string {
	h := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(h[:])
}

func (c *Client) StoreRefreshToken(ctx context.Context, sessionID, tokenHash string, expiresAt time.Time) error {
	_, err := c.db.ExecContext(ctx, `
		INSERT INTO refresh_tokens (session_id, token_hash, expires_at)
		VALUES ($1, $2, $3)`,
		sessionID, tokenHash, expiresAt,
	)
	return err
}

// ConsumeRefreshToken — atomic validation + mark used (replay protection)
func (c *Client) ConsumeRefreshToken(ctx context.Context, tokenHash string) (string, error) {
	var sessionID string
	err := c.db.QueryRowContext(ctx, `
		UPDATE refresh_tokens SET used = TRUE, used_at = NOW()
		WHERE token_hash = $1 AND NOT used AND expires_at > NOW()
		RETURNING session_id`,
		tokenHash,
	).Scan(&sessionID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	return sessionID, err
}

// ── RBAC ──────────────────────────────────────────────────────────────────

// GetPermissions يجيب كل permissions للـ user في tenant معين
// يُستخدم من rbac.Engine كـ DB interface
func (c *Client) GetPermissions(ctx context.Context, userID, tenantID string) ([]string, error) {
	const q = `
		SELECT DISTINCT p.resource || ':' || p.action
		FROM user_tenants ut
		JOIN roles r
			ON r.name = ut.role
			AND (r.tenant_id = ut.tenant_id OR r.is_system = TRUE)
		JOIN role_permissions rp ON rp.role_id = r.id
		JOIN permissions p       ON p.id = rp.permission_id
		WHERE ut.user_id = $1 AND ut.tenant_id = $2`

	rows, err := c.db.QueryContext(ctx, q, userID, tenantID)
	if err != nil {
		return nil, fmt.Errorf("get permissions: %w", err)
	}
	defer rows.Close()

	var perms []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, err
		}
		perms = append(perms, p)
	}
	return perms, rows.Err()
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
