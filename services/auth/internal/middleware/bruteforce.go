package middleware

import (
    "context"
    "net/http"
    "time"

    "github.com/scorpiontrader16-ai/youtuop-1/services/auth/internal/postgres"
)

type BruteForceProtection struct {
    db *postgres.Client
}

func NewBruteForceProtection(db *postgres.Client) *BruteForceProtection {
    return &BruteForceProtection{db: db}
}

// LoginLimit middleware (تستخدم داخل handler)
func (b *BruteForceProtection) LoginLimit(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // سيتم تنفيذ التحقق داخل handler نفسه بعد استخراج user ID
        next.ServeHTTP(w, r)
    })
}

// CheckAndRecord – تتحقق من العدد وتضيف محاولة فاشلة
func (b *BruteForceProtection) CheckAndRecord(ctx context.Context, userID, ip string) (bool, error) {
    count, err := b.db.CountFailedAttempts(ctx, userID, ip, 15*time.Minute)
    if err != nil {
        return false, err
    }
    if count >= 5 {
        return false, nil
    }
    if err := b.db.RecordFailedLogin(ctx, userID, ip); err != nil {
        return false, err
    }
    return true, nil
}

// IsBlocked – يتحقق فقط إذا كان المستخدم محجوبًا بدون تسجيل محاولة
// استخدم هذا قبل bcrypt — استخدم RecordFailure بعد فشل bcrypt فقط
func (b *BruteForceProtection) IsBlocked(ctx context.Context, userID, ip string) (bool, error) {
    count, err := b.db.CountFailedAttempts(ctx, userID, ip, 15*time.Minute)
    if err != nil {
        return false, err
    }
    return count >= 5, nil
}

// RecordFailure – يسجل محاولة فاشلة بعد التحقق من فشل bcrypt
func (b *BruteForceProtection) RecordFailure(ctx context.Context, userID, ip string) {
    _ = b.db.RecordFailedLogin(ctx, userID, ip)
}

// IsBlocked – يتحقق فقط إذا كان المستخدم محجوبًا بدون تسجيل محاولة
// استخدم هذا قبل bcrypt — استخدم RecordFailure بعد فشل bcrypt فقط
func (b *BruteForceProtection) IsBlocked(ctx context.Context, userID, ip string) (bool, error) {
    count, err := b.db.CountFailedAttempts(ctx, userID, ip, 15*time.Minute)
    if err != nil {
        return false, err
    }
    return count >= 5, nil
}

// RecordFailure – يسجل محاولة فاشلة بعد التحقق من فشل bcrypt
func (b *BruteForceProtection) RecordFailure(ctx context.Context, userID, ip string) {
    _ = b.db.RecordFailedLogin(ctx, userID, ip)
}
