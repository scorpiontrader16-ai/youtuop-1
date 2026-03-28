package middleware

import (
    "net/http"

    "github.com/scorpiontrader16-ai/youtuop-1/services/auth/internal/postgres"
)

// TenantContextMiddleware sets PostgreSQL session variable app.tenant_id
// based on the X-Tenant-ID header.
func TenantContextMiddleware(db *postgres.Client) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            tenantID := r.Header.Get("X-Tenant-ID")
            if tenantID != "" {
                // Execute set_config in PostgreSQL
                _, err := db.DB().Exec(r.Context(), "SELECT set_config('app.tenant_id', $1, false)", tenantID)
                if err != nil {
                    // Log error but continue
                    // slog is not available here; use a global logger if needed
                }
            }
            next.ServeHTTP(w, r)
        })
    }
}
