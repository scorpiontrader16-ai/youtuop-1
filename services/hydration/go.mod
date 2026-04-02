module github.com/scorpiontrader16-ai/youtuop-1/services/hydration

go 1.24.0

require (
	google.golang.org/grpc v1.80.0
	google.golang.org/protobuf v1.36.11
)

require (
	github.com/grafana/pyroscope-go/godeltaprof v0.1.9 // indirect
	github.com/klauspost/compress v1.17.8 // indirect
	golang.org/x/net v0.49.0 // indirect
	golang.org/x/sys v0.40.0 // indirect
	golang.org/x/text v0.33.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260120221211-b8f7ae30c516 // indirect
)

require (
	github.com/grafana/pyroscope-go v1.2.8
	github.com/scorpiontrader16-ai/youtuop-1 v0.0.0-00010101000000-000000000000
)

replace github.com/scorpiontrader16-ai/youtuop-1 => ../..

toolchain go1.24.13
