package handlers

import (
    "encoding/json"
    "fmt"
    "net/http"
    "time"

    "github.com/pquerna/otp/totp"
    "github.com/twilio/twilio-go"
    twilioApi "github.com/twilio/twilio-go/rest/api/v2010"
    "go.uber.org/zap"

    "github.com/scorpiontrader16-ai/youtuop-1/services/auth/internal/postgres"
)

type MFAHandler struct {
    db          *postgres.Client
    twilio      *twilio.RestClient
    smsFrom     string
    logger      *zap.Logger
}

func NewMFAHandler(db *postgres.Client, twilioClient *twilio.RestClient, smsFrom string, logger *zap.Logger) *MFAHandler {
    return &MFAHandler{db: db, twilio: twilioClient, smsFrom: smsFrom, logger: logger}
}

func (h *MFAHandler) GenerateTOTP(w http.ResponseWriter, r *http.Request) {
    userID := r.Context().Value("user_id").(string)
    tenantID := r.Context().Value("tenant_id").(string)

    key, err := totp.Generate(totp.GenerateOpts{
        Issuer:      "Platform",
        AccountName: userID,
    })
    if err != nil {
        http.Error(w, "failed to generate secret", http.StatusInternalServerError)
        return
    }

    if err := h.db.StoreMFASecret(r.Context(), userID, tenantID, key.Secret()); err != nil {
        h.logger.Error("store mfa secret", zap.Error(err))
        http.Error(w, "failed to store secret", http.StatusInternalServerError)
        return
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(map[string]string{
        "secret": key.Secret(),
        "url":    key.URL(),
    })
}

func (h *MFAHandler) VerifyTOTP(w http.ResponseWriter, r *http.Request) {
    userID := r.Context().Value("user_id").(string)
    tenantID := r.Context().Value("tenant_id").(string)

    var req struct {
        Code string `json:"code"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "invalid request", http.StatusBadRequest)
        return
    }

    secret, err := h.db.GetMFASecret(r.Context(), userID, tenantID)
    if err != nil || secret == "" {
        http.Error(w, "no secret found", http.StatusNotFound)
        return
    }

    if !totp.Validate(req.Code, secret) {
        http.Error(w, "invalid code", http.StatusUnauthorized)
        return
    }

    if err := h.db.EnableMFA(r.Context(), userID, tenantID); err != nil {
        h.logger.Error("enable mfa", zap.Error(err))
        http.Error(w, "failed to enable MFA", http.StatusInternalServerError)
        return
    }

    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(map[string]string{"status": "enabled"})
}

func (h *MFAHandler) DisableMFA(w http.ResponseWriter, r *http.Request) {
    userID := r.Context().Value("user_id").(string)
    tenantID := r.Context().Value("tenant_id").(string)

    if err := h.db.DisableMFA(r.Context(), userID, tenantID); err != nil {
        http.Error(w, "failed to disable MFA", http.StatusInternalServerError)
        return
    }
    w.WriteHeader(http.StatusNoContent)
}

func (h *MFAHandler) SendSMS(w http.ResponseWriter, r *http.Request) {
    userID := r.Context().Value("user_id").(string)
    tenantID := r.Context().Value("tenant_id").(string)

    var req struct {
        PhoneNumber string `json:"phone_number"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "invalid request", http.StatusBadRequest)
        return
    }

    code := fmt.Sprintf("%06d", time.Now().UnixNano()%1000000) // لاستخدام أفضل: crypto/rand
    expiresAt := time.Now().Add(10 * time.Minute)

    if err := h.db.StoreSMSAttempt(r.Context(), userID, tenantID, req.PhoneNumber, code, expiresAt); err != nil {
        h.logger.Error("store sms attempt", zap.Error(err))
        http.Error(w, "failed to record attempt", http.StatusInternalServerError)
        return
    }

    params := &twilioApi.CreateMessageParams{}
    params.SetTo(req.PhoneNumber)
    params.SetFrom(h.smsFrom)
    params.SetBody(fmt.Sprintf("Your verification code is: %s", code))

    _, err := h.twilio.Api.CreateMessage(params)
    if err != nil {
        h.logger.Error("twilio send", zap.Error(err))
        http.Error(w, "failed to send SMS", http.StatusInternalServerError)
        return
    }

    w.WriteHeader(http.StatusAccepted)
    json.NewEncoder(w).Encode(map[string]string{"status": "sent"})
}

func (h *MFAHandler) VerifySMS(w http.ResponseWriter, r *http.Request) {
    userID := r.Context().Value("user_id").(string)
    tenantID := r.Context().Value("tenant_id").(string)

    var req struct {
        PhoneNumber string `json:"phone_number"`
        Code        string `json:"code"`
    }
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "invalid request", http.StatusBadRequest)
        return
    }

    ok, err := h.db.VerifySMSAttempt(r.Context(), userID, tenantID, req.PhoneNumber, req.Code)
    if err != nil || !ok {
        http.Error(w, "invalid or expired code", http.StatusUnauthorized)
        return
    }

    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(map[string]string{"status": "verified"})
}
