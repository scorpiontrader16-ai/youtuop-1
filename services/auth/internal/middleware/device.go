package middleware

import (
    "context"
    "crypto/sha256"
    "encoding/hex"
    "net/http"
    "strings"
)

type contextKey string

const DeviceFingerprintKey contextKey = "device_fingerprint"

func DeviceFingerprintMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        ua := r.UserAgent()
        ip := r.Header.Get("X-Forwarded-For")
        if ip == "" {
            ip = r.RemoteAddr
        }
        acceptLang := r.Header.Get("Accept-Language")
        fingerprintData := strings.Join([]string{ua, ip, acceptLang}, "|")
        hash := sha256.Sum256([]byte(fingerprintData))
        fingerprint := hex.EncodeToString(hash[:])

        ctx := context.WithValue(r.Context(), DeviceFingerprintKey, fingerprint)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}
