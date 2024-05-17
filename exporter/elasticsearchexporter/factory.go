// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

//go:generate mdatagen metadata.yaml

package elasticsearchexporter // import "github.com/open-telemetry/opentelemetry-collector-contrib/exporter/elasticsearchexporter"

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"runtime"
	"time"

	"go.opentelemetry.io/collector/component"
	"go.opentelemetry.io/collector/exporter"
	"go.opentelemetry.io/collector/exporter/exporterbatcher"
	"go.opentelemetry.io/collector/exporter/exporterhelper"
	"go.opentelemetry.io/collector/exporter/exporterqueue"

	"github.com/open-telemetry/opentelemetry-collector-contrib/exporter/elasticsearchexporter/internal/metadata"
)

const (
	// The value of "type" key in configuration.
	defaultLogsIndex   = "logs-generic-default"
	defaultTracesIndex = "traces-generic-default"
	userAgentHeaderKey = "User-Agent"
)

// NewFactory creates a factory for Elastic exporter.
func NewFactory() exporter.Factory {
	return exporter.NewFactory(
		metadata.Type,
		createDefaultConfig,
		exporter.WithLogs(createLogsRequestExporter, metadata.LogsStability),
		exporter.WithTraces(createTracesRequestExporter, metadata.TracesStability),
	)
}

func createDefaultConfig() component.Config {
	qs := exporterqueue.PersistentQueueConfig{
		Config:    exporterqueue.NewDefaultConfig(),
		StorageID: nil,
	}
	qs.Enabled = false // FIXME: how does batching without queuing look like?
	return &Config{
		PersistentQueueConfig: qs,
		ClientConfig: ClientConfig{
			Timeout: 90 * time.Second,
		},
		Index:       "",
		LogsIndex:   defaultLogsIndex,
		TracesIndex: defaultTracesIndex,
		Retry: RetrySettings{
			Enabled:         true,
			MaxRequests:     3,
			InitialInterval: 100 * time.Millisecond,
			MaxInterval:     1 * time.Minute,
			RetryOnStatus: []int{
				http.StatusTooManyRequests,
				http.StatusInternalServerError,
				http.StatusBadGateway,
				http.StatusServiceUnavailable,
				http.StatusGatewayTimeout,
			},
		},
		Flush: FlushSettings{
			Bytes:        0,
			MinDocuments: 125,
			Interval:     30 * time.Second,
		},
		Mapping: MappingsSettings{
			Mode:  "none",
			Dedup: true,
			Dedot: true,
		},
		LogstashFormat: LogstashFormatSettings{
			Enabled:         false,
			PrefixSeparator: "-",
			DateFormat:      "%Y.%m.%d",
		},
	}
}

func makeMarshalUnmarshalRequestFuncs(bulkIndexer *bulkIndexerPool) (
	func(exporterhelper.Request) ([]byte, error),
	func([]byte) (exporterhelper.Request, error),
) {
	marshalRequest := func(req exporterhelper.Request) ([]byte, error) {
		// FIXME: use a better and faster serialization
		b, err := json.Marshal(*req.(*request))
		return b, err
	}
	unmarshalRequest := func(b []byte) (exporterhelper.Request, error) {
		// FIXME: possibly handle back-compat or forward-compat in case of residue in persistent queue on upgrades / downgrades
		var req request
		err := json.Unmarshal(b, &req)
		req.bulkIndexer = bulkIndexer
		return &req, err
	}
	return marshalRequest, unmarshalRequest
}

func makeBatchFuncs(bulkIndexer *bulkIndexerPool) (
	func(ctx context.Context, r1, r2 exporterhelper.Request) (exporterhelper.Request, error),
	func(ctx context.Context, conf exporterbatcher.MaxSizeConfig, optReq, req exporterhelper.Request) ([]exporterhelper.Request, error),
) {
	batchMergeFunc := func(ctx context.Context, r1, r2 exporterhelper.Request) (exporterhelper.Request, error) {
		rr1 := r1.(*request)
		rr2 := r2.(*request)
		req := newRequest(bulkIndexer)
		req.Items = append(rr1.Items, rr2.Items...)
		return req, nil
	}

	batchMergeSplitFunc := func(ctx context.Context, conf exporterbatcher.MaxSizeConfig, optReq, req exporterhelper.Request) ([]exporterhelper.Request, error) {
		// TODO: implement merge split func once max_documents is supported in addition to min_documents
		panic("not implemented")
		return nil, nil
	}
	return batchMergeFunc, batchMergeSplitFunc
}

// createLogsRequestExporter creates a new request exporter for logs.
//
// Logs are directly indexed into Elasticsearch.
func createLogsRequestExporter(
	ctx context.Context,
	set exporter.CreateSettings,
	cfg component.Config,
) (exporter.Logs, error) {
	cf := cfg.(*Config)
	if cf.Index != "" {
		set.Logger.Warn("index option are deprecated and replaced with logs_index and traces_index.")
	}

	if cf.Flush.Bytes != 0 {
		set.Logger.Warn("flush.bytes option is ignored. Use flush.min_documents instead.")
	}

	setDefaultUserAgentHeader(cf, set.BuildInfo)

	logsExporter, err := newLogsExporter(set.Logger, cf)
	if err != nil {
		return nil, fmt.Errorf("cannot configure Elasticsearch logsExporter: %w", err)
	}

	batchMergeFunc, batchMergeSplitFunc := makeBatchFuncs(logsExporter.bulkIndexer)
	marshalRequest, unmarshalRequest := makeMarshalUnmarshalRequestFuncs(logsExporter.bulkIndexer)

	batcherCfg := getBatcherConfig(cf)
	return exporterhelper.NewLogsRequestExporter(
		ctx,
		set,
		logsExporter.logsDataToRequest,
		exporterhelper.WithBatcher(batcherCfg, exporterhelper.WithRequestBatchFuncs(batchMergeFunc, batchMergeSplitFunc)),
		exporterhelper.WithShutdown(logsExporter.Shutdown),
		exporterhelper.WithRequestQueue(cf.PersistentQueueConfig.Config,
			exporterqueue.NewPersistentQueueFactory[exporterhelper.Request](cf.PersistentQueueConfig.StorageID, exporterqueue.PersistentQueueSettings[exporterhelper.Request]{
				Marshaler:   marshalRequest,
				Unmarshaler: unmarshalRequest,
			})),
	)
}

func createTracesRequestExporter(ctx context.Context,
	set exporter.CreateSettings,
	cfg component.Config) (exporter.Traces, error) {

	cf := cfg.(*Config)

	if cf.Flush.Bytes != 0 {
		set.Logger.Warn("flush.bytes option is ignored. Use flush.min_documents instead.")
	}

	setDefaultUserAgentHeader(cf, set.BuildInfo)

	tracesExporter, err := newTracesExporter(set.Logger, cf)
	if err != nil {
		return nil, fmt.Errorf("cannot configure Elasticsearch tracesExporter: %w", err)
	}

	batchMergeFunc, batchMergeSplitFunc := makeBatchFuncs(tracesExporter.bulkIndexer)
	marshalRequest, unmarshalRequest := makeMarshalUnmarshalRequestFuncs(tracesExporter.bulkIndexer)

	batcherCfg := getBatcherConfig(cf)
	return exporterhelper.NewTracesRequestExporter(
		ctx,
		set,
		tracesExporter.traceDataToRequest,
		exporterhelper.WithBatcher(batcherCfg, exporterhelper.WithRequestBatchFuncs(batchMergeFunc, batchMergeSplitFunc)),
		exporterhelper.WithShutdown(tracesExporter.Shutdown),
		exporterhelper.WithRequestQueue(cf.PersistentQueueConfig.Config,
			exporterqueue.NewPersistentQueueFactory[exporterhelper.Request](cf.PersistentQueueConfig.StorageID, exporterqueue.PersistentQueueSettings[exporterhelper.Request]{
				Marshaler:   marshalRequest,
				Unmarshaler: unmarshalRequest,
			})),
	)
}

// set default User-Agent header with BuildInfo if User-Agent is empty
func setDefaultUserAgentHeader(cf *Config, info component.BuildInfo) {
	if _, found := cf.Headers[userAgentHeaderKey]; found {
		return
	}
	if cf.Headers == nil {
		cf.Headers = make(map[string]string)
	}
	cf.Headers[userAgentHeaderKey] = fmt.Sprintf("%s/%s (%s/%s)", info.Description, info.Version, runtime.GOOS, runtime.GOARCH)
}

func getBatcherConfig(cf *Config) exporterbatcher.Config {
	batcherCfg := exporterbatcher.NewDefaultConfig()
	batcherCfg.Enabled = true
	batcherCfg.FlushTimeout = cf.Flush.Interval
	batcherCfg.MinSizeItems = cf.Flush.MinDocuments
	batcherCfg.MaxSizeItems = 0
	return batcherCfg
}
