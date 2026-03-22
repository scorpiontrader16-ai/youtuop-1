FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder
ARG TARGETOS=linux
ARG TARGETARCH=arm64
ARG BUILD_VERSION=dev
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY . .
RUN go mod tidy && \
    CGO_ENABLED=0 \
    GOOS=${TARGETOS} \
    GOARCH=${TARGETARCH} \
    go build \
    -ldflags="-s -w -X main.version=${BUILD_VERSION}" \
    -trimpath \
    -o /bin/server \
    ./cmd/server
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /bin/server /server
LABEL org.opencontainers.image.title="feature-flags"
LABEL org.opencontainers.image.description="Go feature flags service"
USER 65532:65532
EXPOSE 9096
ENTRYPOINT ["/server"]
