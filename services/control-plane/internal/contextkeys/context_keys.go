package contextkeys

// ╔══════════════════════════════════════════════════════════════════╗
// ║  services/control-plane/internal/contextkeys/context_keys.go   ║
// ║  F-AUTH62 — Delegates to shared platform contextkeys package    ║
// ║                                                                  ║
// ║  لماذا delegation بدلاً من تعريف محلي:                         ║
// ║  - يضمن أن كل service تستخدم نفس key type بالضبط               ║
// ║  - type collision مستحيل — struct type فريد في Go type system   ║
// ║  - الأسماء المحلية محفوظة — لا تغيير على الـ handlers           ║
// ╚══════════════════════════════════════════════════════════════════╝

import (
	"github.com/scorpiontrader16-ai/youtuop-1/internal/platform/contextkeys"
)

// الأسماء المحلية تفوِّض للـ shared package — handlers لا تحتاج تغيير
var (
	// UserIDKey هو مفتاح الـ context للمستخدم المُحقَّق منه.
	UserIDKey = contextkeys.UserIDKey

	// TenantIDKey هو مفتاح الـ context للـ tenant المُحقَّق منه.
	TenantIDKey = contextkeys.TenantIDKey
)
