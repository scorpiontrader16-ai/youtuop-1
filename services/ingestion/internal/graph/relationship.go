// ╔══════════════════════════════════════════════════════════════════╗
// ║  services/ingestion/internal/graph/relationship.go              ║
// ║  Status: 🆕 New  |  M10 – Graph Intelligence Data Model         ║
// ╚══════════════════════════════════════════════════════════════════╝

package graph

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/aminpola2001-ctrl/youtuop/services/ingestion/internal/postgres"
)

// Relationship represents a directed, weighted edge in the entity graph.
// ValidFrom/ValidTo model temporal validity — nil means unbounded.
type Relationship struct {
	TenantID   string                 `json:"tenant_id"`
	FromEntity string                 `json:"from_entity"`
	ToEntity   string                 `json:"to_entity"`
	Type       string                 `json:"relationship"`
	Weight     float64                `json:"weight"`
	Metadata   map[string]interface{} `json:"metadata,omitempty"`
	Source     string                 `json:"source,omitempty"`
	ValidFrom  *time.Time             `json:"valid_from,omitempty"`
	ValidTo    *time.Time             `json:"valid_to,omitempty"`
}

// Store persists entity graph relationships to PostgreSQL.
// It wraps *postgres.Client to stay consistent with service-wide DB access patterns.
type Store struct {
	pg     *postgres.Client
	logger *slog.Logger
}

// NewStore constructs a Store. logger defaults to slog.Default() if nil.
func NewStore(pg *postgres.Client, logger *slog.Logger) *Store {
	if logger == nil {
		logger = slog.Default()
	}
	return &Store{pg: pg, logger: logger}
}

// AddRelationship inserts a single directed edge into entity_relationships.
func (s *Store) AddRelationship(ctx context.Context, rel Relationship) error {
	if err := validateRelationship(rel); err != nil {
		return fmt.Errorf("graph: invalid relationship: %w", err)
	}

	metadataJSON, err := marshalMetadata(rel.Metadata)
	if err != nil {
		return fmt.Errorf("graph: marshal metadata (from=%s to=%s): %w",
			rel.FromEntity, rel.ToEntity, err)
	}

	_, err = s.pg.DB().ExecContext(ctx, `
		INSERT INTO entity_relationships
			(tenant_id, from_entity, to_entity, relationship,
			 weight, metadata, source, valid_from, valid_to)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		rel.TenantID,
		rel.FromEntity,
		rel.ToEntity,
		rel.Type,
		rel.Weight,
		metadataJSON,       // []byte → JSONB; nil → SQL NULL
		nullableString(rel.Source),
		rel.ValidFrom,      // *time.Time → TIMESTAMPTZ; nil → SQL NULL
		rel.ValidTo,
	)
	if err != nil {
		return fmt.Errorf("graph: insert relationship (from=%s to=%s type=%s): %w",
			rel.FromEntity, rel.ToEntity, rel.Type, err)
	}

	s.logger.Debug("graph relationship added",
		"tenant_id",    rel.TenantID,
		"from_entity",  rel.FromEntity,
		"to_entity",    rel.ToEntity,
		"relationship", rel.Type,
		"weight",       rel.Weight,
	)
	return nil
}

// AddRelationshipBatch inserts multiple directed edges in a single transaction.
// Each relationship is validated before the transaction begins.
// On any error the transaction is rolled back atomically.
func (s *Store) AddRelationshipBatch(ctx context.Context, rels []Relationship) (err error) {
	if len(rels) == 0 {
		return nil
	}

	// Validate all relationships before opening a transaction.
	for i, rel := range rels {
		if verr := validateRelationship(rel); verr != nil {
			return fmt.Errorf("graph: invalid relationship at index %d: %w", i, verr)
		}
	}

	tx, err := s.pg.DB().BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("graph: begin batch transaction: %w", err)
	}
	defer func() {
		// err is the named return — captures any error set after BeginTx.
		if err != nil {
			_ = tx.Rollback()
		}
	}()

	stmt, err := tx.PrepareContext(ctx, `
		INSERT INTO entity_relationships
			(tenant_id, from_entity, to_entity, relationship,
			 weight, metadata, source, valid_from, valid_to)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`)
	if err != nil {
		return fmt.Errorf("graph: prepare batch statement: %w", err)
	}
	defer stmt.Close()

	for i, rel := range rels {
		metadataJSON, merr := marshalMetadata(rel.Metadata)
		if merr != nil {
			return fmt.Errorf("graph: marshal metadata at index %d: %w", i, merr)
		}

		if _, err = stmt.ExecContext(ctx,
			rel.TenantID,
			rel.FromEntity,
			rel.ToEntity,
			rel.Type,
			rel.Weight,
			metadataJSON,
			nullableString(rel.Source),
			rel.ValidFrom,
			rel.ValidTo,
		); err != nil {
			return fmt.Errorf("graph: insert at index %d (from=%s to=%s type=%s): %w",
				i, rel.FromEntity, rel.ToEntity, rel.Type, err)
		}
	}

	if err = tx.Commit(); err != nil {
		return fmt.Errorf("graph: commit batch (count=%d): %w", len(rels), err)
	}

	s.logger.Info("graph relationships batch added", "count", len(rels))
	return nil
}

// ── Domain validation ─────────────────────────────────────────────────────

func validateRelationship(rel Relationship) error {
	if rel.TenantID == "" {
		return fmt.Errorf("tenant_id is required")
	}
	if rel.FromEntity == "" {
		return fmt.Errorf("from_entity is required")
	}
	if rel.ToEntity == "" {
		return fmt.Errorf("to_entity is required")
	}
	if rel.Type == "" {
		return fmt.Errorf("relationship type is required")
	}
	if rel.Weight <= 0 {
		return fmt.Errorf("weight must be positive, got %f", rel.Weight)
	}
	if rel.ValidFrom != nil && rel.ValidTo != nil && !rel.ValidTo.After(*rel.ValidFrom) {
		return fmt.Errorf("valid_to (%s) must be after valid_from (%s)",
			rel.ValidTo.Format(time.RFC3339), rel.ValidFrom.Format(time.RFC3339))
	}
	return nil
}

// ── Helpers ───────────────────────────────────────────────────────────────

// marshalMetadata returns nil (SQL NULL) when metadata is nil or empty,
// and JSON bytes otherwise. Avoids storing JSON "null" in the column.
func marshalMetadata(m map[string]interface{}) ([]byte, error) {
	if len(m) == 0 {
		return nil, nil
	}
	b, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	return b, nil
}

// nullableString converts an empty Go string to sql.NullString{Valid: false}
// so PostgreSQL stores NULL rather than an empty string in TEXT columns.
func nullableString(s string) sql.NullString {
	return sql.NullString{String: s, Valid: s != ""}
}
