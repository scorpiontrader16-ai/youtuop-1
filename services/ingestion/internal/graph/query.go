// ╔══════════════════════════════════════════════════════════════════╗
// ║  services/ingestion/internal/graph/query.go                     ║
// ║  Status: 🆕 New  |  M10 – Graph Intelligence Data Model         ║
// ╚══════════════════════════════════════════════════════════════════╝

package graph

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// RelationshipRow is a read model returned by query operations.
// Intentionally separate from Relationship (write model) to prevent
// callers from accidentally mutating what was read from the database.
type RelationshipRow struct {
	ID         string
	TenantID   string
	FromEntity string
	ToEntity   string
	Type       string
	Weight     float64
	Source     string
	ValidFrom  *time.Time
	ValidTo    *time.Time
	CreatedAt  time.Time
}

// GetOutbound returns all directed edges where from_entity matches.
// Scoped to tenant, ordered by weight descending.
func (s *Store) GetOutbound(ctx context.Context, tenantID, fromEntity string) ([]RelationshipRow, error) {
	if tenantID == "" {
		return nil, fmt.Errorf("graph: GetOutbound: tenant_id is required")
	}
	if fromEntity == "" {
		return nil, fmt.Errorf("graph: GetOutbound: from_entity is required")
	}

	rows, err := s.pg.DB().QueryContext(ctx, `
		SELECT id, tenant_id, from_entity, to_entity, relationship,
		       weight, COALESCE(source, ''), valid_from, valid_to, created_at
		FROM   entity_relationships
		WHERE  tenant_id   = $1
		AND    from_entity = $2
		ORDER  BY weight DESC`,
		tenantID, fromEntity,
	)
	if err != nil {
		return nil, fmt.Errorf("graph: GetOutbound (tenant=%s from=%s): %w",
			tenantID, fromEntity, err)
	}
	defer rows.Close()

	return scanRows(rows)
}

// GetInbound returns all directed edges where to_entity matches.
// Scoped to tenant, ordered by weight descending.
func (s *Store) GetInbound(ctx context.Context, tenantID, toEntity string) ([]RelationshipRow, error) {
	if tenantID == "" {
		return nil, fmt.Errorf("graph: GetInbound: tenant_id is required")
	}
	if toEntity == "" {
		return nil, fmt.Errorf("graph: GetInbound: to_entity is required")
	}

	rows, err := s.pg.DB().QueryContext(ctx, `
		SELECT id, tenant_id, from_entity, to_entity, relationship,
		       weight, COALESCE(source, ''), valid_from, valid_to, created_at
		FROM   entity_relationships
		WHERE  tenant_id = $1
		AND    to_entity = $2
		ORDER  BY weight DESC`,
		tenantID, toEntity,
	)
	if err != nil {
		return nil, fmt.Errorf("graph: GetInbound (tenant=%s to=%s): %w",
			tenantID, toEntity, err)
	}
	defer rows.Close()

	return scanRows(rows)
}

// GetNeighbors returns all edges connected to the given entity in either direction.
// Primary graph traversal operation used by AI agents (M19).
func (s *Store) GetNeighbors(ctx context.Context, tenantID, entityID string) ([]RelationshipRow, error) {
	if tenantID == "" {
		return nil, fmt.Errorf("graph: GetNeighbors: tenant_id is required")
	}
	if entityID == "" {
		return nil, fmt.Errorf("graph: GetNeighbors: entity_id is required")
	}

	rows, err := s.pg.DB().QueryContext(ctx, `
		SELECT id, tenant_id, from_entity, to_entity, relationship,
		       weight, COALESCE(source, ''), valid_from, valid_to, created_at
		FROM   entity_relationships
		WHERE  tenant_id = $1
		AND    (from_entity = $2 OR to_entity = $2)
		ORDER  BY weight DESC`,
		tenantID, entityID,
	)
	if err != nil {
		return nil, fmt.Errorf("graph: GetNeighbors (tenant=%s entity=%s): %w",
			tenantID, entityID, err)
	}
	defer rows.Close()

	return scanRows(rows)
}

// GetByType returns all edges of a specific relationship type within a tenant.
// Used for bulk traversal — e.g. "all MEMBER_OF edges for SP500 index".
func (s *Store) GetByType(ctx context.Context, tenantID, relType string) ([]RelationshipRow, error) {
	if tenantID == "" {
		return nil, fmt.Errorf("graph: GetByType: tenant_id is required")
	}
	if relType == "" {
		return nil, fmt.Errorf("graph: GetByType: relationship type is required")
	}

	rows, err := s.pg.DB().QueryContext(ctx, `
		SELECT id, tenant_id, from_entity, to_entity, relationship,
		       weight, COALESCE(source, ''), valid_from, valid_to, created_at
		FROM   entity_relationships
		WHERE  tenant_id    = $1
		AND    relationship = $2
		ORDER  BY weight DESC`,
		tenantID, relType,
	)
	if err != nil {
		return nil, fmt.Errorf("graph: GetByType (tenant=%s type=%s): %w",
			tenantID, relType, err)
	}
	defer rows.Close()

	return scanRows(rows)
}

// GetActive returns all edges temporally active at the given point in time.
// An edge is active when: (valid_from IS NULL OR valid_from <= at)
//
//	AND (valid_to IS NULL OR valid_to > at)
//
// Used by M19 AI agents to query the graph state at a specific moment.
func (s *Store) GetActive(ctx context.Context, tenantID string, at time.Time) ([]RelationshipRow, error) {
	if tenantID == "" {
		return nil, fmt.Errorf("graph: GetActive: tenant_id is required")
	}
	if at.IsZero() {
		return nil, fmt.Errorf("graph: GetActive: at timestamp must not be zero")
	}

	rows, err := s.pg.DB().QueryContext(ctx, `
		SELECT id, tenant_id, from_entity, to_entity, relationship,
		       weight, COALESCE(source, ''), valid_from, valid_to, created_at
		FROM   entity_relationships
		WHERE  tenant_id  = $1
		AND    (valid_from IS NULL OR valid_from <= $2)
		AND    (valid_to   IS NULL OR valid_to   >  $2)
		ORDER  BY weight DESC`,
		tenantID, at,
	)
	if err != nil {
		return nil, fmt.Errorf("graph: GetActive (tenant=%s at=%s): %w",
			tenantID, at.Format(time.RFC3339), err)
	}
	defer rows.Close()

	return scanRows(rows)
}

// ─── internal scanner ─────────────────────────────────────────────────────────

// scanRows maps *sql.Rows into []RelationshipRow.
// Centralised to avoid duplication across all query functions.
// Column order must match every SELECT in this file:
//
//	id, tenant_id, from_entity, to_entity, relationship,
//	weight, COALESCE(source,''), valid_from, valid_to, created_at
func scanRows(rows *sql.Rows) ([]RelationshipRow, error) {
	var result []RelationshipRow

	for rows.Next() {
		var r RelationshipRow
		if err := rows.Scan(
			&r.ID,
			&r.TenantID,
			&r.FromEntity,
			&r.ToEntity,
			&r.Type,
			&r.Weight,
			&r.Source,
			&r.ValidFrom,
			&r.ValidTo,
			&r.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("graph: scan relationship row: %w", err)
		}
		result = append(result, r)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("graph: rows iteration error: %w", err)
	}

	return result, nil
}
