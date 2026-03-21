module github.com/aminpola2001-ctrl/youtuop/services/auth

go 1.22

require (
	github.com/golang-jwt/jwt/v5         v5.2.1
	github.com/google/uuid               v1.6.0
	github.com/jackc/pgx/v5             v5.5.5
	github.com/pressly/goose/v3         v3.20.0
	github.com/prometheus/client_golang v1.19.0
	github.com/redis/go-redis/v9        v9.5.1
	go.opentelemetry.io/otel            v1.40.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.40.0
	go.opentelemetry.io/otel/sdk        v1.40.0
	go.uber.org/zap                     v1.27.0
	golang.org/x/crypto                 v0.35.0
	google.golang.org/grpc              v1.79.3
)
