package collector

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Snapshot is a single point-in-time sample of Postgres statistics.
// Counter-style fields are cumulative since the stats were last reset;
// the publisher turns consecutive snapshots into rates.
type Snapshot struct {
	Timestamp time.Time

	// pg_stat_database counters (summed across all databases)
	XactCommit   int64
	XactRollback int64
	BlksRead     int64
	BlksHit      int64
	TupReturned  int64
	TupFetched   int64
	TupInserted  int64
	TupUpdated   int64
	TupDeleted   int64
	Conflicts    int64
	Deadlocks    int64
	TempFiles    int64
	TempBytes    int64

	// pg_stat_activity gauges (client backends only)
	ConnActive       int
	ConnIdle         int
	ConnIdleInTxn    int
	ConnTotal        int
	ConnWaitingLocks int
	LongestQuerySec  float64
	LongestXactSec   float64
}

type Collector struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Collector {
	return &Collector{pool: pool}
}

func (c *Collector) Collect(ctx context.Context) (Snapshot, error) {
	var s Snapshot
	s.Timestamp = time.Now().UTC()

	err := c.pool.QueryRow(ctx, `
		SELECT
			COALESCE(sum(xact_commit), 0),
			COALESCE(sum(xact_rollback), 0),
			COALESCE(sum(blks_read), 0),
			COALESCE(sum(blks_hit), 0),
			COALESCE(sum(tup_returned), 0),
			COALESCE(sum(tup_fetched), 0),
			COALESCE(sum(tup_inserted), 0),
			COALESCE(sum(tup_updated), 0),
			COALESCE(sum(tup_deleted), 0),
			COALESCE(sum(conflicts), 0),
			COALESCE(sum(deadlocks), 0),
			COALESCE(sum(temp_files), 0),
			COALESCE(sum(temp_bytes), 0)
		FROM pg_stat_database
		WHERE datname IS NOT NULL
	`).Scan(
		&s.XactCommit, &s.XactRollback, &s.BlksRead, &s.BlksHit,
		&s.TupReturned, &s.TupFetched, &s.TupInserted, &s.TupUpdated,
		&s.TupDeleted, &s.Conflicts, &s.Deadlocks, &s.TempFiles, &s.TempBytes,
	)
	if err != nil {
		return Snapshot{}, fmt.Errorf("querying pg_stat_database: %w", err)
	}

	// CASE WHEN rather than FILTER so the query works on poolers and older
	// servers that don't parse the SQL:2003 FILTER clause.
	err = c.pool.QueryRow(ctx, `
		SELECT
			COALESCE(SUM(CASE WHEN state = 'active' THEN 1 ELSE 0 END), 0)::int,
			COALESCE(SUM(CASE WHEN state = 'idle'   THEN 1 ELSE 0 END), 0)::int,
			COALESCE(SUM(CASE WHEN state IN ('idle in transaction', 'idle in transaction (aborted)') THEN 1 ELSE 0 END), 0)::int,
			COUNT(*)::int,
			COALESCE(SUM(CASE WHEN wait_event_type = 'Lock' THEN 1 ELSE 0 END), 0)::int,
			COALESCE(EXTRACT(EPOCH FROM MAX(CASE WHEN state = 'active' THEN clock_timestamp() - query_start END)), 0)::float8,
			COALESCE(EXTRACT(EPOCH FROM MAX(clock_timestamp() - xact_start)), 0)::float8
		FROM pg_stat_activity
		WHERE pid <> pg_backend_pid()
	`).Scan(
		&s.ConnActive, &s.ConnIdle, &s.ConnIdleInTxn, &s.ConnTotal,
		&s.ConnWaitingLocks, &s.LongestQuerySec, &s.LongestXactSec,
	)
	if err != nil {
		return Snapshot{}, fmt.Errorf("querying pg_stat_activity: %w", err)
	}

	return s, nil
}
