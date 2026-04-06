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
// F-ING22: يُسجّل warning عند غياب الملف بدلاً من التجاهل الصامت
func LoadVaultSecrets(path string) error {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		// F-ING22: log warning بدلاً من return nil صامت
		slog.Warn("vault secrets file not found - using env vars", "path", path)
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
			return fmt.Errorf("parse vault secret line %d: %w", lineNum, fmt.Errorf("invalid format %q (expected KEY=VALUE)", line))
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
