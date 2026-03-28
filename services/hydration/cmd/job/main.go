// services/hydration/cmd/job/main.go
// Cold Start Hydration Service
// يبعت warm-up requests للـ Rust Processing Engine عشان يتجنب cold start latency
// بيشتغل كـ Job في Kubernetes قبل ما يبدأ الـ Rollout traffic
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/protobuf/types/known/timestamppb"

	eventsv1    "github.com/scorpiontrader16-ai/youtuop-1/gen/events/v1"
	processingv1 "github.com/scorpiontrader16-ai/youtuop-1/gen/processing/v1"
)

type Config struct {
	ProcessingAddr  string
	WarmupRequests  int
	WarmupTimeout   time.Duration
	ReadyTimeout    time.Duration
	ConcurrentCalls int
}

func configFromEnv() Config {
	return Config{
		ProcessingAddr:  getEnv("PROCESSING_ADDR", "processing:50051"),
		WarmupRequests:  getEnvInt("WARMUP_REQUESTS", 50),
		WarmupTimeout:   time.Duration(getEnvInt("WARMUP_TIMEOUT_SEC", 30)) * time.Second,
		ReadyTimeout:    time.Duration(getEnvInt("READY_TIMEOUT_SEC", 60)) * time.Second,
		ConcurrentCalls: getEnvInt("CONCURRENT_CALLS", 5),
	}
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	cfg := configFromEnv()

	logger.Info("hydration service starting",
		"processing_addr",   cfg.ProcessingAddr,
		"warmup_requests",   cfg.WarmupRequests,
		"concurrent_calls",  cfg.ConcurrentCalls,
	)

	// ── اتصل بالـ Processing Engine ────────────────────────────────────
	conn, err := grpc.NewClient(
		cfg.ProcessingAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		logger.Error("failed to create grpc connection", "error", err)
		os.Exit(1)
	}
	defer conn.Close()

	ctx := context.Background()

	// ── انتظر الـ service يكون ready ────────────────────────────────────
	if err := waitForReady(ctx, conn, cfg.ReadyTimeout, logger); err != nil {
		logger.Error("processing service not ready", "error", err)
		os.Exit(1)
	}

	// ── شغّل الـ warmup requests ─────────────────────────────────────────
	client := processingv1.NewProcessingEngineServiceClient(conn)

	warmupCtx, cancel := context.WithTimeout(ctx, cfg.WarmupTimeout)
	defer cancel()

	if err := runWarmup(warmupCtx, client, cfg, logger); err != nil {
		logger.Error("warmup failed", "error", err)
		os.Exit(1)
	}

	logger.Info("hydration complete — processing engine is warm")
}

// waitForReady ينتظر الـ gRPC health check يكون SERVING
func waitForReady(ctx context.Context, conn *grpc.ClientConn, timeout time.Duration, logger *slog.Logger) error {
	healthClient := grpc_health_v1.NewHealthClient(conn)
	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		resp, err := healthClient.Check(ctx, &grpc_health_v1.HealthCheckRequest{
			Service: "processing.v1.ProcessingEngineService",
		})
		if err == nil && resp.Status == grpc_health_v1.HealthCheckResponse_SERVING {
			logger.Info("processing engine is SERVING")
			return nil
		}

		logger.Info("waiting for processing engine...",
			"remaining_sec", int(time.Until(deadline).Seconds()),
		)
		time.Sleep(2 * time.Second)
	}

	return fmt.Errorf("processing engine not ready after %s", timeout)
}

// runWarmup يبعت الـ warmup requests بشكل concurrent
func runWarmup(ctx context.Context, client processingv1.ProcessingEngineServiceClient, cfg Config, logger *slog.Logger) error {
	sem := make(chan struct{}, cfg.ConcurrentCalls)
	errs := make(chan error, cfg.WarmupRequests)

	for i := range cfg.WarmupRequests {
		sem <- struct{}{}
		go func(idx int) {
			defer func() { <-sem }()

			req := &processingv1.ProcessEventRequest{
				Event: &eventsv1.BaseEvent{
					EventId:       fmt.Sprintf("warmup-%d", idx),
					EventType:     "warmup.ping",
					Source:        "hydration-service",
					SchemaVersion: "1.0.0",
					OccurredAt:    timestamppb.Now(),
					IngestedAt:    timestamppb.Now(),
					TenantId:      "warmup",
					PartitionKey:  "warmup",
					ContentType:   "application/json",
				},
				Config: &processingv1.ProcessingConfig{
					Indicators:       []string{"rsi"},
					LookbackPeriods:  14,
					IncludeSentiment: false,
				},
			}

			_, err := client.ProcessEvent(ctx, req)
			if err != nil {
				errs <- fmt.Errorf("warmup request %d failed: %w", idx, err)
				return
			}
			errs <- nil
		}(i)
	}

	// drain الـ semaphore
	for range cfg.ConcurrentCalls {
		sem <- struct{}{}
	}
	close(errs)

	successCount := 0
	var lastErr error
	for err := range errs {
		if err != nil {
			lastErr = err
		} else {
			successCount++
		}
	}

	logger.Info("warmup complete",
		"success", successCount,
		"total",   cfg.WarmupRequests,
		"failed",  cfg.WarmupRequests-successCount,
	)

	// نعتبر ناجح لو أكثر من 80% نجحوا
	successRate := float64(successCount) / float64(cfg.WarmupRequests)
	if successRate < 0.8 {
		return fmt.Errorf("warmup success rate %.0f%% below threshold (80%%): last error: %w",
			successRate*100, lastErr)
	}

	return nil
}

func getEnv(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func getEnvInt(key string, defaultVal int) int {
	v := os.Getenv(key)
	if v == "" {
		return defaultVal
	}
	i, err := strconv.Atoi(v)
	if err != nil {
		return defaultVal
	}
	return i
}
