// services/ingestion/internal/profiling/profiling.go
//
// لماذا: Continuous profiling يكشف CPU hotspots وmemory leaks في production
// بدونه لا نعرف أين تضيع الـ microseconds في كل request
// Pyroscope يرسل profiles كل 10s لـ pyroscope server في monitoring namespace

package profiling

import (
	"log/slog"
	"os"

	"github.com/grafana/pyroscope-go"
)

// Init يبدأ الـ Pyroscope profiler — يُستدعى مرة واحدة عند startup
// إذا PYROSCOPE_SERVER_URL فارغ يتجاهل بصمت (local dev بدون pyroscope)
func Init(logger *slog.Logger) {
	serverURL := os.Getenv("PYROSCOPE_SERVER_URL")
	if serverURL == "" {
		logger.Info("pyroscope disabled — PYROSCOPE_SERVER_URL not set")
		return
	}

	_, err := pyroscope.Start(pyroscope.Config{
		ApplicationName: "platform.ingestion",
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
		logger.Warn("pyroscope failed to start", "error", err)
		return
	}

	logger.Info("pyroscope profiling started",
		"server", serverURL,
		"app", "platform.ingestion",
	)
}
