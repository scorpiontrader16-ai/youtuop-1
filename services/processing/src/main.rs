//! Processing Service — HTTP health/metrics + gRPC server + Kafka consumer
use std::net::SocketAddr;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::get,
    Router,
};
use metrics_exporter_prometheus::{PrometheusBuilder, PrometheusHandle};
use tokio::signal;
use tokio_stream::wrappers::TcpListenerStream;
use tracing::info;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

mod engine;
mod consumer;
mod grpc;

// FIX: كان ingestion::v1 — غُيّر لـ events::v1 عشان يطابق package في event.proto
pub mod events {
    pub mod v1 {
        tonic::include_proto!("events.v1");
    }
}

// ── Health state ──────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct AppState {
    pub grpc_ready:  Arc<AtomicBool>,
    pub kafka_ready: Arc<AtomicBool>,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            grpc_ready:  Arc::new(AtomicBool::new(false)),
            kafka_ready: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl Default for AppState {
    fn default() -> Self { Self::new() }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()),
        ))
        .with(tracing_subscriber::fmt::layer().json())
        .init();

    let config = Config::from_env()?;

    info!(
        version      = env!("CARGO_PKG_VERSION"),
        grpc_port    = config.grpc_port,
        metrics_port = config.metrics_port,
        "starting processing service"
    );

    // ── Prometheus exporter ───────────────────────────────────────────────
    let prometheus_handle = PrometheusBuilder::new()
        .install_recorder()
        .map_err(|e| format!("failed to install prometheus recorder: {e}"))?;

    let state = AppState::new();

    // ── Shutdown channel ──────────────────────────────────────────────────
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

    // ── gRPC server ───────────────────────────────────────────────────────
    let grpc_addr: SocketAddr = format!("0.0.0.0:{}", config.grpc_port)
        .parse()
        .map_err(|e| format!("invalid gRPC address: {e}"))?;

    let grpc_listener = tokio::net::TcpListener::bind(grpc_addr).await
        .map_err(|e| format!("failed to bind gRPC port {}: {}", config.grpc_port, e))?;

    let reflection = tonic_reflection::server::Builder::configure()
        .register_encoded_file_descriptor_set(grpc::processing_v1::FILE_DESCRIPTOR_SET)
        .build_v1()
        .map_err(|e| format!("reflection build error: {e}"))?;

    let engine = grpc::Engine::new();

    state.grpc_ready.store(true, Ordering::Relaxed);
    info!(port = config.grpc_port, "gRPC server listening");

    tokio::spawn(async move {
        tonic::transport::Server::builder()
            .add_service(engine.into_server())
            .add_service(reflection)
            .serve_with_incoming(TcpListenerStream::new(grpc_listener))
            .await
            .expect("gRPC server failed");
    });

    // ── Kafka consumer ────────────────────────────────────────────────────
    let consumer_config = consumer::ConsumerConfig::from_env();
    match consumer::KafkaConsumer::new(consumer_config).await {
        Ok(kafka) => {
            state.kafka_ready.store(true, Ordering::Relaxed);
            info!("Kafka consumer connected and ready");
            let rx = shutdown_rx.clone();
            tokio::spawn(async move {
                kafka.run(rx).await;
            });
        }
        Err(e) => {
            tracing::warn!(
                error = %e,
                "Kafka consumer failed to start — readyz will report not-ready"
            );
        }
    }
    drop(shutdown_rx);

    // ── HTTP server ───────────────────────────────────────────────────────
    let metrics_addr: SocketAddr = format!("0.0.0.0:{}", config.metrics_port)
        .parse()
        .map_err(|e| format!("invalid metrics address: {e}"))?;

    let shutdown = async move {
        match signal::ctrl_c().await {
            Ok(())  => info!("shutdown signal received"),
            Err(e)  => tracing::error!(error = %e, "ctrl_c listener error"),
        }
        let _ = shutdown_tx.send(true);
    };

    run_http_server(metrics_addr, state, prometheus_handle, shutdown).await?;
    info!("shutdown complete");
    Ok(())
}

// ── HTTP server ───────────────────────────────────────────────────────────
async fn run_http_server(
    addr:              SocketAddr,
    state:             AppState,
    prometheus_handle: PrometheusHandle,
    shutdown:          impl std::future::Future<Output = ()> + Send + 'static,
) -> Result<(), Box<dyn std::error::Error>> {
    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz",  get(readyz))
        .route("/metrics", get({
            let handle = prometheus_handle.clone();
            move || {
                let h = handle.clone();
                async move {
                    (
                        StatusCode::OK,
                        [(axum::http::header::CONTENT_TYPE, "text/plain; version=0.0.4")],
                        h.render(),
                    )
                }
            }
        }))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    info!(port = addr.port(), "HTTP server listening");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown)
        .await?;

    Ok(())
}

// ── Health handlers ───────────────────────────────────────────────────────

async fn healthz() -> impl IntoResponse {
    StatusCode::OK
}

async fn readyz(State(state): State<AppState>) -> impl IntoResponse {
    let grpc_ok  = state.grpc_ready.load(Ordering::Relaxed);
    let kafka_ok = state.kafka_ready.load(Ordering::Relaxed);

    if grpc_ok && kafka_ok {
        (StatusCode::OK, "ready")
    } else {
        let reason = if !grpc_ok { "grpc not ready" } else { "kafka not ready" };
        tracing::warn!(reason, "readyz check failed");
        (StatusCode::SERVICE_UNAVAILABLE, reason)
    }
}

// ── Config ────────────────────────────────────────────────────────────────
#[derive(Debug)]
pub struct Config {
    pub grpc_port:    u16,
    pub metrics_port: u16,
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        Ok(Self {
            grpc_port:    parse_port("GRPC_PORT",    50051)?,
            metrics_port: parse_port("METRICS_PORT", 9090)?,
        })
    }
}

fn parse_port(key: &str, default: u16) -> Result<u16, String> {
    match std::env::var(key) {
        Ok(v) => v
            .parse::<u16>()
            .map_err(|_| format!("{key} must be 1-65535, got: {v}")),
        Err(_) => Ok(default),
    }
}
