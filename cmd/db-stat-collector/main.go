package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/ec2/imds"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	cwtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	"github.com/jackc/pgx/v5/pgxpool"

	"db-stat-collector/internal/collector"
	"db-stat-collector/internal/publisher"
)

func main() {
	var (
		dsn        = flag.String("pg-dsn", getenv("PG_DSN", "dbname=postgres sslmode=disable"), "PostgreSQL DSN (key=value or postgres:// URL)")
		namespace  = flag.String("namespace", getenv("CW_NAMESPACE", "PostgreSQL"), "CloudWatch namespace")
		interval   = flag.Duration("interval", parseDuration(getenv("COLLECT_INTERVAL", "60s"), 60*time.Second), "Collection interval")
		publishTO  = flag.Duration("publish-timeout", parseDuration(getenv("PUBLISH_TIMEOUT", "10s"), 10*time.Second), "CloudWatch PutMetricData timeout")
		instanceID = flag.String("instance-id", os.Getenv("INSTANCE_ID"), "Override EC2 instance id (else fetched from IMDS)")
		cluster    = flag.String("cluster", os.Getenv("CLUSTER"), "Optional ClusterName dimension")
	)
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, log, runOpts{
		dsn:            *dsn,
		namespace:      *namespace,
		interval:       *interval,
		publishTimeout: *publishTO,
		instanceID:     *instanceID,
		cluster:        *cluster,
	}); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

type runOpts struct {
	dsn            string
	namespace      string
	interval       time.Duration
	publishTimeout time.Duration
	instanceID     string
	cluster        string
}

func run(ctx context.Context, log *slog.Logger, opts runOpts) error {
	awsCfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return fmt.Errorf("loading aws config: %w", err)
	}

	// The default resolver sometimes fails to pick up the region from IMDS
	// even when instance-id lookup works (short internal timeout). Fill it
	// in explicitly so PutMetricData can resolve an endpoint.
	if awsCfg.Region == "" {
		if region, err := fetchRegion(ctx, awsCfg); err != nil {
			log.Warn("could not fetch region from IMDS; set AWS_REGION explicitly", "err", err)
		} else {
			awsCfg.Region = region
			log.Info("resolved region from IMDS", "region", region)
		}
	}

	if opts.instanceID == "" {
		if id, err := fetchInstanceID(ctx, awsCfg); err != nil {
			log.Warn("could not fetch instance id from IMDS; metrics will lack InstanceId dimension", "err", err)
		} else {
			opts.instanceID = id
		}
	}

	var dims []cwtypes.Dimension
	if opts.instanceID != "" {
		dims = append(dims, cwtypes.Dimension{Name: aws.String("InstanceId"), Value: aws.String(opts.instanceID)})
	}
	if opts.cluster != "" {
		dims = append(dims, cwtypes.Dimension{Name: aws.String("ClusterName"), Value: aws.String(opts.cluster)})
	}

	poolCfg, err := pgxpool.ParseConfig(opts.dsn)
	if err != nil {
		return fmt.Errorf("parsing pg dsn: %w", err)
	}
	poolCfg.MinConns = 1
	poolCfg.MaxConns = 2
	poolCfg.MaxConnLifetime = time.Hour

	pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		return fmt.Errorf("connecting to postgres: %w", err)
	}
	defer pool.Close()

	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	err = pool.Ping(pingCtx)
	cancel()
	if err != nil {
		return fmt.Errorf("pinging postgres: %w", err)
	}

	col := collector.New(pool)
	pub := publisher.New(cloudwatch.NewFromConfig(awsCfg), opts.namespace, dims, log)

	log.Info("db-stat-collector started",
		"namespace", opts.namespace,
		"interval", opts.interval,
		"instance_id", opts.instanceID,
		"cluster", opts.cluster,
	)

	ticker := time.NewTicker(opts.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Info("shutting down")
			return nil
		case <-ticker.C:
			tickCtx, cancel := context.WithTimeout(ctx, opts.interval)
			snap, err := col.Collect(tickCtx)
			cancel()
			if err != nil {
				log.Error("collect failed", "err", err)
				continue
			}
			pubCtx, cancel := context.WithTimeout(ctx, opts.publishTimeout)
			if err := pub.Publish(pubCtx, snap); err != nil {
				log.Error("publish failed", "err", err)
			}
			cancel()
		}
	}
}

func fetchInstanceID(ctx context.Context, awsCfg aws.Config) (string, error) {
	c := imds.NewFromConfig(awsCfg)
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := c.GetMetadata(ctx, &imds.GetMetadataInput{Path: "instance-id"})
	if err != nil {
		return "", err
	}
	defer out.Content.Close()
	b, err := io.ReadAll(out.Content)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

func fetchRegion(ctx context.Context, awsCfg aws.Config) (string, error) {
	c := imds.NewFromConfig(awsCfg)
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := c.GetRegion(ctx, &imds.GetRegionInput{})
	if err != nil {
		return "", err
	}
	return out.Region, nil
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func parseDuration(s string, def time.Duration) time.Duration {
	if s == "" {
		return def
	}
	d, err := time.ParseDuration(s)
	if err != nil {
		return def
	}
	return d
}
