// services/ingestion/internal/tiering/job.go
package tiering

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/scorpiontrader16-ai/youtuop-1/services/ingestion/internal/coldstore"
	"github.com/scorpiontrader16-ai/youtuop-1/services/ingestion/internal/postgres"
)

const (
	defaultBatchSize     = 10_000
	defaultColdThreshold = 30 * 24 * time.Hour
	defaultTickInterval  = 1 * time.Hour
)

type Config struct {
	BatchSize     int
	ColdThreshold time.Duration
	TickInterval  time.Duration
}

func DefaultConfig() Config {
	return Config{
		BatchSize:     defaultBatchSize,
		ColdThreshold: defaultColdThreshold,
		TickInterval:  defaultTickInterval,
	}
}

type Job struct {
	pg     *postgres.Client
	cold   *coldstore.Writer
	cfg    Config
	logger *slog.Logger
}

func New(
	pg     *postgres.Client,
	cold   *coldstore.Writer,
	cfg    Config,
	logger *slog.Logger,
) *Job {
	if logger == nil {
		logger = slog.Default()
	}
	return &Job{
		pg:     pg,
		cold:   cold,
		cfg:    cfg,
		logger: logger,
	}
}

func (j *Job) Run(ctx context.Context) {
	j.logger.Info("tiering job started",
		"batch_size",     j.cfg.BatchSize,
		"cold_threshold", j.cfg.ColdThreshold,
		"tick_interval",  j.cfg.TickInterval,
	)

	if err := j.runOnce(ctx); err != nil {
		j.logger.Error("tiering run failed", "error", err)
	}

	ticker := time.NewTicker(j.cfg.TickInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			j.logger.Info("tiering job stopped")
			return
		case <-ticker.C:
			if err := j.runOnce(ctx); err != nil {
				j.logger.Error("tiering run failed", "error", err)
			}
		}
	}
}

func (j *Job) runOnce(ctx context.Context) error {
	olderThan := time.Now().UTC().Add(-j.cfg.ColdThreshold)

	j.logger.Info("tiering run started", "older_than", olderThan)

	// recover records that have parquet_key but missing archived_at
	if err := j.pg.RecoverPendingArchive(ctx); err != nil {
		j.logger.Error("recover pending archive failed", "error", err)
	}

	totalMoved := 0

	for {
		events, err := j.pg.GetUnarchived(ctx, olderThan, j.cfg.BatchSize)
		if err != nil {
			return fmt.Errorf("get unarchived events: %w", err)
		}
		if len(events) == 0 {
			break
		}

		records := toParquetRecords(events)

		key, err := j.cold.WriteParquet(ctx, records)
		if err != nil {
			return fmt.Errorf("write parquet: %w", err)
		}

		eventIDs := make([]string, len(events))
		for i, e := range events {
			eventIDs[i] = e.EventID
		}

		// record parquet key before marking archived — idempotency guarantee
		if err := j.pg.RecordParquetKey(ctx, eventIDs, key); err != nil {
			return fmt.Errorf("record parquet key (key=%s): %w", key, err)
		}

		// mark archived — if this fails, RecoverPendingArchive fixes it next run
		if err := j.pg.MarkArchived(ctx, eventIDs); err != nil {
			j.logger.Error("mark archived failed — recovery will fix on next run",
				"key",   key,
				"count", len(eventIDs),
				"error", err,
			)
		}

		totalMoved += len(events)
		j.logger.Info("batch archived",
			"key",        key,
			"batch_size", len(events),
			"total",      totalMoved,
		)

		if len(events) < j.cfg.BatchSize {
			break
		}
	}

	j.logger.Info("tiering run complete", "total_moved", totalMoved)
	return nil
}

func toParquetRecords(events []postgres.WarmEvent) []coldstore.EventRecord {
	now := time.Now().UnixMilli()
	records := make([]coldstore.EventRecord, len(events))
	for i, e := range events {
		records[i] = coldstore.EventRecord{
			EventID:       e.EventID,
			EventType:     e.EventType,
			Source:        e.Source,
			SchemaVersion: e.SchemaVersion,
			TenantID:      e.TenantID,
			PartitionKey:  e.PartitionKey,
			ContentType:   e.ContentType,
			Payload:       e.Payload,
			PayloadBytes:  int32(e.PayloadBytes),
			TraceID:       e.TraceID,
			SpanID:        e.SpanID,
			OccurredAt:    e.OccurredAt.UnixMilli(),
			IngestedAt:    e.IngestedAt.UnixMilli(),
			ArchivedAt:    now,
		}
	}
	return records
}
