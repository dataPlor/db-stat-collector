package collector

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Snapshot is a single point-in-time sample of Postgres + host statistics.
// Counter-style fields are cumulative; the publisher turns consecutive
// snapshots into rates.
type Snapshot struct {
	Timestamp time.Time

	// pg_stat_database counters (summed across all databases)
	XactCommit   int64
	XactRollback int64
	BlksRead     int64
	BlksHit      int64
	Deadlocks    int64

	// pg_stat_activity gauges
	ConnActive       int
	ConnIdle         int
	ConnIdleInTxn    int
	ConnTotal        int
	ConnWaitingLocks int
	LongestQuerySec  float64
	LongestXactSec   float64

	// Host stats from /proc
	CPUTotalJiffies uint64  // sum of all cpu-time fields on the cpu line
	CPUIdleJiffies  uint64  // idle + iowait
	Load1           float64 // 1-minute load average
	Load5           float64
	Load15          float64
	MemUsedPercent  float64 // 100 * (1 - MemAvailable/MemTotal)
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
			COALESCE(sum(deadlocks), 0)
		FROM pg_stat_database
		WHERE datname IS NOT NULL
	`).Scan(&s.XactCommit, &s.XactRollback, &s.BlksRead, &s.BlksHit, &s.Deadlocks)
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

	// Host metrics — don't fail the whole collection if these error, just
	// leave zero values.
	if total, idle, err := readCPUStat(); err == nil {
		s.CPUTotalJiffies = total
		s.CPUIdleJiffies = idle
	}
	if l1, l5, l15, err := readLoadAvg(); err == nil {
		s.Load1, s.Load5, s.Load15 = l1, l5, l15
	}
	if mem, err := readMemUsedPercent(); err == nil {
		s.MemUsedPercent = mem
	}

	return s, nil
}

// readCPUStat returns (totalJiffies, idle+iowaitJiffies) from /proc/stat.
// The publisher computes utilization as 1 - idleDelta/totalDelta.
func readCPUStat() (uint64, uint64, error) {
	b, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, 0, err
	}
	sc := bufio.NewScanner(bytes.NewReader(b))
	if !sc.Scan() {
		return 0, 0, fmt.Errorf("empty /proc/stat")
	}
	fields := strings.Fields(sc.Text())
	if len(fields) < 5 || fields[0] != "cpu" {
		return 0, 0, fmt.Errorf("unexpected /proc/stat: %q", sc.Text())
	}
	var total uint64
	for _, f := range fields[1:] {
		v, _ := strconv.ParseUint(f, 10, 64)
		total += v
	}
	idle, _ := strconv.ParseUint(fields[4], 10, 64)
	var iowait uint64
	if len(fields) > 5 {
		iowait, _ = strconv.ParseUint(fields[5], 10, 64)
	}
	return total, idle + iowait, nil
}

func readLoadAvg() (float64, float64, float64, error) {
	b, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0, 0, 0, err
	}
	f := strings.Fields(string(b))
	if len(f) < 3 {
		return 0, 0, 0, fmt.Errorf("unexpected /proc/loadavg: %q", string(b))
	}
	l1, _ := strconv.ParseFloat(f[0], 64)
	l5, _ := strconv.ParseFloat(f[1], 64)
	l15, _ := strconv.ParseFloat(f[2], 64)
	return l1, l5, l15, nil
}

func readMemUsedPercent() (float64, error) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0, err
	}
	defer f.Close()

	var total, available uint64
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "MemTotal:"):
			fmt.Sscanf(line, "MemTotal: %d kB", &total)
		case strings.HasPrefix(line, "MemAvailable:"):
			fmt.Sscanf(line, "MemAvailable: %d kB", &available)
		}
	}
	if total == 0 {
		return 0, fmt.Errorf("MemTotal not found in /proc/meminfo")
	}
	return 100.0 * (1.0 - float64(available)/float64(total)), nil
}
