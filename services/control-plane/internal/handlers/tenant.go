package handlers

import (
    "encoding/json"
    "net/http"
    "time"

    "github.com/gorilla/mux"
    "github.com/jackc/pgx/v5/pgxpool"
    "go.uber.org/zap"
)

type TenantHandler struct {
    db  *pgxpool.Pool
    log *zap.Logger
}

func NewTenantHandler(db *pgxpool.Pool, log *zap.Logger) *TenantHandler {
    return &TenantHandler{db: db, log: log}
}

type CreateTenantRequest struct {
    Name         string                 `json:"name"`
    Slug         string                 `json:"slug"`
    CustomDomain string                 `json:"custom_domain,omitempty"`
    Plan         string                 `json:"plan"` // basic, pro, business, enterprise
    Limits       map[string]interface{} `json:"limits,omitempty"`
}

func (h *TenantHandler) CreateTenant(w http.ResponseWriter, r *http.Request) {
    var req CreateTenantRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "invalid request", http.StatusBadRequest)
        return
    }

    // Validate slug uniqueness
    var exists bool
    err := h.db.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM tenants WHERE slug = $1)", req.Slug).Scan(&exists)
    if err != nil || exists {
        http.Error(w, "slug already exists", http.StatusConflict)
        return
    }

    // Default limits
    limits := req.Limits
    if limits == nil {
        limits = map[string]interface{}{
            "rate_limit": 1000,
            "storage_gb": 10,
            "max_users":  10,
        }
    }

    // Insert tenant
    var tenantID string
    err = h.db.QueryRow(r.Context(),
        `INSERT INTO tenants (slug, name, plan, custom_domain, limits, created_by, created_at, updated_at)
         VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW())
         RETURNING id`,
        req.Slug, req.Name, req.Plan, req.CustomDomain, limits, r.Context().Value("user_id").(string),
    ).Scan(&tenantID)
    if err != nil {
        h.log.Error("create tenant", zap.Error(err))
        http.Error(w, "failed to create tenant", http.StatusInternalServerError)
        return
    }

    // Log audit
    _, _ = h.db.Exec(r.Context(),
        `INSERT INTO tenant_audit_log (tenant_id, action, performed_by, details)
         VALUES ($1, 'create', $2, $3)`,
        tenantID, r.Context().Value("user_id").(string), req,
    )

    w.WriteHeader(http.StatusCreated)
    json.NewEncoder(w).Encode(map[string]string{"id": tenantID})
}

func (h *TenantHandler) ListTenants(w http.ResponseWriter, r *http.Request) {
    rows, err := h.db.Query(r.Context(),
        `SELECT id, slug, name, plan, custom_domain, status, limits, created_at, updated_at
         FROM tenants WHERE status != 'deleted' ORDER BY created_at DESC`)
    if err != nil {
        http.Error(w, "db error", http.StatusInternalServerError)
        return
    }
    defer rows.Close()

    var tenants []map[string]interface{}
    for rows.Next() {
        var id, slug, name, plan, customDomain, status string
        var limits []byte
        var createdAt, updatedAt time.Time
        if err := rows.Scan(&id, &slug, &name, &plan, &customDomain, &status, &limits, &createdAt, &updatedAt); err != nil {
            continue
        }
        tenants = append(tenants, map[string]interface{}{
            "id":            id,
            "slug":          slug,
            "name":          name,
            "plan":          plan,
            "custom_domain": customDomain,
            "status":        status,
            "limits":        limits,
            "created_at":    createdAt,
            "updated_at":    updatedAt,
        })
    }
    json.NewEncoder(w).Encode(tenants)
}

func (h *TenantHandler) SuspendTenant(w http.ResponseWriter, r *http.Request) {
    id := mux.Vars(r)["id"]
    _, err := h.db.Exec(r.Context(),
        `UPDATE tenants SET status = 'suspended', updated_at = NOW() WHERE id = $1`,
        id,
    )
    if err != nil {
        http.Error(w, "failed to suspend", http.StatusInternalServerError)
        return
    }
    // Log
    _, _ = h.db.Exec(r.Context(),
        `INSERT INTO tenant_audit_log (tenant_id, action, performed_by) VALUES ($1, 'suspend', $2)`,
        id, r.Context().Value("user_id").(string),
    )
    w.WriteHeader(http.StatusNoContent)
}

func (h *TenantHandler) DeleteTenant(w http.ResponseWriter, r *http.Request) {
    id := mux.Vars(r)["id"]
    // Soft delete
    _, err := h.db.Exec(r.Context(),
        `UPDATE tenants SET status = 'deleted', deleted_at = NOW(), updated_at = NOW() WHERE id = $1`,
        id,
    )
    if err != nil {
        http.Error(w, "failed to delete", http.StatusInternalServerError)
        return
    }
    _, _ = h.db.Exec(r.Context(),
        `INSERT INTO tenant_audit_log (tenant_id, action, performed_by) VALUES ($1, 'delete', $2)`,
        id, r.Context().Value("user_id").(string),
    )
    w.WriteHeader(http.StatusNoContent)
}

func (h *TenantHandler) UpdateConfig(w http.ResponseWriter, r *http.Request) {
    id := mux.Vars(r)["id"]
    var req struct {
        CustomDomain string                 `json:"custom_domain"`
        Branding     map[string]interface{} `json:"branding"`
        Limits       map[string]interface{} `json:"limits"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "invalid request", http.StatusBadRequest)
        return
    }
    _, err := h.db.Exec(r.Context(),
        `UPDATE tenants SET custom_domain = $1, branding = $2, limits = $3, updated_at = NOW() WHERE id = $4`,
        req.CustomDomain, req.Branding, req.Limits, id,
    )
    if err != nil {
        http.Error(w, "failed to update", http.StatusInternalServerError)
        return
    }
    _, _ = h.db.Exec(r.Context(),
        `INSERT INTO tenant_audit_log (tenant_id, action, performed_by, details) VALUES ($1, 'update_config', $2, $3)`,
        id, r.Context().Value("user_id").(string), req,
    )
    w.WriteHeader(http.StatusNoContent)
}
