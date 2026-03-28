// ─────────────────────────────────────────────────────────────────────────────
// Root module — Proto generation only
//
// This module exists solely to generate Go code from .proto files via buf.
// It is NOT the application entrypoint — the platform is a multi-service
// monorepo where each service under services/ has its own go.mod.
//
// Consumer: services/hydration uses a `replace` directive to import from here.
//
// To regenerate proto code:
//   make proto        (runs: buf generate)
// ─────────────────────────────────────────────────────────────────────────────

module github.com/scorpiontrader16-ai/youtuop-1

go 1.24.0

require (
	google.golang.org/grpc v1.79.3
	google.golang.org/protobuf v1.36.11
)

require (
	golang.org/x/net v0.48.0 // indirect
	golang.org/x/sys v0.39.0 // indirect
	golang.org/x/text v0.32.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20251202230838-ff82c1b0f217 // indirect
)

toolchain go1.24.13
