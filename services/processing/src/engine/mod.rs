#![allow(dead_code)]
use thiserror::Error;
use tracing::{debug, instrument};

#[derive(Debug, Error)]
pub enum EngineError {
    #[error("insufficient data: need {required} points, got {got}")]
    InsufficientData { required: usize, got: usize },

    #[error("invalid symbol: {0}")]
    InvalidSymbol(String),

    #[error("computation error: {0}")]
    Computation(String),
}

// ─── Correlation Engine ──────────────────────────────────────
pub struct CorrelationEngine {
    min_periods: usize,
}

impl CorrelationEngine {
    pub fn new() -> Self {
        Self { min_periods: 30 }
    }

    #[instrument(skip(self, series_a, series_b))]
    pub fn pearson_correlation(
        &self,
        series_a: &[f64],
        series_b: &[f64],
    ) -> Result<CorrelationResult, EngineError> {
        if series_a.len() != series_b.len() {
            return Err(EngineError::Computation("series must have equal length".into()));
        }
        if series_a.len() < self.min_periods {
            return Err(EngineError::InsufficientData {
                required: self.min_periods,
                got: series_a.len(),
            });
        }

        let n = series_a.len() as f64;
        let mean_a = series_a.iter().sum::<f64>() / n;
        let mean_b = series_b.iter().sum::<f64>() / n;

        let (cov, var_a, var_b) = series_a
            .iter()
            .zip(series_b.iter())
            .fold((0.0_f64, 0.0_f64, 0.0_f64), |(cov, va, vb), (a, b)| {
                let da = a - mean_a;
                let db = b - mean_b;
                (cov + da * db, va + da * da, vb + db * db)
            });

        let denominator = (var_a * var_b).sqrt();
        if denominator == 0.0 {
            return Err(EngineError::Computation("zero variance".into()));
        }

        let coefficient = cov / denominator;
        let t_stat = coefficient * ((n - 2.0) / (1.0 - coefficient.powi(2))).sqrt();
        let is_significant = t_stat.abs() > 1.96;

        debug!(coefficient, is_significant, "correlation computed");

        Ok(CorrelationResult {
            coefficient,
            is_significant,
            sample_size: series_a.len(),
        })
    }
}

impl Default for CorrelationEngine {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug)]
pub struct CorrelationResult {
    pub coefficient:    f64,
    pub is_significant: bool,
    pub sample_size:    usize,
}

// ─── Signal Engine ───────────────────────────────────────────
pub struct SignalEngine;

impl SignalEngine {
    pub fn new() -> Self { Self }

    #[instrument(skip(self, prices))]
    pub fn rsi(&self, prices: &[f64], period: usize) -> Result<f64, EngineError> {
        if prices.len() < period + 1 {
            return Err(EngineError::InsufficientData {
                required: period + 1,
                got: prices.len(),
            });
        }

        let changes: Vec<f64> = prices.windows(2).map(|w| w[1] - w[0]).collect();
        let recent = &changes[changes.len() - period..];

        let (gains_sum, losses_sum, gains_count, losses_count) =
            recent.iter().fold((0.0_f64, 0.0_f64, 0_usize, 0_usize), |(gs, ls, gc, lc), &x| {
                if x >= 0.0 { (gs + x, ls, gc + 1, lc) }
                else        { (gs, ls + x.abs(), gc, lc + 1) }
            });

        let avg_gain = if gains_count > 0  { gains_sum  / period as f64 } else { 0.0 };
        let avg_loss = if losses_count > 0 { losses_sum / period as f64 } else { 0.0 };

        if avg_loss == 0.0 {
            return Ok(100.0);
        }

        let rs = avg_gain / avg_loss;
        Ok(100.0 - (100.0 / (1.0 + rs)))
    }

    pub fn macd(
        &self,
        prices: &[f64],
        fast: usize,
        slow: usize,
        signal_period: usize,
    ) -> Result<MacdResult, EngineError> {
        if prices.len() < slow + signal_period {
            return Err(EngineError::InsufficientData {
                required: slow + signal_period,
                got: prices.len(),
            });
        }
        let ema_fast  = self.ema(prices, fast)?;
        let ema_slow  = self.ema(prices, slow)?;
        let macd_line = ema_fast - ema_slow;
        Ok(MacdResult {
            macd:      macd_line,
            signal:    macd_line * 0.2,
            histogram: macd_line * 0.8,
        })
    }

    fn ema(&self, prices: &[f64], period: usize) -> Result<f64, EngineError> {
        if prices.len() < period {
            return Err(EngineError::InsufficientData { required: period, got: prices.len() });
        }
        let k = 2.0 / (period as f64 + 1.0);
        let mut ema = prices[..period].iter().sum::<f64>() / period as f64;
        for price in &prices[period..] {
            ema = price * k + ema * (1.0 - k);
        }
        Ok(ema)
    }
}

impl Default for SignalEngine {
    fn default() -> Self { Self::new() }
}

#[derive(Debug)]
pub struct MacdResult {
    pub macd:      f64,
    pub signal:    f64,
    pub histogram: f64,
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn test_rsi_oversold() {
        let e = SignalEngine::new();
        let prices: Vec<f64> = (0..20).map(|i| 100.0 - i as f64).collect();
        let rsi = e.rsi(&prices, 14).expect("valid rsi");
        assert!(rsi < 30.0, "got {rsi}");
    }

    #[test]
    fn test_rsi_overbought() {
        let e = SignalEngine::new();
        let prices: Vec<f64> = (0..20).map(|i| 100.0 + i as f64).collect();
        let rsi = e.rsi(&prices, 14).expect("valid rsi");
        assert!(rsi > 70.0, "got {rsi}");
    }

    #[test]
    fn test_correlation_perfect() {
        let e = CorrelationEngine::new();
        let a: Vec<f64> = (0..50).map(|i| i as f64).collect();
        let b: Vec<f64> = (0..50).map(|i| i as f64 * 2.0 + 1.0).collect();
        let r = e.pearson_correlation(&a, &b).expect("valid");
        assert!((r.coefficient - 1.0).abs() < 1e-10);
    }

    #[test]
    fn test_insufficient_data_returns_error() {
        let e = CorrelationEngine::new();
        let a = vec![1.0, 2.0, 3.0];
        let b = vec![1.0, 2.0, 3.0];
        assert!(e.pearson_correlation(&a, &b).is_err());
    }
}
