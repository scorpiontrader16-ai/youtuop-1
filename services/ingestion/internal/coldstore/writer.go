// services/ingestion/internal/coldstore/writer.go
package coldstore

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	"github.com/parquet-go/parquet-go"
)

// Config إعدادات الاتصال بـ MinIO / S3
type Config struct {
	Endpoint        string
	AccessKeyID     string
	SecretAccessKey string
	Bucket          string
	UseSSL          bool
	// Prefix — prefix للـ object keys مثلاً "events/2024/01/"
	Prefix string
}

// ConfigFromEnv يقرأ الإعدادات من environment variables
func ConfigFromEnv() Config {
	return Config{
		Endpoint:        getEnv("MINIO_ENDPOINT", "localhost:9000"),
		AccessKeyID:     getEnv("MINIO_ACCESS_KEY", ""),
		SecretAccessKey: getEnv("MINIO_SECRET_KEY", ""),
		Bucket:          getEnv("MINIO_BUCKET_PARQUET", "parquet-archive"),
		UseSSL:          getEnv("MINIO_USE_SSL", "false") == "true",
		Prefix:          getEnv("MINIO_PREFIX", "events"),
	}
}

// EventRecord هو الـ Parquet schema — كل field بيتحول لـ Parquet column
type EventRecord struct {
	EventID       string    `parquet:"event_id"`
	EventType     string    `parquet:"event_type"`
	Source        string    `parquet:"source"`
	SchemaVersion string    `parquet:"schema_version"`
	TenantID      string    `parquet:"tenant_id"`
	PartitionKey  string    `parquet:"partition_key"`
	ContentType   string    `parquet:"content_type"`
	Payload       string    `parquet:"payload"`
	PayloadBytes  int32     `parquet:"payload_bytes"`
	TraceID       string    `parquet:"trace_id"`
	SpanID        string    `parquet:"span_id"`
	OccurredAt    int64     `parquet:"occurred_at"`  // Unix milliseconds
	IngestedAt    int64     `parquet:"ingested_at"`  // Unix milliseconds
	ArchivedAt    int64     `parquet:"archived_at"`  // Unix milliseconds
}

// Writer يكتب الـ events كـ Parquet files في S3/MinIO
type Writer struct {
	client *minio.Client
	cfg    Config
	logger *slog.Logger
}

// New ينشئ writer جديد ويتحقق من الاتصال بـ S3
func New(ctx context.Context, cfg Config, logger *slog.Logger) (*Writer, error) {
	if logger == nil {
		logger = slog.Default()
	}

	client, err := minio.New(cfg.Endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(cfg.AccessKeyID, cfg.SecretAccessKey, ""),
		Secure: cfg.UseSSL,
	})
	if err != nil {
		return nil, fmt.Errorf("create minio client: %w", err)
	}

	// تحقق من وجود الـ bucket
	exists, err := client.BucketExists(ctx, cfg.Bucket)
	if err != nil {
		return nil, fmt.Errorf("check bucket %q: %w", cfg.Bucket, err)
	}
	if !exists {
		return nil, fmt.Errorf("bucket %q does not exist — run minio-init first", cfg.Bucket)
	}

	logger.Info("coldstore connected",
		"endpoint", cfg.Endpoint,
		"bucket", cfg.Bucket,
	)

	return &Writer{client: client, cfg: cfg, logger: logger}, nil
}

// WaitForColdStore ينتظر MinIO يكون ready (max 60s)
func WaitForColdStore(ctx context.Context, cfg Config, logger *slog.Logger) (*Writer, error) {
	if logger == nil {
		logger = slog.Default()
	}
	logger.Info("waiting for coldstore (minio)...")

	var lastErr error
	for attempt := 1; attempt <= 30; attempt++ {
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("context cancelled: %w", ctx.Err())
		default:
		}

		w, err := New(ctx, cfg, logger)
		if err == nil {
			return w, nil
		}

		lastErr = err
		logger.Warn("coldstore not ready, retrying",
			"attempt", attempt,
			"error", err,
		)
		time.Sleep(2 * time.Second)
	}

	return nil, fmt.Errorf("coldstore not ready after 60s: %w", lastErr)
}

// WriteParquet يكتب batch من الـ records كـ Parquet file في S3
// الـ object key: {prefix}/{tenant}/{year}/{month}/{day}/{hour}_{nanotime}.parquet
func (w *Writer) WriteParquet(ctx context.Context, records []EventRecord) (string, error) {
	if len(records) == 0 {
		return "", nil
	}

	// ── بناء الـ Parquet file في memory ──────────────────────────────────
	var buf bytes.Buffer
	pw := parquet.NewGenericWriter[EventRecord](&buf)

	if _, err := pw.Write(records); err != nil {
		return "", fmt.Errorf("write parquet records: %w", err)
	}
	if err := pw.Close(); err != nil {
		return "", fmt.Errorf("close parquet writer: %w", err)
	}

	// ── بناء الـ object key ───────────────────────────────────────────────
	// نستخدم وقت أول record للـ partitioning
	refTime := time.UnixMilli(records[0].OccurredAt).UTC()
	key := fmt.Sprintf("%s/%d/%02d/%02d/%02d_%d.parquet",
		w.cfg.Prefix,
		refTime.Year(),
		refTime.Month(),
		refTime.Day(),
		refTime.Hour(),
		time.Now().UnixNano(),
	)

	// ── رفع على S3 ────────────────────────────────────────────────────────
	data := buf.Bytes()
	_, err := w.client.PutObject(ctx, w.cfg.Bucket, key,
		bytes.NewReader(data),
		int64(len(data)),
		minio.PutObjectOptions{
			ContentType:  "application/octet-stream",
			UserMetadata: map[string]string{
				"record-count": strconv.Itoa(len(records)),
				"schema":       "EventRecord/v1",
			},
		},
	)
	if err != nil {
		return "", fmt.Errorf("put object %q: %w", key, err)
	}

	w.logger.Info("parquet file written to coldstore",
		"key",          key,
		"records",      len(records),
		"size_bytes",   len(data),
	)

	return key, nil
}

// ObjectExists يتحقق من وجود object في S3
func (w *Writer) ObjectExists(ctx context.Context, key string) (bool, error) {
	_, err := w.client.StatObject(ctx, w.cfg.Bucket, key, minio.StatObjectOptions{})
	if err != nil {
		errResp := minio.ToErrorResponse(err)
		if errResp.Code == "NoSuchKey" {
			return false, nil
		}
		return false, fmt.Errorf("stat object %q: %w", key, err)
	}
	return true, nil
}

// ── Helpers ───────────────────────────────────────────────────────────────

func getEnv(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}
