package schemaregistry

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"time"
)

// Registrar يسجل كل الـ schemas تلقائياً عند الـ startup
type Registrar struct {
	client *Client
	logger *slog.Logger
}

// NewRegistrar ينشئ registrar جديد
func NewRegistrar(registryURL string, logger *slog.Logger) *Registrar {
	if logger == nil {
		logger = slog.Default()
	}
	return &Registrar{
		client: New(registryURL),
		logger: logger,
	}
}

// WaitForRegistry ينتظر الـ Schema Registry يكون ready
// يرجع error لو انتهى الـ context قبل ما يكون ready
func (r *Registrar) WaitForRegistry(ctx context.Context) error {
	r.logger.Info("waiting for schema registry...")
	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("context cancelled while waiting for schema registry: %w", ctx.Err())
		default:
			_, err := r.client.ListSubjects(ctx)
			if err == nil {
				r.logger.Info("schema registry is ready")
				return nil
			}
			r.logger.Warn("schema registry not ready, retrying in 2s", "error", err)
			time.Sleep(2 * time.Second)
		}
	}
}

// RegisterAll يسجل كل الـ .proto files في الـ directory ومحتوياتها
// FIX: يستخدم filepath.Walk بدل filepath.Glob لأن Go لا يدعم ** في Glob
func (r *Registrar) RegisterAll(ctx context.Context, protoDir string) error {
	var files []string

	err := filepath.Walk(protoDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return fmt.Errorf("walk error at %s: %w", path, err)
		}
		if !info.IsDir() && filepath.Ext(path) == ".proto" {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("walk proto dir %q: %w", protoDir, err)
	}

	if len(files) == 0 {
		return fmt.Errorf("no .proto files found in %q", protoDir)
	}

	for _, f := range files {
		if err := r.registerFile(ctx, f); err != nil {
			return fmt.Errorf("register %s: %w", f, err)
		}
	}

	r.logger.Info("all schemas registered", "count", len(files))
	return nil
}

// registerFile يسجل ملف proto واحد
func (r *Registrar) registerFile(ctx context.Context, path string) error {
	content, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read file: %w", err)
	}

	// subject name = اسم الملف بدون extension
	subject := filepath.Base(path[:len(path)-len(filepath.Ext(path))])

	// اتحقق لو الـ subject موجود بالفعل — لازم يكون compatible
	existingSubjects, err := r.client.ListSubjects(ctx)
	if err != nil {
		return fmt.Errorf("list subjects: %w", err)
	}

	for _, s := range existingSubjects {
		if s == subject {
			ok, err := r.client.CheckCompatibility(ctx, subject, string(content))
			if err != nil {
				// لو فشل الـ check، نحذّر بس منوقفش الـ registration
				r.logger.Warn("compatibility check failed, proceeding anyway",
					"subject", subject, "error", err)
				break
			}
			if !ok {
				return fmt.Errorf("schema %q is NOT backward-compatible with existing version — aborting", subject)
			}
		}
	}

	// اضبط BACKWARD compatibility قبل التسجيل
	if err := r.client.SetCompatibility(ctx, subject, CompatBackward); err != nil {
		// غير fatal — الـ global config قد يكون كافي
		r.logger.Warn("could not set subject compatibility", "subject", subject, "error", err)
	}

	id, err := r.client.RegisterSchema(ctx, subject, string(content))
	if err != nil {
		return fmt.Errorf("register schema: %w", err)
	}

	r.logger.Info("schema registered", "subject", subject, "schema_id", id, "file", path)
	return nil
}
