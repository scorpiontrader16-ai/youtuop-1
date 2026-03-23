package main

import (
    "context"
    "fmt"
    "log/slog"
    "os"
    "time"

    "github.com/jackc/pgx/v5/pgxpool"
    "go.uber.org/zap"
    corev1 "k8s.io/api/core/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/rest"
)

func main() {
    logger, _ := zap.NewProduction()
    defer logger.Sync()
    slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

    // Postgres connection
    pgConn := os.Getenv("POSTGRES_CONN")
    if pgConn == "" {
        pgConn = "postgres://postgres:postgres@postgres.platform.svc.cluster.local:5432/platform?sslmode=disable"
    }
    pool, err := pgxpool.New(context.Background(), pgConn)
    if err != nil {
        logger.Fatal("failed to connect postgres", zap.Error(err))
    }
    defer pool.Close()

    // Kubernetes client
    config, err := rest.InClusterConfig()
    if err != nil {
        logger.Fatal("failed to get k8s config", zap.Error(err))
    }
    k8sClient, err := kubernetes.NewForConfig(config)
    if err != nil {
        logger.Fatal("failed to create k8s client", zap.Error(err))
    }

    // Redpanda brokers (placeholder – topic creation not implemented in this version)
    // kafkaBrokers := []string{os.Getenv("KAFKA_BROKERS")}
    // if len(kafkaBrokers) == 0 || kafkaBrokers[0] == "" {
    //     kafkaBrokers = []string{"redpanda.platform.svc.cluster.local:9092"}
    // }

    logger.Info("tenant operator started")
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()

    for {
        select {
        case <-ticker.C:
            rows, err := pool.Query(context.Background(),
                `SELECT id, slug, custom_domain, status FROM tenants WHERE status IN ('active', 'suspended')`)
            if err != nil {
                logger.Error("query tenants", zap.Error(err))
                continue
            }

            for rows.Next() {
                var id, slug, customDomain, status string
                if err := rows.Scan(&id, &slug, &customDomain, &status); err != nil {
                    continue
                }

                // Ensure Kubernetes namespace
                nsName := fmt.Sprintf("tenant-%s", slug)
                _, err := k8sClient.CoreV1().Namespaces().Get(context.Background(), nsName, metav1.GetOptions{})
                if err != nil {
                    ns := &corev1.Namespace{
                        ObjectMeta: metav1.ObjectMeta{
                            Name: nsName,
                            Labels: map[string]string{
                                "app.kubernetes.io/managed-by": "tenant-operator",
                                "tenant-id":                    id,
                            },
                        },
                    }
                    _, err = k8sClient.CoreV1().Namespaces().Create(context.Background(), ns, metav1.CreateOptions{})
                    if err != nil {
                        logger.Error("create namespace", zap.Error(err), zap.String("ns", nsName))
                    } else {
                        logger.Info("created namespace", zap.String("ns", nsName))
                    }
                }

                // TODO: create Kafka topic using kafka admin client
                // For now just log
                logger.Info("ensuring kafka topic", zap.String("topic", fmt.Sprintf("tenant-%s-events", slug)))

                // TODO: create PostgreSQL schema (schema-per-tenant)
            }
            rows.Close()

        case <-context.Background().Done():
            return
        }
    }
}
