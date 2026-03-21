module github.com/aminpola2001-ctrl/youtuop/services/billing

go 1.24.0

toolchain go1.24.13

require (
	github.com/jackc/pgx/v5              v5.5.5
	github.com/pressly/goose/v3          v3.20.0
	github.com/prometheus/client_golang  v1.19.0
	github.com/stripe/stripe-go/v81      v81.3.0
	go.opentelemetry.io/otel             v1.40.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.40.0
	go.opentelemetry.io/otel/sdk         v1.40.0
	go.uber.org/zap                      v1.27.0
	google.golang.org/grpc               v1.79.3
)
