package postgres

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Client struct {
	db *pgxpool.Pool
}

type Config struct {
	Host     string
	Port     int
	User     string
	Password string
	Database string
	SSLMode  string
}

func ConfigFromEnv() Config {
	port, err := strconv.Atoi(getEnv("POSTGRES_PORT", "5432"))
	if err != nil {
		slog.Warn("POSTGRES_PORT is not a valid integer, using default 5432", "value", getEnv("POSTGRES_PORT", "5432"))
		port = 5432
	}
	// PostgreSQL password must be injected from ExternalSecrets (AWS Secrets Manager)
	// Never use hardcoded or default passwords — fail fast at startup to prevent
	// security issues from weak credentials reaching production.
	password := getEnv("POSTGRES_PASSWORD", "")
	if password == "" {
		panic("CRITICAL: POSTGRES_PASSWORD environment variable is required but not set")
	}
	return Config{
		Host:     getEnv("POSTGRES_HOST", "postgres.platform.svc.cluster.local"),
		Port:     port,
		User:     getEnv("POSTGRES_USER", "postgres"),
		Password: password,
		Database: getEnv("POSTGRES_DB", "platform"),
		SSLMode:  getEnv("POSTGRES_SSL_MODE", "require"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func (c Config) ConnString() string {
	return fmt.Sprintf(
		"host=%s port=%d user=%s password=%s dbname=%s sslmode=%s",
		c.Host, c.Port, c.User, c.Password, c.Database, c.SSLMode,
	)
}

func NewClient(ctx context.Context, cfg Config) (*Client, error) {
	pool, err := pgxpool.New(ctx, cfg.ConnString())
	if err != nil {
		return nil, fmt.Errorf("failed to create connection pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("failed to ping database: %w", err)
	}
	return &Client{db: pool}, nil
}

func WaitForPostgres(ctx context.Context, cfg Config, logger *slog.Logger) (*Client, error) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
			client, err := NewClient(ctx, cfg)
			if err == nil {
				logger.Info("connected to postgres")
				return client, nil
			}
			logger.Warn("waiting for postgres", "error", err)
		}
	}
}

func (c *Client) Migrate(ctx context.Context) error {
	return nil
}

func (c *Client) Close() {
	c.db.Close()
}

func (c *Client) DB() *pgxpool.Pool {
	return c.db
}

// ── User methods ─────────────────────────────────────────────────────────

type User struct {
	ID           string
	KeycloakID   string
	Email        string
	FirstName    string
	LastName     string
	Picture      string
	PasswordHash string
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

func (c *Client) GetUserByEmail(ctx context.Context, email string) (*User, error) {
	var u User
	err := c.db.QueryRow(ctx,
		`SELECT id, keycloak_id, email, first_name, last_name, picture, password_hash, created_at, updated_at
         FROM users WHERE email = $1`,
		email,
	).Scan(&u.ID, &u.KeycloakID, &u.Email, &u.FirstName, &u.LastName, &u.Picture, &u.PasswordHash, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, err
	}
	return &u, nil
}

func (c *Client) GetUserByID(ctx context.Context, id string) (*User, error) {
	var u User
	err := c.db.QueryRow(ctx,
		`SELECT id, keycloak_id, email, first_name, last_name, picture, password_hash, created_at, updated_at
         FROM users WHERE id = $1`,
		id,
	).Scan(&u.ID, &u.KeycloakID, &u.Email, &u.FirstName, &u.LastName, &u.Picture, &u.PasswordHash, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, err
	}
	return &u, nil
}

func (c *Client) UpsertByKeycloakID(ctx context.Context, keycloakID, email, firstName, lastName, picture string) (*User, error) {
	var u User
	err := c.db.QueryRow(ctx,
		`INSERT INTO users (keycloak_id, email, first_name, last_name, picture, created_at, updated_at)
         VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
         ON CONFLICT (keycloak_id) DO UPDATE SET
            email = EXCLUDED.email,
            first_name = EXCLUDED.first_name,
            last_name = EXCLUDED.last_name,
            picture = EXCLUDED.picture,
            updated_at = NOW()
         RETURNING id, keycloak_id, email, first_name, last_name, picture, password_hash, created_at, updated_at`,
		keycloakID, email, firstName, lastName, picture,
	).Scan(&u.ID, &u.KeycloakID, &u.Email, &u.FirstName, &u.LastName, &u.Picture, &u.PasswordHash, &u.CreatedAt, &u.UpdatedAt)
	return &u, err
}

// ── Tenant methods ───────────────────────────────────────────────────────

type Tenant struct {
	ID   string
	Slug string
	Tier string
}

func (c *Client) GetTenantBySlug(ctx context.Context, slug string) (*Tenant, error) {
	var t Tenant
	err := c.db.QueryRow(ctx,
		`SELECT id, slug, tier FROM tenants WHERE slug = $1`,
		slug,
	).Scan(&t.ID, &t.Slug, &t.Tier)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

func (c *Client) GetTenantByID(ctx context.Context, id string) (*Tenant, error) {
	var t Tenant
	err := c.db.QueryRow(ctx,
		`SELECT id, slug, tier FROM tenants WHERE id = $1`,
		id,
	).Scan(&t.ID, &t.Slug, &t.Tier)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// ── Role methods ─────────────────────────────────────────────────────────

func (c *Client) GetUserRole(ctx context.Context, userID, tenantID string) (string, error) {
	var role string
	err := c.db.QueryRow(ctx,
		`SELECT role FROM user_roles WHERE user_id = $1 AND tenant_id = $2`,
		userID, tenantID,
	).Scan(&role)
	if err != nil {
		return "", err
	}
	return role, nil
}

func (c *Client) AssignRole(ctx context.Context, userID, tenantID, role string) error {
	_, err := c.db.Exec(ctx,
		`INSERT INTO user_roles (user_id, tenant_id, role) VALUES ($1, $2, $3)
         ON CONFLICT (user_id, tenant_id) DO UPDATE SET role = $3, updated_at = NOW()`,
		userID, tenantID, role,
	)
	return err
}

// ── GetPermissions: satisfies rbac.DB interface exactly ──────────────────
//
// Signature MUST match rbac.DB:
//
//	GetPermissions(ctx context.Context, userID, tenantID string) ([]string, error)
//
// This method returns ONLY the role-based permissions for the user.
// Plan-level permissions (markets:stream, analytics:export, etc.) are merged
// UPSTREAM by rbac.Engine.GetPermissions using the planPermissions map.
// Do NOT add plan logic here — that would duplicate Engine's responsibility.
func (c *Client) GetPermissions(ctx context.Context, userID, tenantID string) ([]string, error) {
	// Try explicit per-user permission grants first
	rows, err := c.db.Query(ctx,
		`SELECT permission FROM user_permissions
         WHERE user_id = $1 AND tenant_id = $2`,
		userID, tenantID,
	)
	if err != nil {
		// user_permissions table may not exist yet — fall back to role defaults
		return c.roleBasedPermissions(ctx, userID, tenantID)
	}
	defer rows.Close()

	var perms []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			continue
		}
		perms = append(perms, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading user_permissions: %w", err)
	}

	if len(perms) == 0 {
		return c.roleBasedPermissions(ctx, userID, tenantID)
	}
	return perms, nil
}

// roleBasedPermissions maps the user's role to its default permission set.
// Uses the same namespaced scheme as rbac.Engine (e.g. "markets:read").
// Plan-level entitlements are NOT added here — that is rbac.Engine's job.
func (c *Client) roleBasedPermissions(ctx context.Context, userID, tenantID string) ([]string, error) {
	role, err := c.GetUserRole(ctx, userID, tenantID)
	if err != nil {
		// No role assigned — grant minimal read-only access
		return []string{"markets:read"}, nil
	}

	base := map[string][]string{
		"admin": {
			"markets:read", "markets:write", "markets:stream",
			"analytics:read", "analytics:export", "analytics:backtest",
			"agents:read", "agents:write", "agents:execute",
			"users:read", "users:write",
		},
		"editor": {
			"markets:read", "markets:write",
			"analytics:read",
			"agents:read", "agents:execute",
		},
		"viewer": {
			"markets:read",
			"analytics:read",
		},
		"billing": {
			"markets:read",
		},
	}

	perms, ok := base[role]
	if !ok {
		perms = []string{"markets:read"}
	}
	return perms, nil
}

// ── Session methods ──────────────────────────────────────────────────────

type Session struct {
	ID                string
	UserID            string
	TenantID          string
	DeviceFingerprint string
	IP                string
	UserAgent         string
	ExpiresAt         time.Time
	CreatedAt         time.Time
	RevokedAt         *time.Time
}

func (c *Client) CreateSession(ctx context.Context, userID, tenantID, deviceFingerprint, ip, userAgent string, expiresAt time.Time) (string, error) {
	var sessionID string
	err := c.db.QueryRow(ctx,
		`INSERT INTO active_sessions (user_id, tenant_id, device_fingerprint, ip_address, user_agent, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING session_id`,
		userID, tenantID, deviceFingerprint, ip, userAgent, expiresAt,
	).Scan(&sessionID)
	return sessionID, err
}

func (c *Client) GetSessionByID(ctx context.Context, sessionID string) (*Session, error) {
	var s Session
	err := c.db.QueryRow(ctx,
		`SELECT session_id, user_id, tenant_id, device_fingerprint, ip_address, user_agent, expires_at, created_at, revoked_at
         FROM active_sessions WHERE session_id = $1`,
		sessionID,
	).Scan(&s.ID, &s.UserID, &s.TenantID, &s.DeviceFingerprint, &s.IP, &s.UserAgent, &s.ExpiresAt, &s.CreatedAt, &s.RevokedAt)
	if err != nil {
		return nil, err
	}
	return &s, nil
}

func (c *Client) StoreRefreshToken(ctx context.Context, sessionID, refreshTokenHash string, expiresAt time.Time) error {
	_, err := c.db.Exec(ctx,
		`UPDATE active_sessions SET refresh_token_hash = $1, refresh_expires_at = $2 WHERE session_id = $3`,
		refreshTokenHash, expiresAt, sessionID,
	)
	return err
}

func (c *Client) ConsumeRefreshToken(ctx context.Context, refreshTokenHash string) (string, error) {
	var sessionID string
	err := c.db.QueryRow(ctx,
		`UPDATE active_sessions
         SET refresh_token_hash = NULL, refresh_expires_at = NULL
         WHERE refresh_token_hash = $1 AND refresh_expires_at > NOW()
         RETURNING session_id`,
		refreshTokenHash,
	).Scan(&sessionID)
	if err != nil {
		return "", err
	}
	return sessionID, nil
}

func (c *Client) RevokeSession(ctx context.Context, sessionID, userID, tenantID string) error {
	_, err := c.db.Exec(ctx,
		`UPDATE active_sessions SET revoked_at = NOW()
         WHERE session_id = $1 AND user_id = $2 AND tenant_id = $3`,
		sessionID, userID, tenantID,
	)
	return err
}

func (c *Client) ListSessions(ctx context.Context, userID, tenantID string) ([]Session, error) {
	rows, err := c.db.Query(ctx,
		`SELECT session_id, user_id, tenant_id, device_fingerprint, ip_address, user_agent, expires_at, created_at, revoked_at
         FROM active_sessions
         WHERE user_id = $1 AND tenant_id = $2 AND revoked_at IS NULL
         ORDER BY created_at DESC`,
		userID, tenantID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var sessions []Session
	for rows.Next() {
		var s Session
		if err := rows.Scan(&s.ID, &s.UserID, &s.TenantID, &s.DeviceFingerprint, &s.IP, &s.UserAgent, &s.ExpiresAt, &s.CreatedAt, &s.RevokedAt); err != nil {
			continue
		}
		sessions = append(sessions, s)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing sessions: %w", err)
	}
	return sessions, nil
}

// RevokeAllSessions revokes active sessions for a user in a tenant.
//
// exceptSessionID = ""         → revoke ALL sessions (password reset use-case).
// exceptSessionID = "<uuid>"   → revoke all EXCEPT that session.
//
// FIX: The old implementation passed an empty string for a UUID column which
// caused a Postgres type-cast error at runtime via pgx. We now branch instead.
func (c *Client) RevokeAllSessions(ctx context.Context, userID, tenantID, exceptSessionID string) error {
	var err error
	if exceptSessionID == "" {
		_, err = c.db.Exec(ctx,
			`UPDATE active_sessions SET revoked_at = NOW()
             WHERE user_id = $1 AND tenant_id = $2 AND revoked_at IS NULL`,
			userID, tenantID,
		)
	} else {
		_, err = c.db.Exec(ctx,
			`UPDATE active_sessions SET revoked_at = NOW()
             WHERE user_id = $1 AND tenant_id = $2
               AND session_id != $3 AND revoked_at IS NULL`,
			userID, tenantID, exceptSessionID,
		)
	}
	return err
}

// ── MFA ──────────────────────────────────────────────────────────────────

func (c *Client) GetMFASecret(ctx context.Context, userID, tenantID string) (string, error) {
	var secret string
	err := c.db.QueryRow(ctx,
		`SELECT secret FROM mfa_secrets WHERE user_id = $1 AND tenant_id = $2 AND enabled = true`,
		userID, tenantID,
	).Scan(&secret)
	if err != nil {
		return "", err
	}
	return secret, nil
}

func (c *Client) StoreMFASecret(ctx context.Context, userID, tenantID, secret string) error {
	_, err := c.db.Exec(ctx,
		`INSERT INTO mfa_secrets (user_id, tenant_id, secret, enabled, verified)
         VALUES ($1, $2, $3, false, false)
         ON CONFLICT (user_id, tenant_id) DO UPDATE SET secret = $3, enabled = false, verified = false`,
		userID, tenantID, secret,
	)
	return err
}

func (c *Client) EnableMFA(ctx context.Context, userID, tenantID string) error {
	_, err := c.db.Exec(ctx,
		`UPDATE mfa_secrets SET enabled = true, verified = true, updated_at = NOW()
         WHERE user_id = $1 AND tenant_id = $2`,
		userID, tenantID,
	)
	return err
}

func (c *Client) DisableMFA(ctx context.Context, userID, tenantID string) error {
	_, err := c.db.Exec(ctx,
		`DELETE FROM mfa_secrets WHERE user_id = $1 AND tenant_id = $2`,
		userID, tenantID,
	)
	return err
}

func (c *Client) StoreSMSAttempt(ctx context.Context, userID, tenantID, phone, code string, expiresAt time.Time) error {
	_, err := c.db.Exec(ctx,
		`INSERT INTO sms_mfa_attempts (user_id, tenant_id, phone_number, code, expires_at)
         VALUES ($1, $2, $3, $4, $5)`,
		userID, tenantID, phone, code, expiresAt,
	)
	return err
}

func (c *Client) VerifySMSAttempt(ctx context.Context, userID, tenantID, phone, code string) (bool, error) {
	var id int64
	var expiresAt time.Time
	err := c.db.QueryRow(ctx,
		`SELECT id, expires_at FROM sms_mfa_attempts
         WHERE user_id = $1 AND tenant_id = $2 AND phone_number = $3 AND code = $4 AND verified = false
         ORDER BY created_at DESC LIMIT 1`,
		userID, tenantID, phone, code,
	).Scan(&id, &expiresAt)
	if err != nil {
		return false, err
	}
	if time.Now().After(expiresAt) {
		return false, nil
	}
	_, err = c.db.Exec(ctx,
		`UPDATE sms_mfa_attempts SET verified = true WHERE id = $1`,
		id,
	)
	return err == nil, err
}

// ── Failed login attempts (brute force) ──────────────────────────────────

func (c *Client) RecordFailedLogin(ctx context.Context, userID, ip string) error {
	_, err := c.db.Exec(ctx,
		`INSERT INTO failed_login_attempts (user_id, ip_address) VALUES ($1, $2)`,
		userID, ip,
	)
	return err
}

func (c *Client) CountFailedAttempts(ctx context.Context, userID, ip string, window time.Duration) (int, error) {
	var count int
	err := c.db.QueryRow(ctx,
		`SELECT COUNT(*) FROM failed_login_attempts
         WHERE (user_id = $1 OR ip_address = $2) AND attempted_at > NOW() - $3::INTERVAL`,
		userID, ip, window,
	).Scan(&count)
	return count, err
}

// ── Password history ──────────────────────────────────────────────────────

func (c *Client) AddPasswordHistory(ctx context.Context, userID, tenantID, passwordHash string) error {
	_, err := c.db.Exec(ctx,
		`INSERT INTO password_history (user_id, tenant_id, password_hash) VALUES ($1, $2, $3)`,
		userID, tenantID, passwordHash,
	)
	return err
}

func (c *Client) CheckPasswordReuse(ctx context.Context, userID, tenantID, passwordHash string) (bool, error) {
	var count int
	err := c.db.QueryRow(ctx,
		`SELECT COUNT(*) FROM password_history
         WHERE user_id = $1 AND tenant_id = $2 AND password_hash = $3`,
		userID, tenantID, passwordHash,
	).Scan(&count)
	return count > 0, err
}

// ── Account recovery ──────────────────────────────────────────────────────

func (c *Client) CreateRecoveryToken(ctx context.Context, userID, tenantID, token string, expiresAt time.Time) error {
	_, err := c.db.Exec(ctx,
		`INSERT INTO account_recovery_tokens (user_id, tenant_id, token, expires_at)
         VALUES ($1, $2, $3, $4)`,
		userID, tenantID, token, expiresAt,
	)
	return err
}

func (c *Client) ValidateRecoveryToken(ctx context.Context, token string) (userID, tenantID string, err error) {
	var expiresAt time.Time
	var usedAt *time.Time
	err = c.db.QueryRow(ctx,
		`SELECT user_id, tenant_id, expires_at, used_at FROM account_recovery_tokens WHERE token = $1`,
		token,
	).Scan(&userID, &tenantID, &expiresAt, &usedAt)
	if err != nil {
		return "", "", err
	}
	if usedAt != nil || time.Now().After(expiresAt) {
		return "", "", fmt.Errorf("token invalid or expired")
	}
	return userID, tenantID, nil
}

func (c *Client) MarkRecoveryTokenUsed(ctx context.Context, token string) error {
	_, err := c.db.Exec(ctx,
		`UPDATE account_recovery_tokens SET used_at = NOW() WHERE token = $1`,
		token,
	)
	return err
}

// ── API Keys ──────────────────────────────────────────────────────────────

type APIKey struct {
	ID          int64
	Name        string
	Permissions []string
	ExpiresAt   *time.Time
	LastUsedAt  *time.Time
	CreatedAt   time.Time
}

// CreateAPIKey expects keyHash to be a SHA-256 hex string (use HashToken).
// The raw key must NEVER be stored.
func (c *Client) CreateAPIKey(ctx context.Context, tenantID, userID, name, keyHash string, permissions []string, expiresAt *time.Time) error {
	_, err := c.db.Exec(ctx,
		`INSERT INTO api_keys (tenant_id, user_id, name, key_hash, permissions, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6)`,
		tenantID, userID, name, keyHash, permissions, expiresAt,
	)
	return err
}

func (c *Client) ListAPIKeys(ctx context.Context, userID, tenantID string) ([]APIKey, error) {
	rows, err := c.db.Query(ctx,
		`SELECT id, name, permissions, expires_at, last_used_at, created_at
         FROM api_keys WHERE user_id = $1 AND tenant_id = $2
         ORDER BY created_at DESC`,
		userID, tenantID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var keys []APIKey
	for rows.Next() {
		var k APIKey
		if err := rows.Scan(&k.ID, &k.Name, &k.Permissions, &k.ExpiresAt, &k.LastUsedAt, &k.CreatedAt); err != nil {
			continue
		}
		keys = append(keys, k)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing api keys: %w", err)
	}
	return keys, nil
}

func (c *Client) RevokeAPIKey(ctx context.Context, keyID int64, userID, tenantID string) error {
	_, err := c.db.Exec(ctx,
		`DELETE FROM api_keys WHERE id = $1 AND user_id = $2 AND tenant_id = $3`,
		keyID, userID, tenantID,
	)
	return err
}

func (c *Client) ValidateAPIKey(ctx context.Context, keyHash string) (userID, tenantID string, permissions []string, err error) {
	var expiresAt *time.Time
	err = c.db.QueryRow(ctx,
		`SELECT user_id, tenant_id, permissions, expires_at FROM api_keys WHERE key_hash = $1`,
		keyHash,
	).Scan(&userID, &tenantID, &permissions, &expiresAt)
	if err != nil {
		return "", "", nil, err
	}
	if expiresAt != nil && time.Now().After(*expiresAt) {
		return "", "", nil, fmt.Errorf("key expired")
	}
	_, _ = c.db.Exec(ctx,
		`UPDATE api_keys SET last_used_at = NOW() WHERE key_hash = $1`,
		keyHash,
	)
	return userID, tenantID, permissions, nil
}

// ── Utility ───────────────────────────────────────────────────────────────

func HashToken(token string) string {
	hash := sha256.Sum256([]byte(token))
	return hex.EncodeToString(hash[:])
}
