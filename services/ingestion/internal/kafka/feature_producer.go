// ╔══════════════════════════════════════════════════════════════════╗
// ║  Full path: services/ingestion/internal/kafka/feature_producer.go ║
// ║  Migrated: segmentio/kafka-go → twmb/franz-go                   ║
// ╚══════════════════════════════════════════════════════════════════╝

package kafka

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/twmb/franz-go/pkg/kgo"
	"go.uber.org/zap"
)

// ── Prometheus Metrics ────────────────────────────────────────────────────

var (
	featureEventsPublishedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ingestion_feature_events_published_total",
		Help: "Total number of feature events successfully published to Redpanda",
	})

	featureEventsFailedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "ingestion_feature_events_failed_total",
		Help: "Total number of feature events that failed to publish",
	})

	featurePublishDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "ingestion_feature_publish_duration_seconds",
		Help:    "Duration of feature event publish operations",
		Buckets: []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0},
	})
)

// ── FeatureProducer ───────────────────────────────────────────────────────

// FeatureProducer يُرسل FeatureEvent messages إلى Redpanda
//
// topic:    "feature-events"
// encoding: JSON
// key:      tenant_id — يضمن ordered delivery per tenant
// acks:     LeaderEpoch — at-least-once delivery
// compress: Snappy — سريع مع ضغط جيد
type FeatureProducer struct {
	client *kgo.Client
	topic  string
	log    *zap.Logger
}

// NewFeatureProducer ينشئ producer جاهزاً للاستخدام الفوري
//
//	brokers: قائمة Redpanda brokers — []string{"redpanda:9092"}
//	topic:   "feature-events"
//	log:     zap structured logger
func NewFeatureProducer(brokers []string, topic string, log *zap.Logger) (*FeatureProducer, error) {
	client, err := kgo.NewClient(
		kgo.SeedBrokers(brokers...),
		kgo.DefaultProduceTopic(topic),
		kgo.RequiredAcks(kgo.LeaderAck()),
		kgo.ProducerBatchCompression(kgo.SnappyCompression()),
		kgo.RecordRetries(3),
		kgo.ProduceRequestTimeout(2*time.Second),
	)
	if err != nil {
		return nil, fmt.Errorf("feature_producer: failed to create client: %w", err)
	}

	log.Info("feature producer initialized",
		zap.Strings("brokers", brokers),
		zap.String("topic", topic),
	)

	return &FeatureProducer{
		client: client,
		topic:  topic,
		log:    log,
	}, nil
}

// SendFeatureEvent يُسلسل FeatureEvent كـ JSON ويُرسله إلى Redpanda
func (p *FeatureProducer) SendFeatureEvent(ctx context.Context, event *FeatureEvent) error {
	if event == nil {
		return fmt.Errorf("feature_producer: event must not be nil")
	}
	if event.TenantID == "" {
		return fmt.Errorf("feature_producer: tenant_id is required")
	}
	if event.EventID == "" {
		return fmt.Errorf("feature_producer: event_id is required")
	}

	start := time.Now()

	value, err := json.Marshal(event)
	if err != nil {
		featureEventsFailedTotal.Inc()
		return fmt.Errorf("feature_producer: json marshal failed: %w", err)
	}

	record := &kgo.Record{
		Topic: p.topic,
		Key:   []byte(event.TenantID),
		Value: value,
		Headers: []kgo.RecordHeader{
			{Key: "event_id", Value: []byte(event.EventID)},
			{Key: "source_type", Value: []byte(event.SourceType)},
			{Key: "content_type", Value: []byte("application/json")},
		},
	}

	if err := p.client.ProduceSync(ctx, record).FirstErr(); err != nil {
		featureEventsFailedTotal.Inc()
		return fmt.Errorf("feature_producer: write failed: %w", err)
	}

	featureEventsPublishedTotal.Inc()
	featurePublishDuration.Observe(time.Since(start).Seconds())

	return nil
}

// Close يغلق الـ client بشكل آمن — يُستدعى عند graceful shutdown.
func (p *FeatureProducer) Close() {
	p.client.Close()
	p.log.Info("feature producer closed")
}
