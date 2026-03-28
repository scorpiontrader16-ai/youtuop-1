package evaluator

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/scorpiontrader16-ai/youtuop-1/services/feature-flags/internal/postgres"
)

const cacheTTL = 30 * time.Second

// Engine يدير الـ feature flag evaluation مع Redis cache
// الـ TTL قصير عشان الـ flags تتحدث بسرعة بعد التغيير
type Engine struct {
	db    *postgres.Client
	redis *redis.Client
}

func NewEngine(db *postgres.Client, rdb *redis.Client) *Engine {
	return &Engine{db: db, redis: rdb}
}

// GetAll يجيب كل الـ flags لـ context معين مع cache
func (e *Engine) GetAll(ctx context.Context, tenantID, plan string) (map[string]json.RawMessage, error) {
	cacheKey := fmt.Sprintf("ff:ctx:%s:%s", tenantID, plan)

	// Redis cache
	if cached, err := e.redis.Get(ctx, cacheKey).Bytes(); err == nil {
		var result map[string]json.RawMessage
		if json.Unmarshal(cached, &result) == nil {
			return result, nil
		}
	}

	// DB fallback
	results, err := e.db.GetFlagsForContext(ctx, tenantID, plan)
	if err != nil {
		return nil, err
	}

	flagMap := make(map[string]json.RawMessage, len(results))
	for _, r := range results {
		flagMap[r.Key] = r.Value
	}

	// Cache it
	if data, err := json.Marshal(flagMap); err == nil {
		e.redis.Set(ctx, cacheKey, data, cacheTTL) //nolint:errcheck
	}

	return flagMap, nil
}

// Evaluate يقيّم flag واحد
func (e *Engine) Evaluate(ctx context.Context, key, tenantID, plan, userID string) (*postgres.EvalResult, error) {
	cacheKey := fmt.Sprintf("ff:single:%s:%s:%s", key, tenantID, plan)

	// Redis cache للـ single flag
	if cached, err := e.redis.Get(ctx, cacheKey).Bytes(); err == nil {
		var r postgres.EvalResult
		if json.Unmarshal(cached, &r) == nil {
			return &r, nil
		}
	}

	result, err := e.db.EvaluateFlag(ctx, key, tenantID, plan)
	if err != nil {
		return nil, err
	}

	// Cache it
	if data, err := json.Marshal(result); err == nil {
		e.redis.Set(ctx, cacheKey, data, cacheTTL) //nolint:errcheck
	}

	// Log evaluation بشكل async (1 من كل 100 requests)
	go func() {
		e.db.LogEvaluation(context.Background(), key, tenantID, userID, result.Reason, result.Value)
	}()

	return result, nil
}

// InvalidateContext يمسح الـ cache لما flag تتغير
func (e *Engine) InvalidateContext(ctx context.Context, tenantID, plan string) {
	pattern := fmt.Sprintf("ff:ctx:%s:%s", tenantID, plan)
	e.redis.Del(ctx, pattern) //nolint:errcheck
}

// InvalidateAll يمسح كل الـ flags cache (بعد global flag update)
func (e *Engine) InvalidateAll(ctx context.Context) {
	keys, err := e.redis.Keys(ctx, "ff:*").Result()
	if err != nil || len(keys) == 0 {
		return
	}
	e.redis.Del(ctx, keys...) //nolint:errcheck
}
