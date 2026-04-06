// internal/platform/profiling/profiling.go
//
// Shared Pyroscope profiling initializer — used by ALL Go services.
//
// Why shared: 13 services had identical copies differing only in
// ApplicationName. Centralising here means:
//   - Bug fixes apply to all services simultaneously
//   - Profile type list is consistent across the fleet
//   - F-ING08: explicit warning when PYROSCOPE_SERVER_URL is missing
//
// Usage in each service main.go:
//   profiling.Init(logger, "platform.auth")
//
// Migration: replace per-service internal/profiling/profiling.go
// with import from this shared package via go.mod replace directive.
package profiling

import (
	"log/slog"
	"os"

	"github.com/grafana/pyroscope-go"
)

// Init starts the Pyroscope continuous profiler for the given service.
//
// appName should follow the convention "platform.<service>" e.g.
// "platform.auth", "platform.ingestion", "platform.billing".
//
// Behaviour:
//   - If PYROSCOPE_SERVER_URL is unset: logs a Warning (F-ING08 fix)
//     and returns — profiling is disabled but service starts normally.
//   - If pyroscope.Start fails: logs a Warning and returns — service
//     continues without profiling rather than crashing.
//   - On success: logs Info with server URL and app name.
//
// Tags collected per profile:
//   - pod:       POD_NAME env var (Kubernetes downward API)
//   - namespace: POD_NAMESPACE env var (Kubernetes downward API)
//   - version:   VERSION env var (injected at build time)
func Init(logger *slog.Logger, appName string) {
	serverURL := os.Getenv("PYROSCOPE_SERVER_URL")
	if serverURL == "" {
		// F-ING08: explicit warning (not silent Info) when profiling
		// is not configured. Operators should know profiling is off.
		logger.Warn("pyroscope profiling disabled — PYROSCOPE_SERVER_URL not set",
			"app", appName,
			"action", "set PYROSCOPE_SERVER_URL to enable continuous profiling",
		)
		return
	}

	_, err := pyroscope.Start(pyroscope.Config{
		ApplicationName: appName,
		ServerAddress:   serverURL,
		ProfileTypes: []pyroscope.ProfileType{
			pyroscope.ProfileCPU,
			pyroscope.ProfileAllocObjects,
			pyroscope.ProfileAllocSpace,
			pyroscope.ProfileInuseObjects,
			pyroscope.ProfileInuseSpace,
			pyroscope.ProfileGoroutines,
		},
		Tags: map[string]string{
			"pod":       os.Getenv("POD_NAME"),
			"namespace": os.Getenv("POD_NAMESPACE"),
			"version":   os.Getenv("VERSION"),
		},
	})
	if err != nil {
		logger.Warn("pyroscope failed to start — profiling disabled",
			"app", appName,
			"server", serverURL,
			"error", err,
		)
		return
	}

	logger.Info("pyroscope continuous profiling started",
		"app", appName,
		"server", serverURL,
	)
}
