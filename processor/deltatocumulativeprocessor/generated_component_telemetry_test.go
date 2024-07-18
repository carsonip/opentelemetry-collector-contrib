// Code generated by mdatagen. DO NOT EDIT.

package deltatocumulativeprocessor

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"go.opentelemetry.io/otel/sdk/metric/metricdata/metricdatatest"

	"go.opentelemetry.io/collector/component"
	"go.opentelemetry.io/collector/processor"
	"go.opentelemetry.io/collector/processor/processortest"
)

type componentTestTelemetry struct {
	reader        *sdkmetric.ManualReader
	meterProvider *sdkmetric.MeterProvider
}

func (tt *componentTestTelemetry) NewSettings() processor.Settings {
	settings := processortest.NewNopSettings()
	settings.MeterProvider = tt.meterProvider
	settings.ID = component.NewID(component.MustNewType("deltatocumulative"))

	return settings
}

func setupTestTelemetry() componentTestTelemetry {
	reader := sdkmetric.NewManualReader()
	return componentTestTelemetry{
		reader:        reader,
		meterProvider: sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader)),
	}
}

func (tt *componentTestTelemetry) assertMetrics(t *testing.T, expected []metricdata.Metrics) {
	var md metricdata.ResourceMetrics
	require.NoError(t, tt.reader.Collect(context.Background(), &md))
	// ensure all required metrics are present
	for _, want := range expected {
		got := tt.getMetric(want.Name, md)
		metricdatatest.AssertEqual(t, want, got, metricdatatest.IgnoreTimestamp())
	}

	// ensure no additional metrics are emitted
	require.Equal(t, len(expected), tt.len(md))
}

func (tt *componentTestTelemetry) getMetric(name string, got metricdata.ResourceMetrics) metricdata.Metrics {
	for _, sm := range got.ScopeMetrics {
		for _, m := range sm.Metrics {
			if m.Name == name {
				return m
			}
		}
	}

	return metricdata.Metrics{}
}

func (tt *componentTestTelemetry) len(got metricdata.ResourceMetrics) int {
	metricsCount := 0
	for _, sm := range got.ScopeMetrics {
		metricsCount += len(sm.Metrics)
	}

	return metricsCount
}

func (tt *componentTestTelemetry) Shutdown(ctx context.Context) error {
	return tt.meterProvider.Shutdown(ctx)
}
