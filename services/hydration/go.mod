module github.com/scorpiontrader16-ai/youtuop-1/services/hydration

go 1.24.0

require (
	google.golang.org/grpc v1.79.3
	google.golang.org/protobuf v1.36.11
)

require (
	github.com/grafana/pyroscope-go/godeltaprof v0.1.9 // indirect
	github.com/klauspost/compress v1.17.8 // indirect
	golang.org/x/net v0.48.0 // indirect
	golang.org/x/sys v0.39.0 // indirect
	golang.org/x/text v0.32.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20251202230838-ff82c1b0f217 // indirect
)

require (
	github.com/grafana/pyroscope-go v1.2.8
	github.com/scorpiontrader16-ai/youtuop-1 v0.0.0-00010101000000-000000000000
)

replace github.com/scorpiontrader16-ai/youtuop-1 => ../..

toolchain go1.24.13

require github.com/scorpiontrader16-ai/youtuop-1/internal/platform v0.0.0

replace github.com/scorpiontrader16-ai/youtuop-1/internal/platform => ../../internal/platform
