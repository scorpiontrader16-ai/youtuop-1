//! Kafka / Redpanda consumer with Circuit Breaker on gRPC calls

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use metrics::{counter, gauge};
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

// ── Circuit Breaker ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
enum CbState {
    Closed,
    Open,
    HalfOpen,
}

struct CircuitBreaker {
    state:                CbState,
    consecutive_failures: u32,
    failure_threshold:    u32,
    last_failure:         Option<Instant>,
    timeout:              Duration,
}

impl CircuitBreaker {
    fn new(failure_threshold: u32, timeout: Duration) -> Self {
        Self {
            state:                CbState::Closed,
            consecutive_failures: 0,
            failure_threshold,
            last_failure:         None,
            timeout,
        }
    }

    fn allow(&mut self) -> bool {
        match self.state {
            CbState::Closed | CbState::HalfOpen => true,
            CbState::Open => {
                if let Some(t) = self.last_failure {
                    if t.elapsed() >= self.timeout {
                        self.state = CbState::HalfOpen;
                        info!("circuit breaker → half-open");
                        return true;
                    }
                }
                false
            }
        }
    }

    fn on_success(&mut self) {
        if self.state == CbState::HalfOpen {
            info!("circuit breaker → closed");
        }
        self.state                = CbState::Closed;
        self.consecutive_failures = 0;
        self.last_failure         = None;
    }

    fn on_failure(&mut self) {
        self.consecutive_failures += 1;
        self.last_failure          = Some(Instant::now());
        if self.consecutive_failures >= self.failure_threshold
            && self.state != CbState::Open
        {
            warn!(failures = self.consecutive_failures, "circuit breaker → open");
            self.state = CbState::Open;
        }
    }

    fn is_open(&self) -> bool {
        self.state == CbState::Open
    }
}

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
    consumer:        StreamConsumer,
    client:          ProcessingEngineServiceClient<Channel>,
    circuit_breaker: Arc<Mutex<CircuitBreaker>>,
    #[allow(dead_code)]
    config:          ConsumerConfig,
}

impl KafkaConsumer {
    pub async fn new(
        config: ConsumerConfig,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let consumer: StreamConsumer = ClientConfig::new()
            .set("bootstrap.servers",    &config.brokers)
            .set("group.id",             &config.group_id)
            .set("enable.auto.commit",   "false")
            .set("auto.offset.reset",    "earliest")
            .set("session.timeout.ms",   "30000")
            .set("max.poll.interval.ms", "300000")
            .set("fetch.max.bytes",      "10485760")
            .create()?;

        consumer.subscribe(&[&config.topic])?;
        info!(topic = %config.topic, brokers = %config.brokers, "Kafka consumer subscribed");

        let client = connect_with_retry(&config.processing_addr, 5).await?;
        let circuit_breaker = Arc::new(Mutex::new(
            CircuitBreaker::new(5, Duration::from_secs(30))
        ));

        Ok(Self { consumer, client, circuit_breaker, config })
    }

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
                            counter!("processing_kafka_errors_total", "type" => "receive").increment(1);
                            sleep(Duration::from_millis(500)).await;
                        }
                        Ok(msg) => {
                            let partition = msg.partition();
                            let offset    = msg.offset();
                            let topic     = msg.topic().to_string();
                            let payload   = msg.payload().map(|p| p.to_vec());

                            let allowed = {
                                let mut cb = self.circuit_breaker.lock().unwrap();
                                cb.allow()
                            };

                            if !allowed {
                                warn!("circuit breaker open — dropping message");
                                counter!("processing_kafka_errors_total", "type" => "circuit_open").increment(1);
                                gauge!("processing_circuit_breaker_open").set(1.0);
                                sleep(Duration::from_secs(1)).await;
                                continue;
                            }

                            let success = handle_message(
                                &mut self.client,
                                &topic, partition, offset, payload,
                            ).await;

                            {
                                let mut cb = self.circuit_breaker.lock().unwrap();
                                if success {
                                    cb.on_success();
                                    gauge!("processing_circuit_breaker_open").set(0.0);
                                } else {
                                    cb.on_failure();
                                    if cb.is_open() {
                                        gauge!("processing_circuit_breaker_open").set(1.0);
                                    }
                                }
                            }

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
}

// ── Free functions ────────────────────────────────────────────────────────

#[instrument(skip(client, payload), fields(%topic, partition, offset))]
async fn handle_message(
    client:    &mut ProcessingEngineServiceClient<Channel>,
    topic:     &str,
    partition: i32,
    offset:    i64,
    payload:   Option<Vec<u8>>,
) -> bool {
    let bytes = match payload {
        Some(b) if !b.is_empty() => b,
        _ => {
            warn!(%topic, partition, offset, "empty payload — skipping");
            counter!("processing_kafka_messages_total", "status" => "skipped").increment(1);
            return true;
        }
    };

    let event = match MarketEvent::decode(bytes.as_slice()) {
        Ok(e)  => e,
        Err(e) => {
            error!(error = %e, "protobuf decode failed");
            counter!("processing_kafka_errors_total", "type" => "decode").increment(1);
            counter!("processing_kafka_messages_total", "status" => "decode_error").increment(1);
            return false;
        }
    };

    info!(event_id = %event.event_id, symbol = %event.symbol, "forwarding event");

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
            counter!("processing_kafka_messages_total", "status" => "success").increment(1);
            true
        }
        Err(e) => {
            error!(error = %e, "gRPC process_event failed");
            counter!("processing_kafka_errors_total", "type" => "grpc").increment(1);
            counter!("processing_kafka_messages_total", "status" => "grpc_error").increment(1);
            false
        }
    }
}

async fn connect_with_retry(
    addr:        &str,
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
                warn!(addr, attempt, max_retries,
                    delay_secs = delay.as_secs(), error = %e,
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
        indicators:        vec!["rsi".into(), "macd".into(), "correlation".into()],
        lookback_periods:  14,
        include_sentiment: false,
    }
}
