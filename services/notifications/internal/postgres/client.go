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
	c.logger.Info("notifications migrations applied")
	return nil
}

func (c *Client) DB() *sql.DB  { return c.db }
func (c *Client) Close() error { return c.db.Close() }

// ── Domain Types ──────────────────────────────────────────────────────────

type NotificationTemplate struct {
	Name      string
	Type      string
	Subject   *string
	BodyHTML  string
	BodyText  string
	Variables []string
}

type Notification struct {
	ID        string
	TenantID  string
	UserID    string
	Type      string
	Title     string
	Body      string
	Data      map[string]any
	Read      bool
	ReadAt    *time.Time
	CreatedAt time.Time
}

type NotificationPreferences struct {
	UserID          string
	TenantID        string
	EmailEnabled    bool
	InAppEnabled    bool
	AlertEmail      bool
	AlertInApp      bool
	InvoiceEmail    bool
	DigestEmail     bool
	DigestFrequency string
}

// ── Templates ─────────────────────────────────────────────────────────────

func (c *Client) GetTemplate(ctx context.Context, name string) (*NotificationTemplate, error) {
	const q = `
		SELECT name, type, subject, body_html, body_text
		FROM notification_templates WHERE name = $1`

	t := &NotificationTemplate{}
	err := c.db.QueryRowContext(ctx, q, name).Scan(
		&t.Name, &t.Type, &t.Subject, &t.BodyHTML, &t.BodyText,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return t, err
}

// ── Preferences ───────────────────────────────────────────────────────────

func (c *Client) GetPreferences(ctx context.Context, userID, tenantID string) (*NotificationPreferences, error) {
	const q = `
		SELECT user_id, tenant_id, email_enabled, in_app_enabled,
		       alert_email, alert_in_app, invoice_email,
		       digest_email, digest_frequency
		FROM notification_preferences
		WHERE user_id = $1 AND tenant_id = $2`

	p := &NotificationPreferences{}
	err := c.db.QueryRowContext(ctx, q, userID, tenantID).Scan(
		&p.UserID, &p.TenantID, &p.EmailEnabled, &p.InAppEnabled,
		&p.AlertEmail, &p.AlertInApp, &p.InvoiceEmail,
		&p.DigestEmail, &p.DigestFrequency,
	)
	if errors.Is(err, sql.ErrNoRows) {
		// Default preferences — كل حاجة enabled
		return &NotificationPreferences{
			UserID: userID, TenantID: tenantID,
			EmailEnabled: true, InAppEnabled: true,
			AlertEmail: true, AlertInApp: true,
			InvoiceEmail: true, DigestEmail: true,
			DigestFrequency: "weekly",
		}, nil
	}
	return p, err
}

func (c *Client) UpsertPreferences(ctx context.Context, p *NotificationPreferences) error {
	const q = `
		INSERT INTO notification_preferences
			(user_id, tenant_id, email_enabled, in_app_enabled,
			 alert_email, alert_in_app, invoice_email,
			 digest_email, digest_frequency)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		ON CONFLICT (user_id, tenant_id) DO UPDATE SET
			email_enabled    = EXCLUDED.email_enabled,
			in_app_enabled   = EXCLUDED.in_app_enabled,
			alert_email      = EXCLUDED.alert_email,
			alert_in_app     = EXCLUDED.alert_in_app,
			invoice_email    = EXCLUDED.invoice_email,
			digest_email     = EXCLUDED.digest_email,
			digest_frequency = EXCLUDED.digest_frequency`

	_, err := c.db.ExecContext(ctx, q,
		p.UserID, p.TenantID, p.EmailEnabled, p.InAppEnabled,
		p.AlertEmail, p.AlertInApp, p.InvoiceEmail,
		p.DigestEmail, p.DigestFrequency,
	)
	return err
}

// ── In-App Notifications ──────────────────────────────────────────────────

func (c *Client) CreateNotification(ctx context.Context,
	tenantID, userID, notifType, title, body string,
	data map[string]any,
) (*Notification, error) {
	id := newID()
	const q = `
		INSERT INTO notifications (id, tenant_id, user_id, type, title, body, data)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING id, tenant_id, user_id, type, title, body, read, read_at, created_at`

	n := &Notification{}
	err := c.db.QueryRowContext(ctx, q,
		id, tenantID, userID, notifType, title, body, encodeJSON(data),
	).Scan(
		&n.ID, &n.TenantID, &n.UserID, &n.Type, &n.Title, &n.Body,
		&n.Read, &n.ReadAt, &n.CreatedAt,
	)
	return n, err
}

func (c *Client) ListUnread(ctx context.Context, userID string, limit int) ([]*Notification, error) {
	const q = `
		SELECT id, tenant_id, user_id, type, title, body, read, read_at, created_at
		FROM notifications
		WHERE user_id = $1 AND NOT read
		ORDER BY created_at DESC
		LIMIT $2`

	rows, err := c.db.QueryContext(ctx, q, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var notifs []*Notification
	for rows.Next() {
		n := &Notification{}
		if err := rows.Scan(
			&n.ID, &n.TenantID, &n.UserID, &n.Type, &n.Title, &n.Body,
			&n.Read, &n.ReadAt, &n.CreatedAt,
		); err != nil {
			return nil, err
		}
		notifs = append(notifs, n)
	}
	return notifs, rows.Err()
}

func (c *Client) MarkRead(ctx context.Context, notifID, userID string) error {
	tag, err := c.db.ExecContext(ctx, `
		UPDATE notifications SET read = TRUE, read_at = NOW()
		WHERE id = $1 AND user_id = $2 AND NOT read`,
		notifID, userID,
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

func (c *Client) MarkAllRead(ctx context.Context, userID string) error {
	_, err := c.db.ExecContext(ctx, `
		UPDATE notifications SET read = TRUE, read_at = NOW()
		WHERE user_id = $1 AND NOT read`, userID,
	)
	return err
}

func (c *Client) UnreadCount(ctx context.Context, userID string) (int, error) {
	var count int
	err := c.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM notifications WHERE user_id = $1 AND NOT read`,
		userID,
	).Scan(&count)
	return count, err
}

// ── Email Log ─────────────────────────────────────────────────────────────

func (c *Client) LogEmail(ctx context.Context,
	tenantID, userID *string, resendID, templateName, toEmail, subject, status string,
	emailErr error,
) error {
	var errMsg *string
	if emailErr != nil {
		s := emailErr.Error()
		errMsg = &s
	}
	_, err := c.db.ExecContext(ctx, `
		INSERT INTO email_log
			(tenant_id, user_id, resend_id, template_name, to_email, subject, status, error)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
		tenantID, userID, resendID, templateName, toEmail, subject, status, errMsg,
	)
	return err
}

// ── Helpers ───────────────────────────────────────────────────────────────

func newID() string {
	return uuid.NewString()
}

func encodeJSON(m map[string]any) string {
	if m == nil {
		return "{}"
	}
	b, err := json.Marshal(m)
	if err != nil {
		return "{}"
	}
	return string(b)
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
