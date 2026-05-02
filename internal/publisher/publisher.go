package publisher

import (
	"context"
	"log/slog"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"

	"db-stat-collector/internal/collector"
)

type Publisher struct {
	client     *cloudwatch.Client
	namespace  string
	dimensions []types.Dimension
	log        *slog.Logger
	prev       *collector.Snapshot
}

func New(client *cloudwatch.Client, namespace string, dims []types.Dimension, log *slog.Logger) *Publisher {
	return &Publisher{
		client:     client,
		namespace:  namespace,
		dimensions: dims,
		log:        log,
	}
}

func (p *Publisher) Publish(ctx context.Context, snap collector.Snapshot) error {
	data := p.buildMetricData(snap)
	prev := snap
	p.prev = &prev

	if len(data) == 0 {
		return nil
	}

	_, err := p.client.PutMetricData(ctx, &cloudwatch.PutMetricDataInput{
		Namespace:  aws.String(p.namespace),
		MetricData: data,
	})
	return err
}

func (p *Publisher) buildMetricData(snap collector.Snapshot) []types.MetricDatum {
	ts := snap.Timestamp
	var data []types.MetricDatum

	addWith := func(name string, value float64, unit types.StandardUnit, dims []types.Dimension) {
		data = append(data, types.MetricDatum{
			MetricName:        aws.String(name),
			Value:             aws.Float64(value),
			Unit:              unit,
			Timestamp:         aws.Time(ts),
			Dimensions:        dims,
		})
	}
	add := func(name string, value float64, unit types.StandardUnit) {
		addWith(name, value, unit, p.dimensions)
	}

	// Instantaneous gauges — always published.
	add("Connections.Active", float64(snap.ConnActive), types.StandardUnitCount)
	add("Connections.Idle", float64(snap.ConnIdle), types.StandardUnitCount)
	add("Connections.IdleInTransaction", float64(snap.ConnIdleInTxn), types.StandardUnitCount)
	add("Connections.Total", float64(snap.ConnTotal), types.StandardUnitCount)
	add("Connections.WaitingOnLock", float64(snap.ConnWaitingLocks), types.StandardUnitCount)
	add("LongestQuerySeconds", snap.LongestQuerySec, types.StandardUnitSeconds)
	add("LongestUserTransactionSeconds", snap.LongestUserXactSec, types.StandardUnitSeconds)
	add("LongestVacuumSeconds", snap.LongestVacuumSec, types.StandardUnitSeconds)

	// Counter-derived rates — need a previous snapshot.
	if p.prev == nil {
		return data
	}
	elapsed := snap.Timestamp.Sub(p.prev.Timestamp).Seconds()
	if elapsed <= 0 {
		return data
	}

	rate := func(cur, prev int64) float64 {
		delta := cur - prev
		if delta < 0 {
			// pg_stat_reset or counter wrap — skip this interval.
			return 0
		}
		return float64(delta) / elapsed
	}

	add("Commits", rate(snap.XactCommit, p.prev.XactCommit), types.StandardUnitCountSecond)
	add("Rollbacks", rate(snap.XactRollback, p.prev.XactRollback), types.StandardUnitCountSecond)
	add("Deadlocks", rate(snap.Deadlocks, p.prev.Deadlocks), types.StandardUnitCountSecond)

	// Cache hit ratio over the interval (not cumulative), so operators see
	// recent pressure rather than a slowly-moving lifetime average.
	hitDelta := snap.BlksHit - p.prev.BlksHit
	readDelta := snap.BlksRead - p.prev.BlksRead
	if total := hitDelta + readDelta; total > 0 && hitDelta >= 0 && readDelta >= 0 {
		add("CacheHitRatio", float64(hitDelta)/float64(total)*100.0, types.StandardUnitPercent)
	}

	// --- Host metrics ---

	// Load and memory are instantaneous gauges.
	add("System.LoadAverage.1m", snap.Load1, types.StandardUnitNone)
	add("System.LoadAverage.5m", snap.Load5, types.StandardUnitNone)
	add("System.LoadAverage.15m", snap.Load15, types.StandardUnitNone)
	add("System.Memory.UsedPercent", snap.MemUsedPercent, types.StandardUnitPercent)

	// CPU usage is derived from /proc/stat jiffy deltas. Skip if either
	// sample is missing (e.g. first tick or /proc read failed).
	if snap.CPUTotalJiffies > 0 && p.prev.CPUTotalJiffies > 0 &&
		snap.CPUTotalJiffies > p.prev.CPUTotalJiffies {
		totalDelta := snap.CPUTotalJiffies - p.prev.CPUTotalJiffies
		idleDelta := snap.CPUIdleJiffies - p.prev.CPUIdleJiffies
		if idleDelta <= totalDelta {
			used := 100.0 * (1.0 - float64(idleDelta)/float64(totalDelta))
			add("System.CPU.UsedPercent", used, types.StandardUnitPercent)
		}
	}

	// Per-query-signature counts of active backends.
	for _, q := range snap.ActiveQueries {
		dims := make([]types.Dimension, 0, len(p.dimensions)+1)
		dims = append(dims, p.dimensions...)
		dims = append(dims, types.Dimension{
			Name:  aws.String("Query"),
			Value: aws.String(q.Signature),
		})
		addWith("ActiveQueries.Count", float64(q.Count), types.StandardUnitCount, dims)
	}

	// Per-wait-event counts of active backends. Bucket is "<type>:<event>"
	// or "CPU".
	for _, w := range snap.WaitEvents {
		dims := make([]types.Dimension, 0, len(p.dimensions)+1)
		dims = append(dims, p.dimensions...)
		dims = append(dims, types.Dimension{
			Name:  aws.String("WaitEvent"),
			Value: aws.String(w.Event),
		})
		addWith("WaitEvents.Count", float64(w.Count), types.StandardUnitCount, dims)
	}

	// Per-tablespace metrics get an extra Tablespace dimension.
	for _, tsp := range snap.Tablespaces {
		dims := make([]types.Dimension, 0, len(p.dimensions)+1)
		dims = append(dims, p.dimensions...)
		dims = append(dims, types.Dimension{
			Name:  aws.String("Tablespace"),
			Value: aws.String(tsp.Name),
		})
		addWith("Tablespace.SizeBytes", float64(tsp.SizeBytes), types.StandardUnitBytes, dims)
		if tsp.DiskTotalBytes > 0 {
			addWith("Tablespace.DiskUsedPercent", tsp.DiskUsedPercent, types.StandardUnitPercent, dims)
			addWith("Tablespace.DiskAvailBytes", float64(tsp.DiskAvailBytes), types.StandardUnitBytes, dims)
		}
	}

	return data
}
