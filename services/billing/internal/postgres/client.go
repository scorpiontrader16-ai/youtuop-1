package postgres

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

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

func (c *Client) DB() *sql.DB  { return c.db }
func (c *Client) Close() error { return c.db.Close() }

func (c *Client) SetTenantContext(ctx context.Context, tenantID string) error {
	_, err := c.db.ExecContext(ctx, "SELECT set_config('app.tenant_id', $1, true)", tenantID)
	return err
}

// ── Domain Types ──────────────────────────────────────────────────────────

type Subscription struct {
	ID                   string
	TenantID             string
	StripeSubscriptionID *string
	StripePriceID        *string
	Plan                 string
	Status               string
	CurrentPeriodStart   *time.Time
	CurrentPeriodEnd     *time.Time
	CancelAtPeriodEnd    bool
	CancelledAt          *time.Time
	TrialStart           time.Time
	TrialEnd             time.Time
	CreatedAt            time.Time
	UpdatedAt            time.Time
}

type Invoice struct {
	ID               string
	TenantID         string
	SubscriptionID   *string
	StripeInvoiceID  *string
	AmountDue        int64
	AmountPaid       int64
	Currency         string
	Status           string
	InvoicePDF       *string
	HostedInvoiceURL *string
	PeriodStart      *time.Time
	PeriodEnd        *time.Time
	DueDate          *time.Time
	PaidAt           *time.Time
	CreatedAt        time.Time
}

type UsageRecord struct {
	TenantID       string
	SubscriptionID *string
	Metric         string
	Quantity       int64
	PeriodStart    time.Time
	PeriodEnd      time.Time
}

// ── Tenant Billing ────────────────────────────────────────────────────────

// SetStripeCustomerID يحفظ الـ Stripe customer ID على الـ tenant
func (c *Client) SetStripeCustomerID(ctx context.Context, tenantID, customerID string) error {
	_, err := c.db.ExecContext(ctx, `
		UPDATE tenants SET stripe_customer_id = $2 WHERE id = $1`,
		tenantID, customerID,
	)
	return err
}

// GetStripeCustomerID يجيب الـ Stripe customer ID للـ tenant
func (c *Client) GetStripeCustomerID(ctx context.Context, tenantID string) (string, error) {
	var id *string
	err := c.db.QueryRowContext(ctx,
		`SELECT stripe_customer_id FROM tenants WHERE id = $1`, tenantID,
	).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if id == nil {
		return "", ErrNotFound
	}
	return *id, nil
}

// GetTenantBySlug يجيب tenant للتحقق من وجوده
func (c *Client) GetTenantBySlug(ctx context.Context, slug string) (id, name, plan string, err error) {
	err = c.db.QueryRowContext(ctx,
		`SELECT id, name, plan FROM tenants WHERE slug = $1 AND status = 'active'`, slug,
	).Scan(&id, &name, &plan)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", "", ErrNotFound
	}
	return
}

// ── Subscriptions ─────────────────────────────────────────────────────────

// CreateSubscription ينشئ subscription جديدة للـ tenant
func (c *Client) CreateSubscription(ctx context.Context, tenantID, plan string) (*Subscription, error) {
	const q = `
		INSERT INTO subscriptions (tenant_id, plan, status, trial_start, trial_end)
		VALUES ($1, $2, 'trialing', NOW(), NOW() + INTERVAL '14 days')
		RETURNING id, tenant_id, stripe_subscription_id, stripe_price_id,
		          plan, status, current_period_start, current_period_end,
		          cancel_at_period_end, cancelled_at, trial_start, trial_end,
		          created_at, updated_at`

	return c.scanSubscription(c.db.QueryRowContext(ctx, q, tenantID, plan))
}

// GetActiveSubscription يجيب الـ subscription النشطة للـ tenant
func (c *Client) GetActiveSubscription(ctx context.Context, tenantID string) (*Subscription, error) {
	const q = `
		SELECT id, tenant_id, stripe_subscription_id, stripe_price_id,
		       plan, status, current_period_start, current_period_end,
		       cancel_at_period_end, cancelled_at, trial_start, trial_end,
		       created_at, updated_at
		FROM subscriptions
		WHERE tenant_id = $1 AND status IN ('active', 'trialing', 'past_due')
		ORDER BY created_at DESC LIMIT 1`

	s, err := c.scanSubscription(c.db.QueryRowContext(ctx, q, tenantID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return s, err
}

// UpdateSubscriptionFromStripe يحدّث الـ subscription من Stripe webhook
func (c *Client) UpdateSubscriptionFromStripe(ctx context.Context,
	stripeSubID, status, plan string,
	periodStart, periodEnd *time.Time,
	cancelAtPeriodEnd bool,
) error {
	const q = `
		UPDATE subscriptions SET
			status               = $2,
			plan                 = $3,
			current_period_start = $4,
			current_period_end   = $5,
			cancel_at_period_end = $6
		WHERE stripe_subscription_id = $1`

	tag, err := c.db.ExecContext(ctx, q,
		stripeSubID, status, plan, periodStart, periodEnd, cancelAtPeriodEnd,
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

// AttachStripeSubscription يربط الـ Stripe subscription ID بالـ local subscription
func (c *Client) AttachStripeSubscription(ctx context.Context, localSubID, stripeSubID, stripePriceID string) error {
	_, err := c.db.ExecContext(ctx, `
		UPDATE subscriptions
		SET stripe_subscription_id = $2,
		    stripe_price_id        = $3,
		    status                 = 'active'
		WHERE id = $1`,
		localSubID, stripeSubID, stripePriceID,
	)
	return err
}

// ── Invoices ──────────────────────────────────────────────────────────────

// UpsertInvoiceFromStripe ينشئ أو يحدّث invoice من Stripe webhook
func (c *Client) UpsertInvoiceFromStripe(ctx context.Context,
	tenantID, stripeInvoiceID, status, currency string,
	amountDue, amountPaid int64,
	invoicePDF, hostedURL *string,
	periodStart, periodEnd, dueDate, paidAt *time.Time,
) error {
	const q = `
		INSERT INTO invoices (
			tenant_id, stripe_invoice_id, status, currency,
			amount_due, amount_paid, invoice_pdf, hosted_invoice_url,
			period_start, period_end, due_date, paid_at
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
		ON CONFLICT (stripe_invoice_id) DO UPDATE SET
			status             = EXCLUDED.status,
			amount_paid        = EXCLUDED.amount_paid,
			invoice_pdf        = EXCLUDED.invoice_pdf,
			hosted_invoice_url = EXCLUDED.hosted_invoice_url,
			paid_at            = EXCLUDED.paid_at`

	_, err := c.db.ExecContext(ctx, q,
		tenantID, stripeInvoiceID, status, currency,
		amountDue, amountPaid, invoicePDF, hostedURL,
		periodStart, periodEnd, dueDate, paidAt,
	)
	return err
}

// ListInvoices يجيب كل invoices للـ tenant مرتبة بالأحدث أولاً
func (c *Client) ListInvoices(ctx context.Context, tenantID string, limit int) ([]*Invoice, error) {
	const q = `
		SELECT id, tenant_id, subscription_id, stripe_invoice_id,
		       amount_due, amount_paid, currency, status,
		       invoice_pdf, hosted_invoice_url,
		       period_start, period_end, due_date, paid_at, created_at
		FROM invoices
		WHERE tenant_id = $1
		ORDER BY created_at DESC
		LIMIT $2`

	rows, err := c.db.QueryContext(ctx, q, tenantID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var invoices []*Invoice
	for rows.Next() {
		inv := &Invoice{}
		if err := rows.Scan(
			&inv.ID, &inv.TenantID, &inv.SubscriptionID, &inv.StripeInvoiceID,
			&inv.AmountDue, &inv.AmountPaid, &inv.Currency, &inv.Status,
			&inv.InvoicePDF, &inv.HostedInvoiceURL,
			&inv.PeriodStart, &inv.PeriodEnd, &inv.DueDate, &inv.PaidAt,
			&inv.CreatedAt,
		); err != nil {
			return nil, err
		}
		invoices = append(invoices, inv)
	}
	return invoices, rows.Err()
}

// ── Usage Records ─────────────────────────────────────────────────────────

// RecordUsage يسجّل usage للـ tenant — يُستدعى من الـ services التانية
func (c *Client) RecordUsage(ctx context.Context, r *UsageRecord) error {
	const q = `
		INSERT INTO usage_records (tenant_id, subscription_id, metric, quantity, period_start, period_end)
		VALUES ($1, $2, $3, $4, $5, $6)`
	_, err := c.db.ExecContext(ctx, q,
		r.TenantID, r.SubscriptionID, r.Metric, r.Quantity, r.PeriodStart, r.PeriodEnd,
	)
	return err
}

// GetUsageSummary يجيب إجمالي الـ usage للـ tenant في فترة معينة
func (c *Client) GetUsageSummary(ctx context.Context, tenantID string, from, to time.Time) (map[string]int64, error) {
	const q = `
		SELECT metric, SUM(quantity)
		FROM usage_records
		WHERE tenant_id = $1 AND period_start >= $2 AND period_end <= $3
		GROUP BY metric`

	rows, err := c.db.QueryContext(ctx, q, tenantID, from, to)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	result := make(map[string]int64)
	for rows.Next() {
		var metric string
		var total int64
		if err := rows.Scan(&metric, &total); err != nil {
			return nil, err
		}
		result[metric] = total
	}
	return result, rows.Err()
}

// ── Billing Events ────────────────────────────────────────────────────────

// StoreBillingEvent يحفظ Stripe webhook event لضمان idempotency
func (c *Client) StoreBillingEvent(ctx context.Context, stripeEventID, eventType string, payload []byte) error {
	_, err := c.db.ExecContext(ctx, `
		INSERT INTO billing_events (stripe_event_id, event_type, payload)
		VALUES ($1, $2, $3)
		ON CONFLICT (stripe_event_id) DO NOTHING`,
		stripeEventID, eventType, string(payload),
	)
	return err
}

// MarkEventProcessed يعلّم الـ event كـ processed
func (c *Client) MarkEventProcessed(ctx context.Context, stripeEventID string, processingErr error) error {
	var errMsg *string
	if processingErr != nil {
		s := processingErr.Error()
		errMsg = &s
	}
	_, err := c.db.ExecContext(ctx, `
		UPDATE billing_events
		SET processed = TRUE, processed_at = NOW(), error = $2
		WHERE stripe_event_id = $1`,
		stripeEventID, errMsg,
	)
	return err
}

// IsEventProcessed يتحقق إن الـ event اتعمل قبل كده (idempotency)
func (c *Client) IsEventProcessed(ctx context.Context, stripeEventID string) (bool, error) {
	var processed bool
	err := c.db.QueryRowContext(ctx,
		`SELECT processed FROM billing_events WHERE stripe_event_id = $1`,
		stripeEventID,
	).Scan(&processed)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return processed, err
}

// ── Helpers ───────────────────────────────────────────────────────────────

func (c *Client) scanSubscription(row *sql.Row) (*Subscription, error) {
	s := &Subscription{}
	err := row.Scan(
		&s.ID, &s.TenantID, &s.StripeSubscriptionID, &s.StripePriceID,
		&s.Plan, &s.Status, &s.CurrentPeriodStart, &s.CurrentPeriodEnd,
		&s.CancelAtPeriodEnd, &s.CancelledAt, &s.TrialStart, &s.TrialEnd,
		&s.CreatedAt, &s.UpdatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return s, err
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
