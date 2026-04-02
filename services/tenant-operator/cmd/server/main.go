package main

// ╔══════════════════════════════════════════════════════════════════╗
// ║  services/tenant-operator/cmd/server/main.go                    ║
// ║  M9 — reconcile loop: provisions K8s resources per active tenant ║
// ╚══════════════════════════════════════════════════════════════════╝

import (
	"github.com/scorpiontrader16-ai/youtuop-1/services/tenant-operator/internal/profiling"
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"log/slog"

	"go.uber.org/zap"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"

	"github.com/scorpiontrader16-ai/youtuop-1/services/tenant-operator/internal/onboarding"
)

func main() {
	logger := zap.Must(zap.NewProduction())

	// GAP-11: Continuous profiling — slog adapter for pyroscope
	profiling.Init(slog.Default())
	defer logger.Sync() //nolint:errcheck

	// ── PostgreSQL ────────────────────────────────────────────────────
	pgConn := os.Getenv("POSTGRES_CONN")
	if pgConn == "" {
		logger.Fatal("POSTGRES_CONN is required — set via ExternalSecret")
	}

	pool, err := pgxpool.New(context.Background(), pgConn)
	if err != nil {
		logger.Fatal("failed to connect postgres", zap.Error(err))
	}
	defer pool.Close()

	// ── Kubernetes ────────────────────────────────────────────────────
	k8sCfg, err := rest.InClusterConfig()
	if err != nil {
		logger.Fatal("failed to get k8s config", zap.Error(err))
	}
	k8sClient, err := kubernetes.NewForConfig(k8sCfg)
	if err != nil {
		logger.Fatal("failed to create k8s client", zap.Error(err))
	}

	provisioner := onboarding.NewProvisioner(k8sClient, logger)

	logger.Info("tenant-operator started")

	// ── Reconcile Loop ────────────────────────────────────────────────
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	for {
		select {
		case <-ctx.Done():
			logger.Info("tenant-operator stopping")
			return

		case <-ticker.C:
			if err := reconcile(ctx, pool, provisioner, logger); err != nil {
				logger.Error("reconcile error", zap.Error(err))
			}
		}
	}
}

// reconcile queries all active tenants and ensures their K8s resources exist.
func reconcile(ctx context.Context, pool *pgxpool.Pool, p *onboarding.Provisioner, logger *zap.Logger) error {
	rows, err := pool.Query(ctx,
		`SELECT id, slug, tier FROM tenants WHERE status = 'active'`)
	if err != nil {
		return err
	}
	defer rows.Close()

	var provisioned int
	for rows.Next() {
		var id, slug, tier string
		if err := rows.Scan(&id, &slug, &tier); err != nil {
			logger.Error("scan tenant row", zap.Error(err))
			continue
		}

		if err := p.Provision(ctx, id, slug, tier); err != nil {
			logger.Error("provision tenant",
				zap.String("tenant_id", id),
				zap.String("slug", slug),
				zap.Error(err),
			)
			continue
		}
		provisioned++
	}

	if err := rows.Err(); err != nil {
		return err
	}

	logger.Info("reconcile complete", zap.Int("provisioned", provisioned))
	return nil
}


