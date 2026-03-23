package postgres

import (
    "context"
    "fmt"
    "log/slog"

    "github.com/jackc/pgx/v5/pgxpool"
)

type Client struct {
    pool *pgxpool.Pool
}

func NewClient(ctx context.Context, connString string) (*Client, error) {
    pool, err := pgxpool.New(ctx, connString)
    if err != nil {
        return nil, fmt.Errorf("failed to create pool: %w", err)
    }
    if err := pool.Ping(ctx); err != nil {
        return nil, fmt.Errorf("ping failed: %w", err)
    }
    slog.Info("PostgreSQL connected")
    return &Client{pool: pool}, nil
}

func (c *Client) Close() {
    c.pool.Close()
}

func (c *Client) Pool() *pgxpool.Pool {
    return c.pool
}
