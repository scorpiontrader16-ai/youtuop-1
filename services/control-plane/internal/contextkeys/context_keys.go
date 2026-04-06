package contextkeys

// ╔══════════════════════════════════════════════════════════════════╗
// ║  services/control-plane/internal/contextkeys/context_keys.go   ║
// ║  Typed context keys (prevents key collisions)                   ║
// ╚══════════════════════════════════════════════════════════════════╝

// contextKey is an unexported type for context keys in this package.
// Using a typed key prevents collisions with other packages.
type contextKey string

const (
	// UserIDKey is the context key for the authenticated user ID.
	UserIDKey contextKey = "user_id"

	// TenantIDKey is the context key for the authenticated tenant ID.
	TenantIDKey contextKey = "tenant_id"
)
