// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package integrationtest

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/collector/component"
	"go.opentelemetry.io/collector/component/componenttest"
	"go.opentelemetry.io/collector/consumer"
	"go.opentelemetry.io/collector/exporter"
	"go.opentelemetry.io/collector/exporter/exportertest"
	"go.opentelemetry.io/collector/extension"
	"go.opentelemetry.io/collector/pdata/plog"
	"go.opentelemetry.io/collector/pdata/pmetric"
	"go.opentelemetry.io/collector/pdata/ptrace"

	"github.com/open-telemetry/opentelemetry-collector-contrib/exporter/elasticsearchexporter"
	"github.com/open-telemetry/opentelemetry-collector-contrib/extension/storage/filestorage"
	"github.com/open-telemetry/opentelemetry-collector-contrib/extension/storage/storagetest"
	"github.com/open-telemetry/opentelemetry-collector-contrib/testbed/testbed"
)

func BenchmarkExporter(b *testing.B) {
	for _, eventType := range []string{"logs", "traces"} {
		for _, mappingMode := range []string{"none", "ecs", "raw"} {
			for _, persistentQueue := range []bool{false, true} {
				for _, tc := range []struct {
					name      string
					batchSize int
				}{
					{name: "small_batch", batchSize: 10},
					{name: "medium_batch", batchSize: 100},
					{name: "large_batch", batchSize: 1000},
					{name: "xlarge_batch", batchSize: 10000},
				} {
					b.Run(fmt.Sprintf("%s/%s/persistentQueue=%v/%s", eventType, mappingMode, persistentQueue, tc.name), func(b *testing.B) {
						switch eventType {
						case "logs":
							benchmarkLogs(b, tc.batchSize, mappingMode, persistentQueue)
						case "traces":
							benchmarkTraces(b, tc.batchSize, mappingMode, persistentQueue)
						}
					})
				}
			}
		}
	}
}

func benchmarkLogs(b *testing.B, batchSize int, mappingMode string, persistentQueue bool) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	host := storagetest.NewStorageHost()
	runnerCfg := prepareBenchmark(b, host, batchSize, mappingMode, persistentQueue)
	exporter, err := runnerCfg.factory.CreateLogsExporter(
		ctx, exportertest.NewNopSettings(), runnerCfg.esCfg,
	)
	require.NoError(b, err)
	require.NoError(b, exporter.Start(ctx, host))

	b.ReportAllocs()
	b.ResetTimer()
	b.StopTimer()
	for i := 0; i < b.N; i++ {
		logs, _ := runnerCfg.provider.GenerateLogs()
		b.StartTimer()
		require.NoError(b, exporter.ConsumeLogs(ctx, logs))
		b.StopTimer()
	}
	b.ReportMetric(
		float64(runnerCfg.generatedCount.Load())/b.Elapsed().Seconds(),
		"events/s",
	)
	require.NoError(b, exporter.Shutdown(ctx))
}

func benchmarkTraces(b *testing.B, batchSize int, mappingMode string, persistentQueue bool) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	host := storagetest.NewStorageHost()
	runnerCfg := prepareBenchmark(b, host, batchSize, mappingMode, persistentQueue)
	exporter, err := runnerCfg.factory.CreateTracesExporter(
		ctx, exportertest.NewNopSettings(), runnerCfg.esCfg,
	)
	require.NoError(b, err)
	require.NoError(b, exporter.Start(ctx, host))

	b.ReportAllocs()
	b.ResetTimer()
	b.StopTimer()
	for i := 0; i < b.N; i++ {
		traces, _ := runnerCfg.provider.GenerateTraces()
		b.StartTimer()
		require.NoError(b, exporter.ConsumeTraces(ctx, traces))
		b.StopTimer()
	}
	b.ReportMetric(
		float64(runnerCfg.generatedCount.Load())/b.Elapsed().Seconds(),
		"events/s",
	)
	require.NoError(b, exporter.Shutdown(ctx))
}

type benchRunnerCfg struct {
	factory  exporter.Factory
	provider testbed.DataProvider
	esCfg    *elasticsearchexporter.Config

	generatedCount atomic.Uint64
}

func prepareBenchmark(
	b *testing.B,
	host *storagetest.StorageHost,
	batchSize int,
	mappingMode string,
	persistentQueue bool,
) *benchRunnerCfg {
	b.Helper()

	cfg := &benchRunnerCfg{}
	// Benchmarks don't decode the bulk requests to avoid allocations to pollute the results.
	receiver := newElasticsearchDataReceiver(b, false /* DecodeBulkRequest */)
	cfg.provider = testbed.NewPerfTestDataProvider(testbed.LoadOptions{ItemsPerBatch: batchSize})
	cfg.provider.SetLoadGeneratorCounters(&cfg.generatedCount)

	cfg.factory = elasticsearchexporter.NewFactory()
	cfg.esCfg = cfg.factory.CreateDefaultConfig().(*elasticsearchexporter.Config)
	cfg.esCfg.Mapping.Mode = mappingMode
	if persistentQueue {
		fileExtID, fileExt := getFileStorageExtension(b)
		host.WithExtension(fileExtID, fileExt)
		cfg.esCfg.QueueSettings.StorageID = &fileExtID
	}
	cfg.esCfg.Endpoints = []string{receiver.endpoint}
	cfg.esCfg.LogsIndex = TestLogsIndex
	cfg.esCfg.TracesIndex = TestTracesIndex
	cfg.esCfg.BatcherConfig.FlushTimeout = 10 * time.Millisecond
	cfg.esCfg.NumWorkers = 1

	tc, err := consumer.NewTraces(func(context.Context, ptrace.Traces) error {
		return nil
	})
	require.NoError(b, err)
	mc, err := consumer.NewMetrics(func(context.Context, pmetric.Metrics) error {
		return nil
	})
	require.NoError(b, err)
	lc, err := consumer.NewLogs(func(context.Context, plog.Logs) error {
		return nil
	})
	require.NoError(b, err)

	require.NoError(b, receiver.Start(tc, mc, lc))
	b.Cleanup(func() { require.NoError(b, receiver.Stop()) })

	return cfg
}

func getFileStorageExtension(b testing.TB) (component.ID, extension.Extension) {
	storage := filestorage.NewFactory()
	componentID := component.NewIDWithName(storage.Type(), "esexporterbench")

	storageCfg := storage.CreateDefaultConfig().(*filestorage.Config)
	storageCfg.Directory = b.TempDir()
	fileExt, err := storage.CreateExtension(
		context.Background(),
		extension.CreateSettings{
			ID:                componentID,
			TelemetrySettings: componenttest.NewNopTelemetrySettings(),
			BuildInfo:         component.NewDefaultBuildInfo(),
		},
		storageCfg,
	)
	require.NoError(b, err)
	return componentID, fileExt
}
