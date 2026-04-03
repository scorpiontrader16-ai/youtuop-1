// services/ingestion/internal/clickhouse/writer.go
package clickhouse

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"

	"github.com/ClickHouse/clickhouse-go/v2"
	"github.com/ClickHouse/clickhouse-go/v2/lib/driver"
	"google.golang.org/protobuf/types/known/structpb"
)

// Config هي إعدادات الاتصال بـ ClickHouse
type Config struct {
	Host     string
	Port     int
	Database string
	Username string
	Password string
	TLS      bool
}

// ConfigFromEnv يقرأ الإعدادات من environment variables
func ConfigFromEnv() Config {
	return Config{
		Host:     getEnv("CLICKHOUSE_HOST", "localhost"),
		Port:     getEnvInt("CLICKHOUSE_PORT", 9000),
		Database: getEnv("CLICKHOUSE_DB", "events"),
		Username: getEnv("CLICKHOUSE_USER", "platform"),
		Password: getEnv("CLICKHOUSE_PASSWORD", ""),
		TLS:      getEnv("CLICKHOUSE_TLS", "false") == "true",
	}
}

// Writer يكتب الـ events في ClickHouse باستخدام batch insert
type Writer struct {
	conn   driver.Conn
	logger *slog.Logger
}

// EventRow هو الـ struct اللي بيتكتب في ClickHouse
type EventRow struct {
	EventID       string
	EventType     string
	Source        string
	SchemaVersion string
	OccurredAt    time.Time
	IngestedAt    time.Time
	TenantID      string
	PartitionKey  string
	ContentType   string
	Payload       string
	PayloadBytes  uint32
	TraceID       string
	SpanID        string
	MetaKeys      []string
	MetaValues    []string
}

// New ينشئ writer جديد ويتحقق من الاتصال
func New(ctx context.Context, cfg Config, logger *slog.Logger) (*Writer, error) {
	if logger == nil {
		logger = slog.Default()
	}

	options := &clickhouse.Options{
		Addr: []string{fmt.Sprintf("%s:%d", cfg.Host, cfg.Port)},
		Auth: clickhouse.Auth{
			Database: cfg.Database,
			Username: cfg.Username,
			Password: cfg.Password,
		},
		DialTimeout:     10 * time.Second,
		MaxOpenConns:    10,
		MaxIdleConns:    5,
		ConnMaxLifetime: time.Hour,
		Compression: &clickhouse.Compression{
			Method: clickhouse.CompressionLZ4,
		},
	}

	if cfg.TLS {
		options.TLS = &tls.Config{MinVersion: tls.VersionTLS12}
	}

	conn, err := clickhouse.Open(options)
	if err != nil {
		return nil, fmt.Errorf("open clickhouse connection: %w", err)
	}

	if err := conn.Ping(ctx); err != nil {
		return nil, fmt.Errorf("ping clickhouse: %w", err)
	}

	logger.Info("clickhouse connected",
		"host", cfg.Host,
		"port", cfg.Port,
		"database", cfg.Database,
	)

	return &Writer{conn: conn, logger: logger}, nil
}

// WaitForClickHouse ينتظر الـ ClickHouse يكون ready (max 60s)
func WaitForClickHouse(ctx context.Context, cfg Config, logger *slog.Logger) (*Writer, error) {
	if logger == nil {
		logger = slog.Default()
	}
	logger.Info("waiting for clickhouse...")

	var lastErr error
	for attempt := 1; attempt <= 30; attempt++ {
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("context cancelled while waiting for clickhouse: %w", ctx.Err())
		default:
		}

		w, err := New(ctx, cfg, logger)
		if err == nil {
			return w, nil
		}

		lastErr = err
		logger.Warn("clickhouse not ready, retrying",
			"attempt", attempt,
			"error", err,
		)
		time.Sleep(2 * time.Second)
	}

	return nil, fmt.Errorf("clickhouse not ready after 60s: %w", lastErr)
}

// WriteEvent يكتب event واحد
func (w *Writer) WriteEvent(ctx context.Context, row EventRow) error {
	return w.WriteBatch(ctx, []EventRow{row})
}

// WriteBatch يكتب batch من الـ events في عملية واحدة
func (w *Writer) WriteBatch(ctx context.Context, rows []EventRow) error {
	if len(rows) == 0 {
		return nil
	}

	batch, err := w.conn.PrepareBatch(ctx,
		`INSERT INTO events.base_events
		(event_id, event_type, source, schema_version,
		 occurred_at, ingested_at,
		 tenant_id, partition_key,
		 content_type, payload, payload_bytes,
		 trace_id, span_id,
		 meta_keys, meta_values)`,
	)
	if err != nil {
		return fmt.Errorf("prepare batch: %w", err)
	}

	for _, r := range rows {
		if err := batch.Append(
			r.EventID,
			r.EventType,
			r.Source,
			r.SchemaVersion,
			r.OccurredAt,
			r.IngestedAt,
			r.TenantID,
			r.PartitionKey,
			r.ContentType,
			r.Payload,
			r.PayloadBytes,
			r.TraceID,
			r.SpanID,
			r.MetaKeys,
			r.MetaValues,
		); err != nil {
			return fmt.Errorf("append row event_id=%s: %w", r.EventID, err)
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("send batch of %d rows: %w", len(rows), err)
	}

	w.logger.Debug("batch written", "count", len(rows))
	return nil
}

// Close يغلق الاتصال
func (w *Writer) Close() error {
	return w.conn.Close()
}

// ── Helpers ───────────────────────────────────────────────────────────────

// MetaFromStruct يحوّل google.protobuf.Struct لـ parallel arrays
func MetaFromStruct(s *structpb.Struct) (keys []string, values []string) {
	if s == nil {
		return []string{}, []string{}
	}
	for k, v := range s.Fields {
		keys = append(keys, k)
		switch t := v.Kind.(type) {
		case *structpb.Value_StringValue:
			values = append(values, t.StringValue)
		case *structpb.Value_NumberValue:
			values = append(values, strconv.FormatFloat(t.NumberValue, 'f', -1, 64))
		case *structpb.Value_BoolValue:
			values = append(values, strconv.FormatBool(t.BoolValue))
		default:
			b, _ := json.Marshal(v)
			values = append(values, string(b))
		}
	}
	return keys, values
}

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
