package handlers

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"go.uber.org/zap"

	"github.com/scorpiontrader16-ai/youtuop-1/services/auth/internal/postgres"
)

type APIKeyHandler struct {
	db     *postgres.Client
	logger *zap.Logger
}

func NewAPIKeyHandler(db *postgres.Client, logger *zap.Logger) *APIKeyHandler {
	return &APIKeyHandler{db: db, logger: logger}
}

func (h *APIKeyHandler) Create(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value("user_id").(string)
	tenantID := r.Context().Value("tenant_id").(string)

	var req struct {
		Name        string   `json:"name"`
		Permissions []string `json:"permissions"`
		ExpiresIn   int      `json:"expires_in_days"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}

	keyBytes := make([]byte, 32)
	if _, err := rand.Read(keyBytes); err != nil {
		http.Error(w, "failed to generate key", http.StatusInternalServerError)
		return
	}
	key := "pk_" + hex.EncodeToString(keyBytes)

	var expiresAt *time.Time
	if req.ExpiresIn > 0 {
		t := time.Now().Add(time.Duration(req.ExpiresIn) * 24 * time.Hour)
		expiresAt = &t
	}

	// Store the SHA-256 hash of the key — never the raw key.
	// The raw key is returned to the caller once; it cannot be recovered later.
	if err := h.db.CreateAPIKey(r.Context(), tenantID, userID, req.Name, postgres.HashToken(key), req.Permissions, expiresAt); err != nil {
		h.logger.Error("create api key", zap.Error(err))
		http.Error(w, "failed to create key", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"api_key": key})
}

func (h *APIKeyHandler) List(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value("user_id").(string)
	tenantID := r.Context().Value("tenant_id").(string)

	keys, err := h.db.ListAPIKeys(r.Context(), userID, tenantID)
	if err != nil {
		h.logger.Error("list api keys", zap.Error(err))
		http.Error(w, "database error", http.StatusInternalServerError)
		return
	}
	json.NewEncoder(w).Encode(keys)
}

func (h *APIKeyHandler) Revoke(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value("user_id").(string)
	tenantID := r.Context().Value("tenant_id").(string)

	// ── Use r.PathValue for Go 1.22 stdlib routing (not gorilla/mux) ──────
	keyIDStr := r.PathValue("key_id")
	keyID, err := strconv.ParseInt(keyIDStr, 10, 64)
	if err != nil {
		http.Error(w, "invalid key id", http.StatusBadRequest)
		return
	}

	if err := h.db.RevokeAPIKey(r.Context(), keyID, userID, tenantID); err != nil {
		http.Error(w, "failed to revoke", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ── FIX #3: Add VerifyInternal — internal endpoint to validate API keys ──
// Called by other internal services without auth middleware.
// Reads the key from the X-API-Key header, validates it, and returns
// the associated user_id, tenant_id, and permissions as JSON.
func (h *APIKeyHandler) VerifyInternal(w http.ResponseWriter, r *http.Request) {
	key := r.Header.Get("X-API-Key")
	if key == "" {
		h.logger.Warn("VerifyInternal called without X-API-Key header")
		http.Error(w, "missing api key", http.StatusUnauthorized)
		return
	}

	keyHash := postgres.HashToken(key)
	userID, tenantID, permissions, err := h.db.ValidateAPIKey(r.Context(), keyHash)
	if err != nil {
		h.logger.Warn("api key validation failed", zap.Error(err))
		http.Error(w, "invalid or expired api key", http.StatusUnauthorized)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"user_id":     userID,
		"tenant_id":   tenantID,
		"permissions": permissions,
	})
}
