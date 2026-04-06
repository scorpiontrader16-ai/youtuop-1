package contextkeys

// ╔══════════════════════════════════════════════════════════════════╗
// ║  internal/platform/contextkeys/context_keys.go                  ║
// ║  F-AUTH62 — Typed struct context keys (shared platform package) ║
// ║                                                                  ║
// ║  لماذا struct{} بدلاً من string:                                ║
// ║  - string keys تتصادم عند تساوي القيمة بين packages مختلفة     ║
// ║  - كل struct type فريد في Go's type system حتى لو فارغ          ║
// ║  - zero-size → zero allocation على الـ heap                     ║
// ╚══════════════════════════════════════════════════════════════════╝

// كل key له نوع struct منفصل — يمنع التصادم حتى بين packages
// تطابق النمط المستخدم في geo.go و ingestion/main.go في نفس المشروع

type userIDKey            struct{}
type tenantIDKey          struct{}
type sessionIDKey         struct{}
type deviceFingerprintKey struct{}

// المتغيرات المصدَّرة — القيمة الوحيدة المقبولة لكل key
var (
	// UserIDKey هو مفتاح الـ context للمستخدم المُحقَّق منه.
	// يُضبط بواسطة TenantContextMiddleware بعد التحقق من الـ JWT.
	UserIDKey userIDKey

	// TenantIDKey هو مفتاح الـ context للـ tenant المُحقَّق منه.
	// يُضبط بواسطة TenantContextMiddleware بعد التحقق من الـ JWT.
	TenantIDKey tenantIDKey

	// SessionIDKey هو مفتاح الـ context للـ session الحالية.
	// يُضبط بواسطة TenantContextMiddleware بعد التحقق من الـ JWT.
	SessionIDKey sessionIDKey

	// DeviceFingerprintKey هو مفتاح الـ context لبصمة الجهاز.
	// يُضبط بواسطة DeviceFingerprintMiddleware.
	DeviceFingerprintKey deviceFingerprintKey
)
