//! gRPC server — ProcessingEngineService implementation

use std::collections::HashMap;
use std::pin::Pin;
use std::time::Instant;

use futures::Stream;
use tokio::sync::mpsc;
use tokio_stream::{wrappers::ReceiverStream, StreamExt as _};
use tonic::{Request, Response, Status, Streaming};
use tracing::{info, instrument, warn};

use crate::engine::{CorrelationEngine, SignalEngine};

// processing_v1 is at crate::grpc::processing_v1.
// prost generates super::super::ingestion::v1::MarketEvent in processing.v1.rs.
// super::super from here = crate  →  crate::ingestion::v1  ✅ (declared in main.rs)
pub mod processing_v1 {
    tonic::include_proto!("processing.v1");
    pub const FILE_DESCRIPTOR_SET: &[u8] =
        tonic::include_file_descriptor_set!("processing_descriptor");
}

use crate::ingestion::v1::market_event::Data as EventData;
use processing_v1::{
    processing_engine_service_server::{
        ProcessingEngineService, ProcessingEngineServiceServer,
    },
    signal::Direction,
    CorrelationRequest, CorrelationResponse, ProcessEventRequest, ProcessEventResponse,
    RiskMetrics, Signal, SignalRequest, SignalResponse, TradingSignal,
};

// ── Service struct ────────────────────────────────────────────────────────
pub struct Engine {
    signal: SignalEngine,
    #[allow(dead_code)]
    correlation: CorrelationEngine,
}

impl Engine {
    pub fn new() -> Self {
        Self {
            signal:      SignalEngine::new(),
            correlation: CorrelationEngine::new(),
        }
    }

    pub fn into_server(self) -> ProcessingEngineServiceServer<Self> {
        ProcessingEngineServiceServer::new(self)
    }
}

impl Default for Engine {
    fn default() -> Self { Self::new() }
}

impl std::fmt::Debug for Engine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Engine").finish()
    }
}

// ── RPC implementations ───────────────────────────────────────────────────
#[tonic::async_trait]
impl ProcessingEngineService for Engine {
    #[instrument(skip(self, request))]
    async fn process_event(
        &self,
        request: Request<ProcessEventRequest>,
    ) -> Result<Response<ProcessEventResponse>, Status> {
        let start = Instant::now();
        let req   = request.into_inner();

        let event = req.event
            .ok_or_else(|| Status::invalid_argument("event is required"))?;

        let (signal, indicators) = analyze_event(&event);
        let processing_us = start.elapsed().as_micros() as f64;

        info!(
            event_id  = %event.event_id,
            symbol    = %event.symbol,
            processing_us,
            "event processed"
        );

        Ok(Response::new(ProcessEventResponse {
            event_id:          event.event_id,
            correlation_score: 0.0,
            primary_signal:    Some(signal),
            indicators,
            risk:              Some(default_risk_metrics()),
            processing_us,
            processed_at:      Some(now_timestamp()),
        }))
    }

    type ProcessStreamStream =
        Pin<Box<dyn Stream<Item = Result<ProcessEventResponse, Status>> + Send + 'static>>;

    async fn process_stream(
        &self,
        request: Request<Streaming<ProcessEventRequest>>,
    ) -> Result<Response<Self::ProcessStreamStream>, Status> {
        let mut inbound = request.into_inner();
        let (tx, rx)    = mpsc::channel::<Result<ProcessEventResponse, Status>>(32);

        tokio::spawn(async move {
            while let Some(result) = inbound.next().await {
                let response = match result {
                    Err(e) => {
                        warn!(error = %e, "stream receive error");
                        Err(Status::internal(e.to_string()))
                    }
                    Ok(req) => match req.event {
                        None => Err(Status::invalid_argument("event is required")),
                        Some(event) => {
                            let start = Instant::now();
                            let (signal, indicators) = analyze_event(&event);
                            let processing_us = start.elapsed().as_micros() as f64;
                            Ok(ProcessEventResponse {
                                event_id:          event.event_id,
                                correlation_score: 0.0,
                                primary_signal:    Some(signal),
                                indicators,
                                risk:              Some(default_risk_metrics()),
                                processing_us,
                                processed_at:      Some(now_timestamp()),
                            })
                        }
                    },
                };
                if tx.send(response).await.is_err() {
                    break;
                }
            }
        });

        Ok(Response::new(Box::pin(ReceiverStream::new(rx))))
    }

    async fn compute_correlation(
        &self,
        request: Request<CorrelationRequest>,
    ) -> Result<Response<CorrelationResponse>, Status> {
        let req = request.into_inner();

        if req.symbol_a.is_empty() || req.symbol_b.is_empty() {
            return Err(Status::invalid_argument("symbol_a and symbol_b are required"));
        }
        if req.lookback_days <= 0 {
            return Err(Status::invalid_argument("lookback_days must be positive"));
        }

        Ok(Response::new(CorrelationResponse {
            symbol_a:       req.symbol_a,
            symbol_b:       req.symbol_b,
            coefficient:    0.0,
            p_value:        1.0,
            is_significant: false,
        }))
    }

    #[instrument(skip(self, request))]
    async fn extract_signals(
        &self,
        request: Request<SignalRequest>,
    ) -> Result<Response<SignalResponse>, Status> {
        let req = request.into_inner();

        if req.symbol.is_empty() {
            return Err(Status::invalid_argument("symbol is required"));
        }
        if req.prices.len() < 2 {
            return Err(Status::invalid_argument("at least 2 price points are required"));
        }

        let mut values  = HashMap::new();
        let mut signals = Vec::new();

        if req.prices.len() >= 15 {
            match self.signal.rsi(&req.prices, 14) {
                Ok(rsi) => {
                    values.insert("rsi_14".into(), rsi);
                    signals.push(TradingSignal {
                        r#type:      "RSI".into(),
                        value:       rsi,
                        description: rsi_description(rsi).into(),
                    });
                }
                Err(e) => warn!(error = %e, "RSI failed"),
            }
        }

        if req.prices.len() >= 35 {
            match self.signal.macd(&req.prices, 12, 26, 9) {
                Ok(macd) => {
                    values.insert("macd".into(),        macd.macd);
                    values.insert("macd_signal".into(), macd.signal);
                    values.insert("macd_hist".into(),   macd.histogram);
                    signals.push(TradingSignal {
                        r#type:      "MACD".into(),
                        value:       macd.histogram,
                        description: if macd.histogram > 0.0 {
                            "bullish momentum"
                        } else {
                            "bearish momentum"
                        }.into(),
                    });
                }
                Err(e) => warn!(error = %e, "MACD failed"),
            }
        }

        info!(symbol = %req.symbol, indicators = values.len(), "signals extracted");
        Ok(Response::new(SignalResponse { values, signals }))
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────
fn analyze_event(
    event: &crate::ingestion::v1::MarketEvent,
) -> (Signal, HashMap<String, f64>) {
    let mut indicators = HashMap::new();

    let (direction, strength, reason): (Direction, f64, String) = match &event.data {
        Some(EventData::Price(price)) => {
            let change_pct = if price.open != 0.0 {
                (price.close - price.open) / price.open * 100.0
            } else {
                0.0
            };
            indicators.insert("price_change_pct".into(), change_pct);
            indicators.insert("volume".into(),           price.volume);
            indicators.insert("close".into(),            price.close);

            if change_pct > 0.5 {
                (Direction::Bullish, (change_pct / 5.0).min(1.0), "positive price movement".into())
            } else if change_pct < -0.5 {
                (Direction::Bearish, (change_pct.abs() / 5.0).min(1.0), "negative price movement".into())
            } else {
                (Direction::Neutral, 0.1, "minimal price movement".into())
            }
        }
        Some(EventData::News(_)) => (
            Direction::Neutral, 0.0,
            "news event — sentiment analysis not yet implemented".into(),
        ),
        Some(EventData::Book(book)) => {
            let bid_vol: f64 = book.bids.iter().map(|l| l.quantity).sum();
            let ask_vol: f64 = book.asks.iter().map(|l| l.quantity).sum();
            let total     = bid_vol + ask_vol;
            let imbalance = if total > 0.0 { (bid_vol - ask_vol) / total } else { 0.0 };
            indicators.insert("order_book_imbalance".into(), imbalance);
            if imbalance > 0.2 {
                (Direction::Bullish, imbalance.min(1.0), "buy-side order book imbalance".into())
            } else if imbalance < -0.2 {
                (Direction::Bearish, imbalance.abs().min(1.0), "sell-side order book imbalance".into())
            } else {
                (Direction::Neutral, 0.1, "balanced order book".into())
            }
        }
        None => (Direction::Unknown, 0.0, "no event data".into()),
    };

    (
        Signal { direction: direction as i32, strength, confidence: 0.5, reason },
        indicators,
    )
}

fn default_risk_metrics() -> RiskMetrics {
    RiskMetrics { volatility_24h: 0.0, max_drawdown: 0.0, sharpe_ratio: 0.0, var_95: 0.0 }
}

fn now_timestamp() -> prost_types::Timestamp {
    let dur = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    prost_types::Timestamp {
        seconds: dur.as_secs() as i64,
        nanos:   dur.subsec_nanos() as i32,
    }
}

fn rsi_description(rsi: f64) -> &'static str {
    if rsi < 30.0      { "oversold — potential buy signal" }
    else if rsi > 70.0 { "overbought — potential sell signal" }
    else               { "neutral" }
}
