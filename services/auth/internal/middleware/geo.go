// ╔══════════════════════════════════════════════════════════════════╗
// ║  Full path: services/auth/internal/middleware/geo.go            ║
// ║  Status: 🆕 New — M7 Data Sovereignty Stub                      ║
// ╚══════════════════════════════════════════════════════════════════╝

package middleware

import (
	"context"
	"net/http"
)

// geoKey — unexported struct key للـ context
// استخدام struct بدلاً من string يمنع أي تعارض مع packages أخرى
// لا تعارض مع contextKey string type الموجودة في context_keys.go
type geoKey struct{}

// GeoMiddleware يستخرج الـ region من X-Geo-Region header
// ويضعه في الـ context لاستخدامه في RBAC و data routing
//
// القيم المتوقعة:
//   - "us-east-1"     — US (default)
//   - "me-central-1"  — UAE
//   - "ap-southeast-3" — Bahrain
//   - "eu-west-1"     — Europe
//
// إذا كان الـ header فارغاً، القيمة الافتراضية هي "default"
func GeoMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		region := r.Header.Get("X-Geo-Region")
		if region == "" {
			region = "default"
		}
		ctx := context.WithValue(r.Context(), geoKey{}, region)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// GeoRegionFromContext يسترجع الـ region من الـ context
// يُستخدم في RBAC middleware و data sovereignty routing
func GeoRegionFromContext(ctx context.Context) string {
	v, ok := ctx.Value(geoKey{}).(string)
	if !ok || v == "" {
		return "default"
	}
	return v
}
