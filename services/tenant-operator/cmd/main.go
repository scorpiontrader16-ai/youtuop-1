package main

import (
    "context"
    "fmt"
    "log/slog"
    "os"
    "os/signal"
    "syscall"
    "time"

    "github.com/jackc/pgx/v5/pgxpool"
    "github.com/segmentio/kafka-go"
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

    // Connect to PostgreSQL
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

    // Kafka brokers
    kafkaBrokers := []string{os.Getenv("KAFKA_BROKERS")}
    if len(kafkaBrokers) == 0 || kafkaBrokers[0] == "" {
        kafkaBrokers = []string{"redpanda.platform.svc.cluster.local:9092"}
    }

    logger.Info("starting tenant operator")
    ticker := time.NewTicker(10 * time.Second)
    defer ticker.Stop()

    for {
        select {
        case <-ticker.C:
            rows, err := pool.Query(context.Background(),
                `SELECT id, slug FROM tenants WHERE status = 'active'`)
            if err != nil {
                logger.Error("query tenants", zap.Error(err))
                continue
            }
            for rows.Next() {
                var id, slug string
                if err := rows.Scan(&id, &slug); err != nil {
                    continue
                }

                // Create namespace if not exists
                nsName := fmt.Sprintf("tenant-%s", slug)
                _, err := k8sClient.CoreV1().Namespaces().Get(context.Background(), nsName, metav1.GetOptions{})
                if err != nil {
                    ns := &corev1.Namespace{
                        ObjectMeta: metav1.ObjectMeta{
                            Name: nsName,
                            Labels: map[string]string{
                                "app.kubernetes.io/managed-by": "tenant-operator",
                                "tenant-id": id,
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

                // Create Kafka topic
                topic := fmt.Sprintf("tenant-%s-events", slug)
                conn, err := kafka.DialLeader(context.Background(), "tcp", kafkaBrokers[0], topic, 0)
                if err != nil {
                    // Try to create topic
                    conn, err = kafka.Dial(context.Background(), "tcp", kafkaBrokers[0])
                    if err != nil {
                        logger.Error("dial kafka", zap.Error(err))
                        continue
                    }
                    defer conn.Close()
                    err = conn.CreateTopics(kafka.TopicConfig{
                        Topic:             topic,
                        NumPartitions:     3,
                        ReplicationFactor: 1,
                    })
                    if err != nil {
                        logger.Error("create topic", zap.Error(err), zap.String("topic", topic))
                    } else {
                        logger.Info("created topic", zap.String("topic", topic))
                    }
                } else {
                    conn.Close()
                }
            }
            rows.Close()
        case <-context.Background().Done():
            return
        }
    }
}
