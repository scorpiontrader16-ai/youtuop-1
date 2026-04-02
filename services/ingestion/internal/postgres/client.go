// services/ingestion/internal/postgres/client.go
package postgres

import (
	"context"
	"database/sql"
	"embed"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

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
		return nil, fmt.Errorf("open postgres connection: %w", err)
	}

	db.SetMaxOpenConns(cfg.MaxOpenConns)
	db.SetMaxIdleConns(cfg.MaxIdleConns)
	db.SetConnMaxLifetime(cfg.ConnLifetime)

	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}

	logger.Info("postgres connected",
		"host", cfg.Host,
		"port", cfg.Port,
		"database", cfg.Database,
	)

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
		logger.Warn("postgres not ready, retrying",
			"attempt", attempt,
			"error", err,
		)
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

	c.logger.Info("postgres migrations applied successfully")
	return nil
}

func (c *Client) MigrateDown(ctx context.Context) error {
	goose.SetBaseFS(migrationsFS)
	if err := goose.SetDialect("postgres"); err != nil {
		return fmt.Errorf("set goose dialect: %w", err)
	}
	return goose.DownContext(ctx, c.db, "migrations")
}

func (c *Client) DB() *sql.DB  { return c.db }
func (c *Client) Close() error { return c.db.Close() }

// ── WarmEvent Repository ───────────────────────────────────────────────────

type WarmEvent struct {
	EventID       string
	EventType     string
	Source        string
	SchemaVersion string
	TenantID      string
	PartitionKey  string
	ContentType   string
	Payload       string
	PayloadBytes  int
	TraceID       string
	SpanID        string
	OccurredAt    time.Time
	IngestedAt    time.Time
}

func (c *Client) InsertWarmEvents(ctx context.Context, events []WarmEvent) error {
	if len(events) == 0 {
		return nil
	}

	const query = `
		INSERT INTO warm_events (
			event_id,      event_type,    source,        schema_version,
			tenant_id,     partition_key, content_type,
			payload,       payload_bytes, trace_id,      span_id,
			occurred_at,   ingested_at
		)
		SELECT
			UNNEST($1::TEXT[]),         UNNEST($2::TEXT[]),
			UNNEST($3::TEXT[]),         UNNEST($4::TEXT[]),
			UNNEST($5::TEXT[]),         UNNEST($6::TEXT[]),
			UNNEST($7::TEXT[]),         UNNEST($8::TEXT[]),
			UNNEST($9::INTEGER[]),      UNNEST($10::TEXT[]),
			UNNEST($11::TEXT[]),
			UNNEST($12::TIMESTAMPTZ[]), UNNEST($13::TIMESTAMPTZ[])
		ON CONFLICT (event_id) DO NOTHING`

	eventIDs      := make([]string,    len(events))
	eventTypes    := make([]string,    len(events))
	sources       := make([]string,    len(events))
	schemaVers    := make([]string,    len(events))
	tenantIDs     := make([]string,    len(events))
	partitionKeys := make([]string,    len(events))
	contentTypes  := make([]string,    len(events))
	payloads      := make([]string,    len(events))
	payloadBytes  := make([]int,       len(events))
	traceIDs      := make([]string,    len(events))
	spanIDs       := make([]string,    len(events))
	occurredAts   := make([]time.Time, len(events))
	ingestedAts   := make([]time.Time, len(events))

	for i, e := range events {
		eventIDs[i]      = e.EventID
		eventTypes[i]    = e.EventType
		sources[i]       = e.Source
		schemaVers[i]    = e.SchemaVersion
		tenantIDs[i]     = e.TenantID
		partitionKeys[i] = e.PartitionKey
		contentTypes[i]  = e.ContentType
		payloads[i]      = e.Payload
		payloadBytes[i]  = e.PayloadBytes
		traceIDs[i]      = e.TraceID
		spanIDs[i]       = e.SpanID
		occurredAts[i]   = e.OccurredAt
		ingestedAts[i]   = e.IngestedAt
	}

	_, err := c.db.ExecContext(ctx, query,
		eventIDs, eventTypes, sources, schemaVers,
		tenantIDs, partitionKeys, contentTypes,
		payloads, payloadBytes, traceIDs, spanIDs,
		occurredAts, ingestedAts,
	)
	if err != nil {
		return fmt.Errorf("insert warm events (batch=%d): %w", len(events), err)
	}

	c.logger.Debug("warm events inserted", "count", len(events))
	return nil
}

func (c *Client) MarkArchived(ctx context.Context, eventIDs []string) error {
	if len(eventIDs) == 0 {
		return nil
	}
	_, err := c.db.ExecContext(ctx, `
		UPDATE warm_events
		SET    archived_at = NOW()
		WHERE  event_id    = ANY($1::TEXT[])
		AND    archived_at IS NULL`,
		eventIDs,
	)
	if err != nil {
		return fmt.Errorf("mark archived: %w", err)
	}
	return nil
}

// RecordParquetKey يسجّل الـ S3 key قبل MarkArchived لضمان idempotency
func (c *Client) RecordParquetKey(ctx context.Context, eventIDs []string, key string) error {
	if len(eventIDs) == 0 {
		return nil
	}
	_, err := c.db.ExecContext(ctx, `
		UPDATE warm_events
		SET    parquet_key = $1
		WHERE  event_id    = ANY($2::TEXT[])
		AND    parquet_key IS NULL`,
		key, eventIDs,
	)
	if err != nil {
		return fmt.Errorf("record parquet key: %w", err)
	}
	return nil
}

// RecoverPendingArchive يُكمل الـ records التي كُتب لها Parquet لكن لم تُحدَّث archived_at
func (c *Client) RecoverPendingArchive(ctx context.Context) error {
	_, err := c.db.ExecContext(ctx, `
		UPDATE warm_events
		SET    archived_at = NOW()
		WHERE  parquet_key IS NOT NULL
		AND    archived_at IS NULL`,
	)
	if err != nil {
		return fmt.Errorf("recover pending archive: %w", err)
	}
	return nil
}

// GetUnarchived يجيب records التي لم تُكتب لها Parquet بعد
func (c *Client) GetUnarchived(ctx context.Context, olderThan time.Time, limit int) ([]WarmEvent, error) {
	rows, err := c.db.QueryContext(ctx, `
		SELECT event_id,    event_type,    source,      schema_version,
		       tenant_id,   partition_key, content_type,
		       payload,     payload_bytes, trace_id,    span_id,
		       occurred_at, ingested_at
		FROM   warm_events
		WHERE  archived_at IS NULL
		AND    parquet_key  IS NULL
		AND    occurred_at  < $1
		ORDER  BY occurred_at ASC
		LIMIT  $2`,
		olderThan, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("query unarchived events: %w", err)
	}
	defer rows.Close()

	var events []WarmEvent
	for rows.Next() {
		var e WarmEvent
		if err := rows.Scan(
			&e.EventID, &e.EventType, &e.Source, &e.SchemaVersion,
			&e.TenantID, &e.PartitionKey, &e.ContentType,
			&e.Payload, &e.PayloadBytes, &e.TraceID, &e.SpanID,
			&e.OccurredAt, &e.IngestedAt,
		); err != nil {
			return nil, fmt.Errorf("scan warm event: %w", err)
		}
		events = append(events, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("rows error: %w", err)
	}
	return events, nil
}

// ── Helpers ───────────────────────────────────────────────────────────────

func getEnv(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func getEnvInt(key string, defaultVal int) int {
	v := os.Getenv(key)
	if v == "" {
		return defaultVal
	}
	i, err := strconv.Atoi(v)
	if err != nil {
		return defaultVal
	}
	return i
}
