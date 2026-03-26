package handlers

// ╔══════════════════════════════════════════════════════════════════╗
// ║  services/auth/internal/handlers/agent.go                       ║
// ║  M8 – Agent Identity: HTTP handlers                             ║
// ╚══════════════════════════════════════════════════════════════════╝

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"go.uber.org/zap"

	"github.com/aminpola2001-ctrl/youtuop/services/auth/internal/middleware"
	"github.com/aminpola2001-ctrl/youtuop/services/auth/internal/postgres"
)

// ── Types ─────────────────────────────────────────────────────────────────

type AgentHandler struct {
	db     *postgres.Client
	logger *zap.Logger
}

func NewAgentHandler(db *postgres.Client, logger *zap.Logger) *AgentHandler {
	return &AgentHandler{db: db, logger: logger}
}

// createAgentRequest is the request body for POST /v1/auth/agents
type createAgentRequest struct {
	Name        string   `json:"name"`
	AgentType   string   `json:"agent_type"`
	Permissions []string `json:"permissions"`
}

func (r *createAgentRequest) validate() error {
	r.Name = strings.TrimSpace(r.Name)
	if r.Name == "" {
		return errors.New("name is required")
	}
	r.AgentType = strings.TrimSpace(r.AgentType)
	if r.AgentType == "" {
		return errors.New("agent_type is required")
	}
	validTypes := map[string]bool{
		"ml": true, "trading": true, "analytics": true,
		"notification": true, "custom": true,
	}
	if !validTypes[r.AgentType] {
		return errors.New("agent_type must be one of: ml, trading, analytics, notification, custom")
	}
	// Validate permission format: "resource:action"
	for _, p := range r.Permissions {
		parts := strings.Split(p, ":")
		if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
			return errors.New("permissions must follow 'resource:action' format")
		}
	}
	return nil
}

// ── Handlers ──────────────────────────────────────────────────────────────

// CreateAgent handles POST /v1/auth/agents
func (h *AgentHandler) CreateAgent(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Extract identity from context — set by JWT/tenant middleware
	tenantID, ok := ctx.Value(middleware.TenantIDKey).(string)
	if !ok || tenantID == "" {
		agentError(w, "missing tenant context", http.StatusUnauthorized)
		return
	}
	userID, ok := ctx.Value(middleware.UserIDKey).(string)
	if !ok || userID == "" {
		agentError(w, "missing user context", http.StatusUnauthorized)
		return
	}

	var req createAgentRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		agentError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if err := req.validate(); err != nil {
		agentError(w, err.Error(), http.StatusBadRequest)
		return
	}

	agent, err := h.db.CreateAgent(ctx, postgres.CreateAgentInput{
		TenantID:    tenantID,
		Name:        req.Name,
		AgentType:   req.AgentType,
		Permissions: req.Permissions,
		CreatedBy:   userID,
	})
	if err != nil {
		h.logger.Error("create agent failed",
			zap.String("tenant_id", tenantID),
			zap.String("user_id", userID),
			zap.Error(err),
		)
		agentError(w, "failed to create agent", http.StatusInternalServerError)
		return
	}

	h.logger.Info("agent created",
		zap.String("agent_id", agent.ID),
		zap.String("tenant_id", tenantID),
		zap.String("created_by", userID),
		zap.String("agent_type", agent.AgentType),
	)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]any{ //nolint:errcheck
		"agent_id":   agent.ID,
		"name":       agent.Name,
		"agent_type": agent.AgentType,
		"status":     agent.Status,
		"created_at": agent.CreatedAt,
	})
}

// ListAgents handles GET /v1/auth/agents
func (h *AgentHandler) ListAgents(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	tenantID, ok := ctx.Value(middleware.TenantIDKey).(string)
	if !ok || tenantID == "" {
		agentError(w, "missing tenant context", http.StatusUnauthorized)
		return
	}

	agents, err := h.db.ListAgents(ctx, tenantID)
	if err != nil {
		h.logger.Error("list agents failed",
			zap.String("tenant_id", tenantID),
			zap.Error(err),
		)
		agentError(w, "failed to list agents", http.StatusInternalServerError)
		return
	}

	type agentResponse struct {
		ID        string `json:"id"`
		Name      string `json:"name"`
		AgentType string `json:"agent_type"`
		Status    string `json:"status"`
		CreatedBy string `json:"created_by,omitempty"`
		CreatedAt string `json:"created_at"`
	}

	result := make([]agentResponse, 0, len(agents))
	for _, a := range agents {
		result = append(result, agentResponse{
			ID:        a.ID,
			Name:      a.Name,
			AgentType: a.AgentType,
			Status:    a.Status,
			CreatedBy: a.CreatedBy,
			CreatedAt: a.CreatedAt.Format("2006-01-02T15:04:05Z"),
		})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"agents": result, "count": len(result)}) //nolint:errcheck
}

// SuspendAgent handles DELETE /v1/auth/agents/{agent_id}
func (h *AgentHandler) SuspendAgent(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	tenantID, ok := ctx.Value(middleware.TenantIDKey).(string)
	if !ok || tenantID == "" {
		agentError(w, "missing tenant context", http.StatusUnauthorized)
		return
	}

	agentID := r.PathValue("agent_id")
	if agentID == "" {
		agentError(w, "agent_id is required", http.StatusBadRequest)
		return
	}

	if err := h.db.SuspendAgent(ctx, agentID, tenantID); err != nil {
		h.logger.Warn("suspend agent failed",
			zap.String("agent_id", agentID),
			zap.String("tenant_id", tenantID),
			zap.Error(err),
		)
		agentError(w, "agent not found or already suspended", http.StatusNotFound)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// ── helpers ───────────────────────────────────────────────────────────────

func agentError(w http.ResponseWriter, msg string, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": msg}) //nolint:errcheck
}
