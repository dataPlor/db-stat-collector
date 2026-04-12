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

	add := func(name string, value float64, unit types.StandardUnit) {
		data = append(data, types.MetricDatum{
			MetricName:        aws.String(name),
			Value:             aws.Float64(value),
			Unit:              unit,
			Timestamp:         aws.Time(ts),
			Dimensions:        p.dimensions,
			StorageResolution: aws.Int32(1),
		})
	}

	// Instantaneous gauges — always published.
	add("Connections.Active", float64(snap.ConnActive), types.StandardUnitCount)
	add("Connections.Idle", float64(snap.ConnIdle), types.StandardUnitCount)
	add("Connections.IdleInTransaction", float64(snap.ConnIdleInTxn), types.StandardUnitCount)
	add("Connections.Total", float64(snap.ConnTotal), types.StandardUnitCount)
	add("Connections.WaitingOnLock", float64(snap.ConnWaitingLocks), types.StandardUnitCount)
	add("LongestQuerySeconds", snap.LongestQuerySec, types.StandardUnitSeconds)
	add("LongestTransactionSeconds", snap.LongestXactSec, types.StandardUnitSeconds)

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
	add("RowsInserted", rate(snap.TupInserted, p.prev.TupInserted), types.StandardUnitCountSecond)
	add("RowsUpdated", rate(snap.TupUpdated, p.prev.TupUpdated), types.StandardUnitCountSecond)
	add("RowsDeleted", rate(snap.TupDeleted, p.prev.TupDeleted), types.StandardUnitCountSecond)
	add("RowsReturned", rate(snap.TupReturned, p.prev.TupReturned), types.StandardUnitCountSecond)
	add("RowsFetched", rate(snap.TupFetched, p.prev.TupFetched), types.StandardUnitCountSecond)
	add("Deadlocks", rate(snap.Deadlocks, p.prev.Deadlocks), types.StandardUnitCountSecond)
	add("Conflicts", rate(snap.Conflicts, p.prev.Conflicts), types.StandardUnitCountSecond)
	add("TempBytes", rate(snap.TempBytes, p.prev.TempBytes), types.StandardUnitBytesSecond)
	add("TempFiles", rate(snap.TempFiles, p.prev.TempFiles), types.StandardUnitCountSecond)

	// Cache hit ratio over the interval (not cumulative), so operators see
	// recent pressure rather than a slowly-moving lifetime average.
	hitDelta := snap.BlksHit - p.prev.BlksHit
	readDelta := snap.BlksRead - p.prev.BlksRead
	if total := hitDelta + readDelta; total > 0 && hitDelta >= 0 && readDelta >= 0 {
		add("CacheHitRatio", float64(hitDelta)/float64(total)*100.0, types.StandardUnitPercent)
	}

	return data
}
