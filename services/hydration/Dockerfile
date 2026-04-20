FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder
ARG TARGETOS=linux
ARG TARGETARCH=arm64
ARG BUILD_VERSION=dev
WORKDIR /repo
COPY go.mod go.sum ./
COPY services/hydration/ ./services/hydration/
# cache-bust: gen/ layer invalidated 2026-03-28
COPY gen/ ./gen/
WORKDIR /repo/services/hydration
RUN go mod download && go mod verify
RUN CGO_ENABLED=0 \
    GOOS=${TARGETOS} \
    GOARCH=${TARGETARCH} \
    go build -o /hydration ./...
FROM gcr.io/distroless/static:nonroot
COPY --from=builder /hydration /hydration
USER nonroot:nonroot
ENTRYPOINT ["/hydration"]
