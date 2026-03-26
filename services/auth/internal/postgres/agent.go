package postgres

// ╔══════════════════════════════════════════════════════════════════╗
// ║  services/auth/internal/postgres/agent.go                       ║
// ║  M8 – Agent Identity: DB methods                                ║
// ╚══════════════════════════════════════════════════════════════════╝

import (
	"context"
	"fmt"
	"time"
)

// ── Types ─────────────────────────────────────────────────────────────────

// Agent represents a registered AI agent identity
type Agent struct {
	ID             string
	TenantID       string
	Name           string
	AgentType      string
	ServiceAccount string
	Status         string
	CreatedBy      string
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// AgentPermission represents a single permission granted to an agent
type AgentPermission struct {
	AgentID    string
	Permission string
	GrantedAt  time.Time
	GrantedBy  string
}

// CreateAgentInput bundles all fields needed to create an agent
type CreateAgentInput struct {
	TenantID    string
	Name        string
	AgentType   string
	Permissions []string
	CreatedBy   string
}

// ── Methods ───────────────────────────────────────────────────────────────

// CreateAgent inserts a new agent and its permissions atomically
func (c *Client) CreateAgent(ctx context.Context, in CreateAgentInput) (*Agent, error) {
	tx, err := c.db.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var agent Agent
	err = tx.QueryRow(ctx,
		`INSERT INTO agents (tenant_id, name, agent_type, created_by)
		 VALUES ($1, $2, $3, $4)
		 RETURNING id, tenant_id, name, agent_type, COALESCE(service_account,''),
		           status, COALESCE(created_by,''), created_at, updated_at`,
		in.TenantID, in.Name, in.AgentType, in.CreatedBy,
	).Scan(
		&agent.ID, &agent.TenantID, &agent.Name, &agent.AgentType,
		&agent.ServiceAccount, &agent.Status, &agent.CreatedBy,
		&agent.CreatedAt, &agent.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("insert agent: %w", err)
	}

	for _, perm := range in.Permissions {
		if perm == "" {
			continue
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO agent_permissions (agent_id, permission, granted_by)
			 VALUES ($1, $2, $3)
			 ON CONFLICT (agent_id, permission) DO NOTHING`,
			agent.ID, perm, in.CreatedBy,
		); err != nil {
			return nil, fmt.Errorf("insert agent permission %q: %w", perm, err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit transaction: %w", err)
	}

	return &agent, nil
}

// GetAgentByID returns an agent by ID, verifying tenant ownership
func (c *Client) GetAgentByID(ctx context.Context, agentID, tenantID string) (*Agent, error) {
	var a Agent
	err := c.db.QueryRow(ctx,
		`SELECT id, tenant_id, name, agent_type, COALESCE(service_account,''),
		        status, COALESCE(created_by,''), created_at, updated_at
		 FROM agents WHERE id = $1 AND tenant_id = $2`,
		agentID, tenantID,
	).Scan(
		&a.ID, &a.TenantID, &a.Name, &a.AgentType,
		&a.ServiceAccount, &a.Status, &a.CreatedBy,
		&a.CreatedAt, &a.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("get agent: %w", err)
	}
	return &a, nil
}

// ListAgents returns all active agents for a tenant
func (c *Client) ListAgents(ctx context.Context, tenantID string) ([]Agent, error) {
	rows, err := c.db.Query(ctx,
		`SELECT id, tenant_id, name, agent_type, COALESCE(service_account,''),
		        status, COALESCE(created_by,''), created_at, updated_at
		 FROM agents WHERE tenant_id = $1
		 ORDER BY created_at DESC`,
		tenantID,
	)
	if err != nil {
		return nil, fmt.Errorf("list agents: %w", err)
	}
	defer rows.Close()

	var agents []Agent
	for rows.Next() {
		var a Agent
		if err := rows.Scan(
			&a.ID, &a.TenantID, &a.Name, &a.AgentType,
			&a.ServiceAccount, &a.Status, &a.CreatedBy,
			&a.CreatedAt, &a.UpdatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan agent: %w", err)
		}
		agents = append(agents, a)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate agents: %w", err)
	}
	return agents, nil
}

// GetAgentPermissions returns all permissions for an agent
func (c *Client) GetAgentPermissions(ctx context.Context, agentID string) ([]string, error) {
	rows, err := c.db.Query(ctx,
		`SELECT permission FROM agent_permissions WHERE agent_id = $1 ORDER BY permission`,
		agentID,
	)
	if err != nil {
		return nil, fmt.Errorf("get agent permissions: %w", err)
	}
	defer rows.Close()

	var perms []string
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, fmt.Errorf("scan permission: %w", err)
		}
		perms = append(perms, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate permissions: %w", err)
	}
	return perms, nil
}

// SuspendAgent soft-suspends an agent
func (c *Client) SuspendAgent(ctx context.Context, agentID, tenantID string) error {
	tag, err := c.db.Exec(ctx,
		`UPDATE agents SET status = 'suspended', updated_at = NOW()
		 WHERE id = $1 AND tenant_id = $2`,
		agentID, tenantID,
	)
	if err != nil {
		return fmt.Errorf("suspend agent: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("agent %q not found or not owned by tenant", agentID)
	}
	return nil
}
