# syntax=docker/dockerfile:1.7
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder
ARG TARGETOS=linux
ARG TARGETARCH=arm64
WORKDIR /app
RUN apk add --no-cache git ca-certificates
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -ldflags="-s -w" -trimpath -o /tenant-operator ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /tenant-operator /tenant-operator
USER 1000:1000
ENTRYPOINT ["/tenant-operator"]
