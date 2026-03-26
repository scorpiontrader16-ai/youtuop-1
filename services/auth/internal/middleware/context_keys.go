package middleware

// ╔══════════════════════════════════════════════════════════════════╗
// ║  services/auth/internal/middleware/context_keys.go              ║
// ║  M8 – Typed context keys (prevents key collisions)              ║
// ╚══════════════════════════════════════════════════════════════════╝

// contextKey is an unexported type for context keys in this package.
// Using a typed key prevents collisions with other packages.
type contextKey string

const (
	// DeviceFingerprintKey is the context key for the device fingerprint.
	// Set by DeviceFingerprintMiddleware.
	DeviceFingerprintKey contextKey = "device_fingerprint"

	// TenantIDKey is the context key for the authenticated tenant ID.
	// Set by JWT validation middleware after token verification.
	TenantIDKey contextKey = "tenant_id"

	// UserIDKey is the context key for the authenticated user ID.
	// Set by JWT validation middleware after token verification.
	UserIDKey contextKey = "user_id"

	// SessionIDKey is the context key for the current session ID.
	SessionIDKey contextKey = "session_id"
)
