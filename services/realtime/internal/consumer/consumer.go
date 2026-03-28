package consumer

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
	"go.uber.org/zap"

	"github.com/scorpiontrader16-ai/youtuop-1/services/realtime/internal/hub"
)

// Config لـ Redpanda consumer
type Config struct {
	Brokers       []string
	Topics        []string
	ConsumerGroup string
}

func ConfigFromEnv() Config {
	brokersRaw := getEnv("REDPANDA_BROKERS", "redpanda:9092")
	return Config{
		Brokers: strings.Split(brokersRaw, ","),
		Topics: []string{
			"platform.events.processed",
			"platform.alerts.triggered",
			"platform.agents.completed",
		},
		ConsumerGroup: "realtime-delivery",
	}
}

// Event الـ structure اللي بتيجي من الـ topics
type Event struct {
	EventID    string          `json:"event_id"`
	EventType  string          `json:"event_type"`
	TenantID   string          `json:"tenant_id"`
	Source     string          `json:"source"`
	Payload    json.RawMessage `json:"payload"`
	OccurredAt time.Time       `json:"occurred_at"`
}

// Consumer يستهلك من Redpanda ويوصّل للـ Hub
type Consumer struct {
	client *kgo.Client
	hub    *hub.Hub
	log    *zap.Logger
}

func New(cfg Config, h *hub.Hub, log *zap.Logger) (*Consumer, error) {
	opts := []kgo.Opt{
		kgo.SeedBrokers(cfg.Brokers...),
		kgo.ConsumerGroup(cfg.ConsumerGroup),
		kgo.ConsumeTopics(cfg.Topics...),
		kgo.DisableAutoCommit(),
		kgo.FetchMaxBytes(10 * 1024 * 1024),
		kgo.FetchMaxWait(500 * time.Millisecond),
	}

	client, err := kgo.NewClient(opts...)
	if err != nil {
		return nil, fmt.Errorf("create kafka client: %w", err)
	}

	return &Consumer{client: client, hub: h, log: log}, nil
}

// Run يشغّل الـ consumer loop حتى يتوقف الـ context
func (c *Consumer) Run(ctx context.Context) {
	c.log.Info("redpanda consumer started")
	defer c.client.Close()

	for {
		select {
		case <-ctx.Done():
			c.log.Info("redpanda consumer stopping")
			return
		default:
		}

		fetches := c.client.PollFetches(ctx)
		if errs := fetches.Errors(); len(errs) > 0 {
			for _, e := range errs {
				c.log.Error("fetch error",
					zap.String("topic", e.Topic),
					zap.Error(e.Err),
				)
			}
			continue
		}

		fetches.EachRecord(func(record *kgo.Record) {
			if err := c.processRecord(record); err != nil {
				c.log.Error("process record failed",
					zap.String("topic", record.Topic),
					zap.Error(err),
				)
			}
		})

		if err := c.client.CommitUncommittedOffsets(ctx); err != nil {
			c.log.Warn("commit offsets failed", zap.Error(err))
		}
	}
}

func (c *Consumer) processRecord(record *kgo.Record) error {
	var event Event
	if err := json.Unmarshal(record.Value, &event); err != nil {
		return fmt.Errorf("unmarshal event: %w", err)
	}
	if event.TenantID == "" {
		return nil
	}

	msg := &hub.Message{
		Type:      event.EventType,
		TenantID:  event.TenantID,
		Channel:   mapToChannel(event.EventType),
		Payload:   event.Payload,
		Timestamp: event.OccurredAt,
	}
	c.hub.Broadcast(msg)
	return nil
}

func mapToChannel(eventType string) string {
	switch {
	case strings.HasPrefix(eventType, "market."):
		return "markets"
	case strings.HasPrefix(eventType, "alert."):
		return "alerts"
	case strings.HasPrefix(eventType, "agent."):
		return "agents"
	default:
		return "system"
	}
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
