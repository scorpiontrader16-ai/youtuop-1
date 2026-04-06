// services/ingestion/internal/config/vault.go
//
// لماذا هذا الملف:
//   Vault Agent يكتب credentials في /vault/secrets/db بصيغة KEY="VALUE"
//   نقرأها ونحمّلها كـ env vars قبل postgres.ConfigFromEnv()
//   هذا يتيح dynamic credential rotation بدون تعديل باقي الكود

package config

import (
	"bufio"
	"fmt"
	"log/slog"
	"os"
	"strings"
)

const DefaultVaultSecretsPath = "/vault/secrets/db"

// LoadVaultSecrets يقرأ ملف secrets المكتوب بواسطة Vault Agent
// ويحمّل القيم كـ env vars — يتغلب على أي قيمة موجودة مسبقاً
//
// F-ING22: سلوك غياب الملف يختلف حسب APP_ENV:
//   - production | prod → return error (Vault Agent يجب أن يكون حقَّن الـ secrets)
//   - dev | staging | test | "" → log warning فقط، fallback لـ static env vars
func LoadVaultSecrets(path string) error {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		appEnv := strings.ToLower(os.Getenv("APP_ENV"))
		if appEnv == "production" || appEnv == "prod" {
			// F-ING22: في production غياب الملف = Vault Agent لم يُحقَّن — خطأ حقيقي يوقف الـ startup
			return fmt.Errorf(
				"vault secrets file missing in production (path=%s): Vault Agent may not have injected credentials — check Vault connectivity and annotations",
				path,
			)
		}
		// F-ING22: في dev/staging — warning فقط، يكمل بـ static env vars
		slog.Warn("vault secrets file not found — using static env vars (non-production)",
			"path", path,
			"APP_ENV", appEnv,
		)
		return nil
	}

	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open vault secrets file %s: %w", path, err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	lineNum := 0
	for scanner.Scan() {
		lineNum++
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			// F-ING13: return parse error بدلاً من continue صامت
			return fmt.Errorf("parse vault secret line %d: %w", lineNum,
				fmt.Errorf("invalid format %q (expected KEY=VALUE)", line))
		}

		key := strings.TrimSpace(parts[0])
		// إزالة الـ quotes: "value" → value
		value := strings.Trim(strings.TrimSpace(parts[1]), `"`)

		if err := os.Setenv(key, value); err != nil {
			return fmt.Errorf("setenv %s: %w", key, err)
		}
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("scan vault secrets file: %w", err)
	}

	return nil
}
