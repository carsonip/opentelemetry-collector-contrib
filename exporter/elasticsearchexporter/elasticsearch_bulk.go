// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

// Package elasticsearchexporter contains an opentelemetry-collector exporter
// for Elasticsearch.
package elasticsearchexporter // import "github.com/open-telemetry/opentelemetry-collector-contrib/exporter/elasticsearchexporter"

import (
	"bytes"
	"context"
	"crypto/tls"
	"net/http"
	"time"

	"github.com/cenkalti/backoff/v4"
	"github.com/elastic/go-docappender"
	elasticsearch7 "github.com/elastic/go-elasticsearch/v7"
	"go.opentelemetry.io/otel/attribute"
	"go.uber.org/zap"

	"github.com/open-telemetry/opentelemetry-collector-contrib/internal/common/sanitize"
)

type esClientCurrent = elasticsearch7.Client
type esConfigCurrent = elasticsearch7.Config

type esBulkIndexerCurrent = *docappender.Appender

// clientLogger implements the estransport.Logger interface
// that is required by the Elasticsearch client for logging.
type clientLogger zap.Logger

// LogRoundTrip should not modify the request or response, except for consuming and closing the body.
// Implementations have to check for nil values in request and response.
func (cl *clientLogger) LogRoundTrip(requ *http.Request, resp *http.Response, err error, _ time.Time, dur time.Duration) error {
	zl := (*zap.Logger)(cl)
	switch {
	case err == nil && resp != nil:
		zl.Debug("Request roundtrip completed.",
			zap.String("path", sanitize.String(requ.URL.Path)),
			zap.String("method", requ.Method),
			zap.Duration("duration", dur),
			zap.String("status", resp.Status))

	case err != nil:
		zl.Error("Request failed.", zap.NamedError("reason", err))
	}

	return nil
}

// RequestBodyEnabled makes the client pass a copy of request body to the logger.
func (*clientLogger) RequestBodyEnabled() bool {
	// TODO: introduce setting log the bodies for more detailed debug logs
	return false
}

// ResponseBodyEnabled makes the client pass a copy of response body to the logger.
func (*clientLogger) ResponseBodyEnabled() bool {
	// TODO: introduce setting log the bodies for more detailed debug logs
	return false
}

func newElasticsearchClient(logger *zap.Logger, config *Config) (*esClientCurrent, error) {
	tlsCfg, err := config.ClientConfig.LoadTLSConfig()
	if err != nil {
		return nil, err
	}

	transport := newTransport(config, tlsCfg)

	headers := make(http.Header)
	for k, v := range config.Headers {
		headers.Add(k, v)
	}

	// TODO: validate settings:
	//  - try to parse address and validate scheme (address must be a valid URL)
	//  - check if cloud ID is valid

	// maxRetries configures the maximum number of event publishing attempts,
	// including the first send and additional retries.

	maxRetries := config.Retry.MaxRequests - 1
	retryDisabled := !config.Retry.Enabled || maxRetries <= 0

	if retryDisabled {
		maxRetries = 0
	}

	return elasticsearch7.NewClient(esConfigCurrent{
		Transport: transport,

		// configure connection setup
		Addresses: config.Endpoints,
		CloudID:   config.CloudID,
		Username:  config.Authentication.User,
		Password:  string(config.Authentication.Password),
		APIKey:    string(config.Authentication.APIKey),
		Header:    headers,

		// configure retry behavior
		RetryOnStatus:        retryOnStatus,
		DisableRetry:         retryDisabled,
		EnableRetryOnTimeout: config.Retry.Enabled,
		//RetryOnError:  retryOnError, // should be used from esclient version 8 onwards
		MaxRetries:   maxRetries,
		RetryBackoff: createElasticsearchBackoffFunc(&config.Retry),

		// configure sniffing
		DiscoverNodesOnStart:  config.Discovery.OnStart,
		DiscoverNodesInterval: config.Discovery.Interval,

		// configure internal metrics reporting and logging
		EnableMetrics:     false, // TODO
		EnableDebugLogger: false, // TODO
		Logger:            (*clientLogger)(logger),
	})
}

func newTransport(config *Config, tlsCfg *tls.Config) *http.Transport {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if tlsCfg != nil {
		transport.TLSClientConfig = tlsCfg
	}
	if config.ReadBufferSize > 0 {
		transport.ReadBufferSize = config.ReadBufferSize
	}
	if config.WriteBufferSize > 0 {
		transport.WriteBufferSize = config.WriteBufferSize
	}

	return transport
}

func newBulkIndexer(logger *zap.Logger, client *elasticsearch7.Client, config *Config) (esBulkIndexerCurrent, error) {
	return docappender.New(client, docappender.Config{
		Logger:             logger,
		Tracer:             nil,
		CompressionLevel:   0,
		MaxRequests:        0,
		MaxDocumentRetries: 0, //config.Retry.MaxRequests,
		FlushBytes:         config.Flush.Bytes,
		FlushInterval:      config.Flush.Interval,
		FlushTimeout:       config.Timeout,
		DocumentBufferSize: config.WriteBufferSize,
		Scaling: docappender.ScalingConfig{
			Disabled:     false,
			ActiveRatio:  1,
			ScaleDown:    docappender.ScaleActionConfig{},
			ScaleUp:      docappender.ScaleActionConfig{},
			IdleInterval: 0,
		},
		MeterProvider:    nil,
		MetricAttributes: attribute.Set{},
	})
}

func createElasticsearchBackoffFunc(config *RetrySettings) func(int) time.Duration {
	if !config.Enabled {
		return nil
	}

	expBackoff := backoff.NewExponentialBackOff()
	if config.InitialInterval > 0 {
		expBackoff.InitialInterval = config.InitialInterval
	}
	if config.MaxInterval > 0 {
		expBackoff.MaxInterval = config.MaxInterval
	}
	expBackoff.Reset()

	return func(attempts int) time.Duration {
		if attempts == 1 {
			expBackoff.Reset()
		}

		return expBackoff.NextBackOff()
	}
}

func pushDocuments(ctx context.Context, logger *zap.Logger, index string, document []byte, bulkIndexer esBulkIndexerCurrent, maxAttempts int) error {
	return bulkIndexer.Add(ctx, index, bytes.NewReader(document))
}
