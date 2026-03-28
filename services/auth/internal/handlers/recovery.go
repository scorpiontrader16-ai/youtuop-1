package handlers

import (
    "crypto/rand"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "net/http"
    "time"

    "go.uber.org/zap"
    "golang.org/x/crypto/bcrypt"

    "github.com/scorpiontrader16-ai/youtuop-1/services/auth/internal/postgres"
)

type Notifier interface {
    SendEmail(to, subject, body string) error
}

type RecoveryHandler struct {
    db       *postgres.Client
    notifier Notifier
    logger   *zap.Logger
}

func NewRecoveryHandler(db *postgres.Client, notifier Notifier, logger *zap.Logger) *RecoveryHandler {
    return &RecoveryHandler{db: db, notifier: notifier, logger: logger}
}

func (h *RecoveryHandler) RequestReset(w http.ResponseWriter, r *http.Request) {
    var req struct {
        Email string `json:"email"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "invalid request", http.StatusBadRequest)
        return
    }

    var userID, tenantID string
    err := h.db.DB().QueryRow(r.Context(),
        `SELECT id, tenant_id FROM users WHERE email = $1`,
        req.Email,
    ).Scan(&userID, &tenantID)
    if err != nil {
        w.WriteHeader(http.StatusAccepted)
        json.NewEncoder(w).Encode(map[string]string{"status": "if email exists, reset link sent"})
        return
    }

    tokenBytes := make([]byte, 32)
    if _, err := rand.Read(tokenBytes); err != nil {
        h.logger.Error("generate token", zap.Error(err))
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }
    token := hex.EncodeToString(tokenBytes)
    expiresAt := time.Now().Add(1 * time.Hour)

    if err := h.db.CreateRecoveryToken(r.Context(), userID, tenantID, token, expiresAt); err != nil {
        h.logger.Error("create recovery token", zap.Error(err))
        http.Error(w, "failed to create token", http.StatusInternalServerError)
        return
    }

    resetURL := fmt.Sprintf("https://app.platform.com/reset-password?token=%s", token)
    emailBody := fmt.Sprintf("Click here to reset your password: %s", resetURL)
    if h.notifier != nil {
        _ = h.notifier.SendEmail(req.Email, "Password Reset", emailBody)
    } else {
        h.logger.Info("recovery email would be sent",
            zap.String("to", req.Email),
            zap.String("url", resetURL),
        )
    }

    w.WriteHeader(http.StatusAccepted)
    json.NewEncoder(w).Encode(map[string]string{"status": "if email exists, reset link sent"})
}

func (h *RecoveryHandler) ResetPassword(w http.ResponseWriter, r *http.Request) {
    var req struct {
        Token       string `json:"token"`
        NewPassword string `json:"new_password"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "invalid request", http.StatusBadRequest)
        return
    }

    userID, tenantID, err := h.db.ValidateRecoveryToken(r.Context(), req.Token)
    if err != nil {
        http.Error(w, "invalid or expired token", http.StatusBadRequest)
        return
    }

    if err := ValidatePassword(req.NewPassword, DefaultPolicy); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }

    hashed, err := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
    if err != nil {
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }

    _, err = h.db.DB().Exec(r.Context(),
        `UPDATE users SET password_hash = $1, updated_at = NOW() WHERE id = $2`,
        hashed, userID,
    )
    if err != nil {
        http.Error(w, "failed to update password", http.StatusInternalServerError)
        return
    }

    h.db.AddPasswordHistory(r.Context(), userID, tenantID, string(hashed))
    h.db.MarkRecoveryTokenUsed(r.Context(), req.Token)
    h.db.RevokeAllSessions(r.Context(), userID, tenantID, "")

    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(map[string]string{"status": "password reset successful"})
}
