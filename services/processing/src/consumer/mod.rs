//! Kafka / Redpanda consumer
//!
//! Reads MarketEvents from a Kafka topic (protobuf-encoded),
//! deserializes them, and forwards each event to the ProcessingEngine
//! via gRPC (ProcessEvent RPC).

use std::time::Duration;

use prost::Message;
use rdkafka::{
    config::ClientConfig,
    consumer::{CommitMode, Consumer, StreamConsumer},
    Message as KafkaMessage,
};
use tokio::time::sleep;
use tonic::transport::Channel;
use tracing::{error, info, instrument, warn};

use crate::grpc::processing_v1::{
    processing_engine_service_client::ProcessingEngineServiceClient,
    ProcessEventRequest, ProcessingConfig,
};
use crate::ingestion::v1::MarketEvent;

// ── Config ────────────────────────────────────────────────────────────────
#[derive(Debug, Clone)]
pub struct ConsumerConfig {
    pub brokers:         String,
    pub group_id:        String,
    pub topic:           String,
    pub processing_addr: String,
}

impl ConsumerConfig {
    pub fn from_env() -> Self {
        Self {
            brokers: std::env::var("REDPANDA_BROKERS")
                .unwrap_or_else(|_| "redpanda:9092".into()),
            group_id: std::env::var("KAFKA_GROUP_ID")
                .unwrap_or_else(|_| "processing-consumer".into()),
            topic: std::env::var("KAFKA_TOPIC")
                .unwrap_or_else(|_| "market-events".into()),
            processing_addr: std::env::var("PROCESSING_ADDR")
                .unwrap_or_else(|_| "http://processing:50051".into()),
        }
    }
}

// ── Consumer ──────────────────────────────────────────────────────────────
pub struct KafkaConsumer {
    consumer: StreamConsumer,
    client:   ProcessingEngineServiceClient<Channel>,
    /// Retained for future use (e.g. dynamic topic reload)
    #[allow(dead_code)]
    config:   ConsumerConfig,
}

impl KafkaConsumer {
    /// Build the Kafka consumer and connect to the gRPC server.
    /// Retries the gRPC connection up to 5 times with backoff.
    pub async fn new(config: ConsumerConfig) -> Result<Self, Box<dyn std::error::Error>> {
        let consumer: StreamConsumer = ClientConfig::new()
            .set("bootstrap.servers",    &config.brokers)
            .set("group.id",             &config.group_id)
            .set("enable.auto.commit",   "false")
            .set("auto.offset.reset",    "earliest")
            .set("session.timeout.ms",   "30000")
            .set("max.poll.interval.ms", "300000")
            .set("fetch.max.bytes",      "10485760") // 10 MB
            .create()?;

        consumer.subscribe(&[&config.topic])?;
        info!(topic = %config.topic, brokers = %config.brokers, "Kafka consumer subscribed");

        let client = connect_with_retry(&config.processing_addr, 5).await?;

        Ok(Self { consumer, client, config })
    }

    /// Main loop — runs until the shutdown watch fires.
    pub async fn run(mut self, mut shutdown: tokio::sync::watch::Receiver<bool>) {
        info!("consumer loop started");

        loop {
            tokio::select! {
                _ = shutdown.changed() => {
                    if *shutdown.borrow() {
                        info!("consumer received shutdown signal");
                        break;
                    }
                }

                result = self.consumer.recv() => {
                    match result {
                        Err(e) => {
                            error!(error = %e, "kafka receive error");
                            sleep(Duration::from_millis(500)).await;
                        }
                        Ok(msg) => {
                            // Copy metadata + payload out of the borrowed message
                            // BEFORE calling handle_message so the borrow on
                            // self.consumer is released and we can pass &mut self.client
                            let partition = msg.partition();
                            let offset    = msg.offset();
                            let topic     = msg.topic().to_string();
                            let payload   = msg.payload().map(|p| p.to_vec());

                            handle_message(
                                &mut self.client,
                                &topic, partition, offset, payload,
                            ).await;

                            if let Err(e) = self.consumer.commit_message(&msg, CommitMode::Async) {
                                warn!(error = %e, "commit failed");
                            }
                        }
                    }
                }
            }
        }

        info!("consumer loop stopped");
    }
} // ── end impl KafkaConsumer ───────────────────────────────────────────────

// ── Free functions ────────────────────────────────────────────────────────
// These are intentionally outside the impl block so we can borrow
// `client` and `consumer` independently inside the run loop.

/// Decode a protobuf payload and forward the MarketEvent via gRPC.
#[instrument(skip(client, payload), fields(%topic, partition, offset))]
async fn handle_message(
    client:    &mut ProcessingEngineServiceClient<Channel>,
    topic:     &str,
    partition: i32,
    offset:    i64,
    payload:   Option<Vec<u8>>,
) {
    let bytes = match payload {
        Some(b) if !b.is_empty() => b,
        _ => {
            warn!(%topic, partition, offset, "empty payload — skipping");
            return;
        }
    };

    let event = match MarketEvent::decode(bytes.as_slice()) {
        Ok(e)  => e,
        Err(e) => {
            error!(error = %e, %topic, partition, offset, "protobuf decode failed");
            return;
        }
    };

    info!(
        event_id = %event.event_id,
        symbol   = %event.symbol,
        "forwarding event to processing engine"
    );

    let request = ProcessEventRequest {
        event:  Some(event),
        config: Some(default_processing_config()),
    };

    match client.process_event(request).await {
        Ok(response) => {
            let r = response.into_inner();
            info!(
                event_id          = %r.event_id,
                correlation_score = r.correlation_score,
                processing_us     = r.processing_us,
                "event processed successfully"
            );
        }
        Err(e) => {
            error!(error = %e, "gRPC process_event failed");
        }
    }
}

/// Connect to the gRPC server with exponential backoff.
async fn connect_with_retry(
    addr: &str,
    max_retries: u32,
) -> Result<ProcessingEngineServiceClient<Channel>, Box<dyn std::error::Error>> {
    let mut delay = Duration::from_secs(1);

    for attempt in 1..=max_retries {
        match Channel::from_shared(addr.to_string())
            .map_err(|e| format!("invalid gRPC address: {e}"))?
            .connect()
            .await
        {
            Ok(channel) => {
                info!(addr, "connected to processing gRPC server");
                return Ok(ProcessingEngineServiceClient::new(channel));
            }
            Err(e) => {
                if attempt == max_retries {
                    return Err(format!(
                        "failed to connect to {} after {} attempts: {}",
                        addr, max_retries, e
                    ).into());
                }
                warn!(
                    addr,
                    attempt,
                    max_retries,
                    delay_secs = delay.as_secs(),
                    error = %e,
                    "gRPC connection failed, retrying"
                );
                sleep(delay).await;
                delay = (delay * 2).min(Duration::from_secs(30));
            }
        }
    }

    unreachable!()
}

fn default_processing_config() -> ProcessingConfig {
    ProcessingConfig {
        indicators:       vec!["rsi".into(), "macd".into(), "correlation".into()],
        lookback_periods: 14,
        include_sentiment: false,
    }
}
