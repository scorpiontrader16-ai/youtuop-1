//! gRPC server — ProcessingEngineService with Rate Limiting + Metrics

use std::collections::HashMap;
use std::num::NonZeroU32;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Instant;

use futures::Stream;
use governor::{Quota, RateLimiter};
use governor::clock::DefaultClock;
use governor::state::{InMemoryState, NotKeyed};
use metrics::{counter, histogram};
use tokio::sync::mpsc;
use tokio_stream::{wrappers::ReceiverStream, StreamExt as _};
use tonic::{Request, Response, Status, Streaming};
use tracing::{info, instrument, warn};

use crate::engine::{CorrelationEngine, SignalEngine};
use crate::events::v1::BaseEvent;

pub mod processing_v1 {
    tonic::include_proto!("processing.v1");
    pub const FILE_DESCRIPTOR_SET: &[u8] =
        tonic::include_file_descriptor_set!("processing_descriptor");
}

use processing_v1::{
    processing_engine_service_server::{
        ProcessingEngineService, ProcessingEngineServiceServer,
    },
    signal::Direction,
    CorrelationRequest, CorrelationResponse, ProcessEventRequest, ProcessEventResponse,
    RiskMetrics, Signal, SignalRequest, SignalResponse, TradingSignal,
};

// ── Rate limiter type alias ───────────────────────────────────────────────
type DirectRateLimiter = RateLimiter<NotKeyed, InMemoryState, DefaultClock>;

// ── Service struct ────────────────────────────────────────────────────────
pub struct Engine {
    signal:       SignalEngine,
    #[allow(dead_code)]
    correlation:  CorrelationEngine,
    rate_limiter: Arc<DirectRateLimiter>,
}

impl Engine {
    pub fn new() -> Self {
        let quota = Quota::per_second(NonZeroU32::new(500).unwrap());
        Self {
            signal:       SignalEngine::new(),
            correlation:  CorrelationEngine::new(),
            rate_limiter: Arc::new(RateLimiter::direct(quota)),
        }
    }

    pub fn into_server(self) -> ProcessingEngineServiceServer<Self> {
        ProcessingEngineServiceServer::new(self)
    }

    fn check_rate_limit(&self, method: &str) -> Result<(), Status> {
        match self.rate_limiter.check() {
            Ok(_)  => Ok(()),
            Err(_) => {
                warn!(method, "gRPC rate limit exceeded");
                counter!("processing_grpc_requests_total",
                    "method" => method.to_string(),
                    "status" => "rate_limited"
                ).increment(1);
                Err(Status::resource_exhausted("rate limit exceeded, try again later"))
            }
        }
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
        self.check_rate_limit("process_event")?;

        let start = Instant::now();
        let req   = request.into_inner();

        let event = req.event.ok_or_else(|| {
            counter!("processing_grpc_requests_total",
                "method" => "process_event", "status" => "invalid_argument"
            ).increment(1);
            Status::invalid_argument("event is required")
        })?;

        let (signal, indicators) = analyze_event(&event);
        let elapsed              = start.elapsed();
        let processing_us        = elapsed.as_micros() as f64;

        histogram!("processing_grpc_request_duration_seconds",
            "method" => "process_event"
        ).record(elapsed.as_secs_f64());

        counter!("processing_grpc_requests_total",
            "method" => "process_event", "status" => "ok"
        ).increment(1);

        counter!("processing_events_processed_total",
            "event_type" => event.event_type.clone()
        ).increment(1);

        info!(
            event_id   = %event.event_id,
            event_type = %event.event_type,
            source     = %event.source,
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
        self.check_rate_limit("process_stream")?;

        let mut inbound = request.into_inner();
        let (tx, rx)    = mpsc::channel::<Result<ProcessEventResponse, Status>>(32);

        tokio::spawn(async move {
            while let Some(result) = inbound.next().await {
                let response = match result {
                    Err(e) => Err(Status::internal(e.to_string())),
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
                if tx.send(response).await.is_err() { break; }
            }
        });

        Ok(Response::new(Box::pin(ReceiverStream::new(rx))))
    }

    async fn compute_correlation(
        &self,
        request: Request<CorrelationRequest>,
    ) -> Result<Response<CorrelationResponse>, Status> {
        self.check_rate_limit("compute_correlation")?;

        let req = request.into_inner();

        if req.symbol_a.is_empty() || req.symbol_b.is_empty() {
            counter!("processing_grpc_requests_total",
                "method" => "compute_correlation", "status" => "invalid_argument"
            ).increment(1);
            return Err(Status::invalid_argument("symbol_a and symbol_b are required"));
        }
        if req.lookback_days <= 0 {
            counter!("processing_grpc_requests_total",
                "method" => "compute_correlation", "status" => "invalid_argument"
            ).increment(1);
            return Err(Status::invalid_argument("lookback_days must be positive"));
        }

        counter!("processing_grpc_requests_total",
            "method" => "compute_correlation", "status" => "ok"
        ).increment(1);

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
        self.check_rate_limit("extract_signals")?;

        let req = request.into_inner();

        if req.symbol.is_empty() {
            counter!("processing_grpc_requests_total",
                "method" => "extract_signals", "status" => "invalid_argument"
            ).increment(1);
            return Err(Status::invalid_argument("symbol is required"));
        }
        if req.prices.len() < 2 {
            counter!("processing_grpc_requests_total",
                "method" => "extract_signals", "status" => "invalid_argument"
            ).increment(1);
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

        counter!("processing_grpc_requests_total",
            "method" => "extract_signals", "status" => "ok"
        ).increment(1);

        info!(symbol = %req.symbol, indicators = values.len(), "signals extracted");
        Ok(Response::new(SignalResponse { values, signals }))
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────

/// analyze_event — يحلل BaseEvent ويرجع Signal + indicators
/// يستخدم event_type وcontent_type من الـ envelope
fn analyze_event(event: &BaseEvent) -> (Signal, HashMap<String, f64>) {
    let mut indicators = HashMap::new();

    indicators.insert("schema_version".into(), {
        // نحول الـ schema_version لـ float للتتبع (مثلاً "1.0.0" → 100.0)
        event.schema_version
            .split('.')
            .next()
            .and_then(|v| v.parse::<f64>().ok())
            .unwrap_or(0.0)
    });

    // نستخدم event_type لتحديد الاتجاه
    let event_type = event.event_type.to_lowercase();

    let (direction, strength, reason) = if event_type.contains("buy")
        || event_type.contains("bullish")
        || event_type.contains("up")
    {
        (Direction::Bullish, 0.7, format!("event_type indicates bullish: {}", event.event_type))
    } else if event_type.contains("sell")
        || event_type.contains("bearish")
        || event_type.contains("down")
    {
        (Direction::Bearish, 0.7, format!("event_type indicates bearish: {}", event.event_type))
    } else {
        (Direction::Neutral, 0.1, format!("neutral event_type: {}", event.event_type))
    };

    // أضف metadata values كـ indicators لو موجودة
    if let Some(meta) = &event.metadata {
        for (k, v) in &meta.fields {
            if let Some(prost_types::value::Kind::NumberValue(n)) = &v.kind {
                indicators.insert(k.clone(), *n);
            }
        }
    }

    (
        Signal {
            direction:  direction as i32,
            strength,
            confidence: 0.5,
            reason,
        },
        indicators,
    )
}

fn default_risk_metrics() -> RiskMetrics {
    RiskMetrics {
        volatility_24h: 0.0,
        max_drawdown:   0.0,
        sharpe_ratio:   0.0,
        var_95:         0.0,
    }
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
