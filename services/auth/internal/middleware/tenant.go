package middleware

// ╔══════════════════════════════════════════════════════════════════╗
// ║  services/auth/internal/middleware/tenant.go                    ║
// ║  Extracts tenant_id from verified JWT claims only.              ║
// ║  Never trusts client-supplied headers — prevents tenant         ║
// ║  hijacking across multi-tenant financial data platform.         ║
// ╚══════════════════════════════════════════════════════════════════╝

import (
	"context"
	"net/http"
	"strings"

	appjwt "github.com/scorpiontrader16-ai/youtuop-1/services/auth/internal/jwt"
)

// TenantContextMiddleware validates the Bearer token and injects the
// verified tenant_id and user_id into the request context.
//
// Security: tenant_id is sourced exclusively from JWT claims (claim "tid").
// Any X-Tenant-ID header supplied by the client is ignored entirely.
// This prevents tenant hijacking in the multi-tenant platform.
//
// Usage:
//
//	mux.Handle("/v1/data", TenantContextMiddleware(jwtSvc)(myHandler))
func TenantContextMiddleware(jwtSvc *appjwt.Service) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			authHeader := r.Header.Get("Authorization")
			if !strings.HasPrefix(authHeader, "Bearer ") {
				http.Error(w, `{"error":"missing authorization"}`, http.StatusUnauthorized)
				return
			}

			claims, err := jwtSvc.Validate(strings.TrimPrefix(authHeader, "Bearer "))
			if err != nil {
				http.Error(w, `{"error":"invalid token"}`, http.StatusUnauthorized)
				return
			}

			if claims.TenantID == "" {
				http.Error(w, `{"error":"missing tenant claim"}`, http.StatusUnauthorized)
				return
			}

			// Inject verified identities into context — handlers must read
			// from context only, never from request headers directly.
			ctx := r.Context()
			ctx = context.WithValue(ctx, TenantIDKey, claims.TenantID)
			ctx = context.WithValue(ctx, UserIDKey, claims.UserID())
			ctx = context.WithValue(ctx, SessionIDKey, claims.SessionID)

			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}
