// Package store provides the item data sources: in-memory for CI, PostgreSQL in AWS.
package store

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Item is a single record returned by the API.
type Item struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// Store lists items.
type Store interface {
	ListItems(ctx context.Context) ([]Item, error)
}

// Memory serves fixed sample data.
type Memory struct{ items []Item }

// NewMemory returns a store with sample data.
func NewMemory() *Memory {
	return &Memory{items: []Item{{ID: 1, Name: "alpha"}, {ID: 2, Name: "beta"}}}
}

// ListItems returns the sample data.
func (m *Memory) ListItems(context.Context) ([]Item, error) {
	return m.items, nil
}

// Postgres reads items from RDS.
type Postgres struct{ pool *pgxpool.Pool }

// NewPostgres returns a store backed by the given pool.
func NewPostgres(pool *pgxpool.Pool) *Postgres {
	return &Postgres{pool: pool}
}

// ListItems returns up to 100 items. The query is static and parameter-free.
func (p *Postgres) ListItems(ctx context.Context) ([]Item, error) {
	rows, err := p.pool.Query(ctx, "SELECT id, name FROM items ORDER BY id LIMIT 100")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := []Item{}
	for rows.Next() {
		var it Item
		if err := rows.Scan(&it.ID, &it.Name); err != nil {
			return nil, err
		}
		items = append(items, it)
	}
	return items, rows.Err()
}
