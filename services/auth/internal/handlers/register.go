package handlers

import (
    "encoding/json"
    "net/http"

    "github.com/scorpiontrader16-ai/youtuop-1/services/auth/internal/postgres"
    "go.uber.org/zap"
    "golang.org/x/crypto/bcrypt"
)

type RegisterHandler struct {
    db     *postgres.Client
    logger *zap.Logger
}

func NewRegisterHandler(db *postgres.Client, logger *zap.Logger) *RegisterHandler {
    return &RegisterHandler{db: db, logger: logger}
}

func (h *RegisterHandler) Register(w http.ResponseWriter, r *http.Request) {
    var req struct {
        Email      string `json:"email"`
        Password   string `json:"password"`
        FirstName  string `json:"first_name"`
        LastName   string `json:"last_name"`
        TenantSlug string `json:"tenant_slug"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "invalid request", http.StatusBadRequest)
        return
    }

    // 1. Validate password strength
    if err := ValidatePassword(req.Password, DefaultPolicy); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }

    // 2. Get tenant by slug
    tenant, err := h.db.GetTenantBySlug(r.Context(), req.TenantSlug)
    if err != nil {
        http.Error(w, "tenant not found", http.StatusForbidden)
        return
    }

    // 3. Check if user already exists
    existing, _ := h.db.GetUserByEmail(r.Context(), req.Email)
    if existing != nil {
        http.Error(w, "email already registered", http.StatusConflict)
        return
    }

    // 4. Hash password
    hashed, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
    if err != nil {
        h.logger.Error("hash password", zap.Error(err))
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }

    // 5. Insert user (global, no tenant_id)
    var userID string
    err = h.db.DB().QueryRow(r.Context(),
        `INSERT INTO users (email, password_hash, first_name, last_name, created_at, updated_at)
         VALUES ($1, $2, $3, $4, NOW(), NOW())
         RETURNING id`,
        req.Email, string(hashed), req.FirstName, req.LastName,
    ).Scan(&userID)
    if err != nil {
        h.logger.Error("create user", zap.Error(err))
        http.Error(w, "failed to create user", http.StatusInternalServerError)
        return
    }

    // 6. Assign default role for the tenant
    if err := h.db.AssignRole(r.Context(), userID, tenant.ID, "viewer"); err != nil {
        h.logger.Warn("assign default role", zap.Error(err))
        // non-critical, continue
    }

    w.WriteHeader(http.StatusCreated)
    json.NewEncoder(w).Encode(map[string]string{"user_id": userID, "status": "created"})
}
