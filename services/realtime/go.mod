module github.com/aminpola2001-ctrl/youtuop/services/realtime

go 1.24.0

toolchain go1.24.13

require (
	github.com/coder/websocket          v1.8.12
	github.com/golang-jwt/jwt/v5       v5.2.2
	github.com/google/uuid             v1.6.0
	github.com/prometheus/client_golang v1.19.0
	github.com/redis/go-redis/v9       v9.5.1
	github.com/twmb/franz-go           v1.17.1
	github.com/twmb/franz-go/pkg/kadm v1.12.0
	go.opentelemetry.io/otel           v1.40.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.40.0
	go.opentelemetry.io/otel/sdk       v1.40.0
	go.uber.org/zap                    v1.27.0
	google.golang.org/grpc             v1.79.3
)
