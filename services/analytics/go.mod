module github.com/aminpola2001-ctrl/youtuop/services/analytics

go 1.24.0

toolchain go1.24.13

require (
    github.com/gofiber/fiber/v2 v2.52.5
    github.com/gofiber/contrib/otelfiber v1.0.10
    github.com/jackc/pgx/v5 v5.5.5
    github.com/pressly/goose/v3 v3.20.0
    github.com/prometheus/client_golang v1.19.0
    go.opentelemetry.io/otel v1.40.0
    go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.40.0
    go.opentelemetry.io/otel/sdk v1.40.0
    go.uber.org/zap v1.27.0
    google.golang.org/grpc v1.79.3
    google.golang.org/protobuf v1.36.11
)
