package main

import (
    "context"
    "log/slog"
    "os"
    "os/signal"
    "syscall"
    "time"

    "github.com/gofiber/fiber/v2"
    "github.com/gofiber/contrib/otelfiber"
    "github.com/jackc/pgx/v5"
    "github.com/prometheus/client_golang/prometheus/promhttp"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.21.0"

    "github.com/aminpola2001-ctrl/youtuop/services/analytics/internal/handlers"
)

var version = "dev"

func main() {
    logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
    slog.SetDefault(logger)

    shutdown, err := initTracer()
    if err != nil {
        slog.Error("failed to init tracer", "error", err)
    }
    defer shutdown(context.Background())

    pgConn := os.Getenv("POSTGRES_CONN")
    if pgConn == "" {
        pgConn = "postgres://postgres:postgres@postgres.platform.svc.cluster.local:5432/platform?sslmode=disable"
    }
    pg, err := pgx.Connect(context.Background(), pgConn)
    if err != nil {
        slog.Error("failed to connect postgres", "error", err)
        os.Exit(1)
    }
    defer pg.Close(context.Background())

    app := fiber.New(fiber.Config{
        DisableStartupMessage: true,
    })
    app.Use(otelfiber.Middleware("analytics"))

    // Health checks
    app.Get("/healthz", func(c *fiber.Ctx) error {
        return c.SendString("ok")
    })
    app.Get("/readyz", func(c *fiber.Ctx) error {
        if err := pg.Ping(context.Background()); err != nil {
            return c.Status(fiber.StatusServiceUnavailable).SendString("postgres not ready")
        }
        return c.SendString("ready")
    })

    // Routes
    evHandler := handlers.NewEventHandler(pg)
    app.Post("/api/v1/analytics/track", evHandler.Track)

    // Metrics
    app.Get("/metrics", func(c *fiber.Ctx) error {
        promhttp.Handler().ServeHTTP(c.Response().BodyWriter(), c.Context())
        return nil
    })

    httpPort := os.Getenv("HTTP_PORT")
    if httpPort == "" {
        httpPort = "9096"
    }

    go func() {
        slog.Info("starting HTTP server", "port", httpPort)
        if err := app.Listen(":" + httpPort); err != nil {
            slog.Error("http server error", "error", err)
        }
    }()

    quit := make(chan os.Signal, 1)
    signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
    <-quit
    slog.Info("shutting down server...")
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    if err := app.ShutdownWithContext(ctx); err != nil {
        slog.Error("shutdown error", "error", err)
    }
    slog.Info("shutdown complete")
}

func initTracer() (func(context.Context) error, error) {
    endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if endpoint == "" {
        return func(context.Context) error { return nil }, nil
    }

    ctx := context.Background()
    exporter, err := otlptracegrpc.New(ctx,
        otlptracegrpc.WithEndpoint(endpoint),
        otlptracegrpc.WithInsecure(),
    )
    if err != nil {
        return nil, err
    }

    res, err := resource.New(ctx,
        resource.WithAttributes(
            semconv.ServiceName("analytics"),
            semconv.ServiceVersion(version),
        ),
        resource.WithFromEnv(),
        resource.WithTelemetrySDK(),
    )
    if err != nil {
        return nil, err
    }

    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter),
        sdktrace.WithResource(res),
    )
    otel.SetTracerProvider(tp)
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{},
        propagation.Baggage{},
    ))

    return tp.Shutdown, nil
}
