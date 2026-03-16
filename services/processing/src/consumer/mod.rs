#![allow(dead_code)]
use rdkafka::config::ClientConfig;
use rdkafka::consumer::{CommitMode, Consumer, StreamConsumer};
use rdkafka::message::Message;
// FIX: rdkafka::consumer::StreamConsumer.stream() returns a futures::Stream
// Use futures::StreamExt (not tokio_stream) for .next() on rdkafka streams
use futures::StreamExt;
use tracing::{error, info, instrument};

pub struct RedpandaConsumer {
    consumer: StreamConsumer,
}

impl RedpandaConsumer {
    pub fn new(
        brokers: &str,
        group_id: &str,
        topic: &str,
    ) -> Result<Self, rdkafka::error::KafkaError> {
        let consumer: StreamConsumer = ClientConfig::new()
            .set("group.id", group_id)
            .set("bootstrap.servers", brokers)
            .set("enable.auto.commit", "false")
            .set("auto.offset.reset", "latest")
            .set("session.timeout.ms", "6000")
            .set("max.poll.interval.ms", "300000")
            .create()?;
        consumer.subscribe(&[topic])?;
        info!(brokers, group_id, topic, "Redpanda consumer ready");
        Ok(Self { consumer })
    }

    #[instrument(skip(self))]
    pub async fn consume_loop(&self) {
        let mut stream = self.consumer.stream();
        loop {
            match stream.next().await {
                Some(Ok(msg)) => {
                    if let Some(payload) = msg.payload() {
                        match self.process_message(payload).await {
                            Ok(()) => {
                                if let Err(e) = self.consumer.commit_message(&msg, CommitMode::Async) {
                                    error!(error = %e, "commit failed");
                                }
                            }
                            Err(e) => {
                                error!(error = %e, "processing failed");
                                // TODO: forward to Dead Letter Topic
                            }
                        }
                    }
                }
                Some(Err(e)) => error!(error = %e, "Kafka error"),
                None => {
                    info!("stream ended");
                    break;
                }
            }
        }
    }

    async fn process_message(&self, _payload: &[u8]) -> Result<(), anyhow::Error> {
        // TODO: prost::Message::decode(payload) → call engine
        Ok(())
    }
}
