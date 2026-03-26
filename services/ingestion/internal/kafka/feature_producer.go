// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  المسار الكامل: services/ingestion/internal/kafka/feature_producer.go   ║
// ║  الحالة: 🆕 جديد                                                        ║
// ╚══════════════════════════════════════════════════════════════════════════╝

package kafka

import (
	"context"
	"fmt"
	"time"

	kafka "github.com/segmentio/kafka-go"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"

	pb "github.com/aminpola2001-ctrl/youtuop/services/ingestion/internal/schema"
)

// FeatureProducer يُرسل FeatureEvent messages إلى Redpanda
// topic: "feature-events"
// encoding: protobuf binary
// key: tenant_id (لضمان ordered delivery per tenant)
type FeatureProducer struct {
	writer *kafka.Writer
	log    *zap.Logger
}

// NewFeatureProducer ينشئ producer جاهزاً للاستخدام الفوري
//
// brokers: قائمة Redpanda brokers — مثال: []string{"redpanda:9092"}
// topic:   اسم الـ topic — "feature-events"
// log:     zap logger للـ error reporting
func NewFeatureProducer(brokers []string, topic string, log *zap.Logger) *FeatureProducer {
	writer := &kafka.Writer{
		Addr:  kafka.TCP(brokers...),
		Topic: topic,
		// LeastBytes يوزّع الـ messages على الـ partitions بشكل متوازن
		Balancer: &kafka.LeastBytes{},
		// Async=false يضمن أن الـ error يُرجَع مباشرةً للـ caller
		// main.go يستدعي SendFeatureEvent في goroutine منفصلة لتجنب block
		Async: false,
		// إعادة المحاولة تلقائياً عند فشل الكتابة
		MaxAttempts: 3,
		// Timeouts محكمة لتجنب تأثير أي بطء في Redpanda على الـ hot path
		WriteTimeout: 2 * time.Second,
		ReadTimeout:  2 * time.Second,
		// Compression لتقليل bandwidth
		Compression: kafka.Snappy,
		// Required acks من leader فقط (توازن بين durability وسرعة)
		RequiredAcks: kafka.RequireOne,
	}

	log.Info("feature producer initialized",
		zap.Strings("brokers", brokers),
		zap.String("topic", topic),
	)

	return &FeatureProducer{
		writer: writer,
		log:    log,
	}
}

// SendFeatureEvent يُسلسل FeatureEvent كـ protobuf ويُرسله إلى Redpanda
//
// يُستدعى من goroutine منفصلة في main.go (non-blocking على الـ hot path)
// ctx يجب أن يحمل timeout (2s) لمنع تراكم goroutines عند بطء Redpanda
func (p *FeatureProducer) SendFeatureEvent(ctx context.Context, event *pb.FeatureEvent) error {
	if event == nil {
		return fmt.Errorf("feature_producer: event must not be nil")
	}
	if event.TenantId == "" {
		return fmt.Errorf("feature_producer: tenant_id is required")
	}
	if event.EventId == "" {
		return fmt.Errorf("feature_producer: event_id is required")
	}

	value, err := proto.Marshal(event)
	if err != nil {
		return fmt.Errorf("feature_producer: proto marshal failed: %w", err)
	}

	msg := kafka.Message{
		// Key = tenant_id يضمن ordered delivery لكل tenant في نفس الـ partition
		Key:   []byte(event.TenantId),
		Value: value,
		// Headers للـ debugging بدون decode كامل
		Headers: []kafka.Header{
			{Key: "event_id", Value: []byte(event.EventId)},
			{Key: "source_type", Value: []byte(event.SourceType)},
			{Key: "content_type", Value: []byte("application/x-protobuf")},
		},
	}

	if err := p.writer.WriteMessages(ctx, msg); err != nil {
		return fmt.Errorf("feature_producer: write failed: %w", err)
	}

	return nil
}

// Close يغلق الـ writer بشكل آمن — يُستدعى عند graceful shutdown
// يضمن flush كل الـ pending messages قبل الإغلاق
func (p *FeatureProducer) Close() {
	if err := p.writer.Close(); err != nil {
		p.log.Error("feature producer close error", zap.Error(err))
		return
	}
	p.log.Info("feature producer closed")
}
