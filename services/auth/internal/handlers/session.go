package handlers

import (
    "encoding/json"
    "net/http"

    "github.com/gorilla/mux"
    "go.uber.org/zap"

    "github.com/scorpiontrader16-ai/youtuop-1/services/auth/internal/postgres"
)

type SessionHandler struct {
    db     *postgres.Client
    logger *zap.Logger
}

func NewSessionHandler(db *postgres.Client, logger *zap.Logger) *SessionHandler {
    return &SessionHandler{db: db, logger: logger}
}

func (h *SessionHandler) List(w http.ResponseWriter, r *http.Request) {
    userID := r.Context().Value("user_id").(string)
    tenantID := r.Context().Value("tenant_id").(string)

    sessions, err := h.db.ListSessions(r.Context(), userID, tenantID)
    if err != nil {
        h.logger.Error("list sessions", zap.Error(err))
        http.Error(w, "database error", http.StatusInternalServerError)
        return
    }
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(sessions)
}

func (h *SessionHandler) Revoke(w http.ResponseWriter, r *http.Request) {
    userID := r.Context().Value("user_id").(string)
    tenantID := r.Context().Value("tenant_id").(string)
    sessionID := mux.Vars(r)["session_id"]

    if err := h.db.RevokeSession(r.Context(), sessionID, userID, tenantID); err != nil {
        http.Error(w, "failed to revoke", http.StatusInternalServerError)
        return
    }
    w.WriteHeader(http.StatusNoContent)
}

func (h *SessionHandler) RevokeAll(w http.ResponseWriter, r *http.Request) {
    userID := r.Context().Value("user_id").(string)
    tenantID := r.Context().Value("tenant_id").(string)
    currentSessionID := r.Context().Value("session_id").(string)

    if err := h.db.RevokeAllSessions(r.Context(), userID, tenantID, currentSessionID); err != nil {
        http.Error(w, "failed to revoke all", http.StatusInternalServerError)
        return
    }
    w.WriteHeader(http.StatusNoContent)
}
