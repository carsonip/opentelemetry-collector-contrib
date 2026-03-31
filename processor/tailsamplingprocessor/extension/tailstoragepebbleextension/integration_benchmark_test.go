// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

//go:build integration

package tailstoragepebbleextension

import (
	"bytes"
	"flag"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/collector/component"
	"go.opentelemetry.io/collector/confmap"
	"go.opentelemetry.io/collector/confmap/provider/fileprovider"
	"go.opentelemetry.io/collector/exporter"
	"go.opentelemetry.io/collector/exporter/nopexporter"
	"go.opentelemetry.io/collector/extension"
	"go.opentelemetry.io/collector/otelcol"
	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/ptrace"
	"go.opentelemetry.io/collector/pdata/ptrace/ptraceotlp"
	"go.opentelemetry.io/collector/processor"
	"go.opentelemetry.io/collector/receiver"
	"go.opentelemetry.io/collector/receiver/otlpreceiver"
	"go.opentelemetry.io/collector/service/telemetry/otelconftelemetry"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor"
)

func BenchmarkCollectorOTLPReceiverStorageBackends(b *testing.B) {
	benchTime, err := benchTimeDuration()
	require.NoError(b, err)
	shapes := []benchmarkShape{
		{
			name:                "dw1s_rps200",
			tracesPerBatch:      30,
			spansPerTrace:       7,
			payloadBytes:        4 * 1024,
			parallelism:         8,
			targetReqPerSec:     200,
			decisionWait:        time.Second,
			numTraces:           1_000_000,
			policyPercentage:    1.0,
			require2xDecisionWait: true,
		},
		{
			name:                "dw1s_noRateLimit",
			tracesPerBatch:      30,
			spansPerTrace:       7,
			payloadBytes:        4 * 1024,
			parallelism:         8,
			targetReqPerSec:     0,
			decisionWait:        time.Second,
			numTraces:           1_000_000,
			policyPercentage:    1.0,
			require2xDecisionWait: true,
		},
		{
			name:                "dwBenchtimePlus1m_rps200",
			tracesPerBatch:      30,
			spansPerTrace:       7,
			payloadBytes:        4 * 1024,
			parallelism:         8,
			targetReqPerSec:     200,
			decisionWait:        benchTime + time.Minute,
			numTraces:           1_000_000,
			policyPercentage:    1.0,
			require2xDecisionWait: false,
		},
	}

	for _, shape := range shapes {
		b.Run(shape.name, func(b *testing.B) {
			for _, backend := range []string{"inmemory", "pebble"} {
				b.Run(backend, func(b *testing.B) {
					if shape.require2xDecisionWait {
						requireBenchTimeAtLeast(b, 2*shape.decisionWait)
					}

					target, cleanup, storageDir := setupCollectorBenchmark(b, backend, shape)
					defer cleanup()

					conn, err := grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
					require.NoError(b, err)
					defer func() { _ = conn.Close() }()
					client := ptraceotlp.NewGRPCClient(conn)

					referenceBatch := benchmarkBatch(1, shape)
					b.SetBytes(int64((&ptrace.ProtoMarshaler{}).TracesSize(referenceBatch)))
					b.ReportAllocs()
					b.SetParallelism(shape.parallelism)
					runtime.GC()
					debug.FreeOSMemory()
					baselineRSS, err := currentRSSBytes()
					require.NoError(b, err)
					stopRSSSampler := startRSSSampler(10 * time.Millisecond)
					acquire, stopRateLimiter := startFixedRateLimiter(shape.targetReqPerSec)
					defer stopRateLimiter()
					var requests atomic.Uint64
					b.ResetTimer()

					b.RunParallel(func(pb *testing.PB) {
						var seed uint64
						for pb.Next() {
							acquire()
							seed++
							requests.Add(1)
							_, err := client.Export(b.Context(), ptraceotlp.NewExportRequestFromTraces(benchmarkBatch(seed, shape)))
							require.NoError(b, err)
						}
					})
					b.StopTimer()

					elapsed := b.Elapsed()
					if elapsed > 0 {
						reqPerSec := float64(requests.Load()) / elapsed.Seconds()
						spansPerSec := reqPerSec * float64(shape.spansPerRequest())
						b.ReportMetric(reqPerSec, "recv_request/s")
						b.ReportMetric(spansPerSec, "recv_spans/s")
					}

					peakRSS := stopRSSSampler()
					deltaRSS := int64(peakRSS) - int64(baselineRSS)
					if deltaRSS < 0 {
						deltaRSS = 0
					}
					b.ReportMetric(float64(peakRSS)/(1024*1024), "peak_rss_mb")
					b.ReportMetric(float64(deltaRSS)/(1024*1024), "rss_delta_mb")
					storageBytes, err := dirSizeBytes(storageDir)
					require.NoError(b, err)
					b.ReportMetric(float64(storageBytes)/(1024*1024), "storage_mb")
				})
			}
		})
	}
}

func setupCollectorBenchmark(b *testing.B, backend string, shape benchmarkShape) (string, func(), string) {
	ctx := b.Context()
	endpoint := availableLocalAddress(b)

	cfgPath, storageDir := writeCollectorBenchmarkConfig(b, backend, endpoint, shape)
	factories := collectorBenchmarkFactories(b)
	app := newCollectorForBenchmark(b, cfgPath, factories)

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_ = app.Run(ctx)
	}()
	waitForCollectorRunning(app)

	return endpoint, func() {
		app.Shutdown()
		wg.Wait()
	}, storageDir
}

func collectorBenchmarkFactories(b *testing.B) otelcol.Factories {
	var err error
	factories := otelcol.Factories{
		Telemetry: otelconftelemetry.NewFactory(),
	}
	factories.Receivers, err = otelcol.MakeFactoryMap[receiver.Factory](
		otlpreceiver.NewFactory(),
	)
	require.NoError(b, err)
	factories.Processors, err = otelcol.MakeFactoryMap[processor.Factory](
		tailsamplingprocessor.NewFactory(),
	)
	require.NoError(b, err)
	factories.Exporters, err = otelcol.MakeFactoryMap[exporter.Factory](
		nopexporter.NewFactory(),
	)
	require.NoError(b, err)
	factories.Extensions, err = otelcol.MakeFactoryMap[extension.Factory](
		NewFactory(),
	)
	require.NoError(b, err)
	return factories
}

func newCollectorForBenchmark(b *testing.B, cfgPath string, factories otelcol.Factories) *otelcol.Collector {
	app, err := otelcol.NewCollector(otelcol.CollectorSettings{
		Factories: func() (otelcol.Factories, error) { return factories, nil },
		ConfigProviderSettings: otelcol.ConfigProviderSettings{
			ResolverSettings: confmap.ResolverSettings{
				URIs:              []string{cfgPath},
				ProviderFactories: []confmap.ProviderFactory{fileprovider.NewFactory()},
			},
		},
		BuildInfo: component.BuildInfo{
			Command:     "otelcol",
			Description: "collector benchmark",
			Version:     "tests",
		},
	})
	require.NoError(b, err)
	return app
}

func waitForCollectorRunning(app *otelcol.Collector) {
	for {
		switch app.GetState() {
		case otelcol.StateRunning, otelcol.StateClosed, otelcol.StateClosing:
			return
		default:
			time.Sleep(10 * time.Millisecond)
		}
	}
}

func writeCollectorBenchmarkConfig(b *testing.B, backend, endpoint string, shape benchmarkShape) (string, string) {
	var cfg string
	storageDir := ""
	if backend == "pebble" {
		storageDir = filepath.Join(b.TempDir(), "pebble")
		cfg = fmt.Sprintf(`
extensions:
  tail_storage_pebble/bench:
    directory: %s
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: %s
processors:
  tail_sampling:
    sampling_strategy: span-ingest
    decision_wait: %s
    num_traces: %d
    block_on_overflow: true
    tail_storage: tail_storage_pebble/bench
    policies:
      - name: probabilistic-1pct
        type: probabilistic
        probabilistic:
          sampling_percentage: %.2f
exporters:
  nop:
service:
  telemetry:
    logs:
      level: error
      output_paths: [/dev/null]
      error_output_paths: [/dev/null]
  extensions: [tail_storage_pebble/bench]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [tail_sampling]
      exporters: [nop]
`, storageDir, endpoint, shape.decisionWait, shape.numTraces, shape.policyPercentage)
	} else {
		cfg = fmt.Sprintf(`
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: %s
processors:
  tail_sampling:
    sampling_strategy: span-ingest
    decision_wait: %s
    num_traces: %d
    block_on_overflow: true
    policies:
      - name: probabilistic-1pct
        type: probabilistic
        probabilistic:
          sampling_percentage: %.2f
exporters:
  nop:
service:
  telemetry:
    logs:
      level: error
      output_paths: [/dev/null]
      error_output_paths: [/dev/null]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [tail_sampling]
      exporters: [nop]
`, endpoint, shape.decisionWait, shape.numTraces, shape.policyPercentage)
	}

	path := filepath.Join(b.TempDir(), "collector_bench.yaml")
	require.NoError(b, os.WriteFile(path, []byte(cfg), 0o600))
	return path, storageDir
}

func availableLocalAddress(b *testing.B) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(b, err)
	defer func() { _ = l.Close() }()
	return l.Addr().String()
}

func startRSSSampler(interval time.Duration) func() uint64 {
	var peak atomic.Uint64
	initial, err := currentRSSBytes()
	if err == nil {
		peak.Store(initial)
	}

	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				rss, err := currentRSSBytes()
				if err != nil {
					continue
				}
				for {
					prev := peak.Load()
					if rss <= prev || peak.CompareAndSwap(prev, rss) {
						break
					}
				}
			case <-done:
				return
			}
		}
	}()

	return func() uint64 {
		close(done)
		rss, err := currentRSSBytes()
		if err == nil {
			for {
				prev := peak.Load()
				if rss <= prev || peak.CompareAndSwap(prev, rss) {
					break
				}
			}
		}
		return peak.Load()
	}
}

func currentRSSBytes() (uint64, error) {
	status, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0, err
	}
	for _, line := range bytes.Split(status, []byte{'\n'}) {
		if !bytes.HasPrefix(line, []byte("VmRSS:")) {
			continue
		}
		fields := bytes.Fields(line)
		if len(fields) < 2 {
			return 0, fmt.Errorf("unexpected VmRSS format: %q", line)
		}
		kb, err := strconv.ParseUint(string(fields[1]), 10, 64)
		if err != nil {
			return 0, err
		}
		return kb * 1024, nil
	}
	return 0, fmt.Errorf("VmRSS not found in /proc/self/status")
}

func requireBenchTimeAtLeast(b *testing.B, minDuration time.Duration) {
	d, err := benchTimeDuration()
	if err != nil {
		b.Fatalf("invalid -test.benchtime: %v", err)
	}
	if d < minDuration {
		b.Fatalf("benchmark benchtime %v must be >= 2x decision_wait (%v); rerun with -benchtime >= %v", d, minDuration/2, minDuration)
	}
}

func benchTimeDuration() (time.Duration, error) {
	benchTime := "1s"
	if f := flag.Lookup("test.benchtime"); f != nil {
		benchTime = f.Value.String()
	}
	if strings.HasSuffix(benchTime, "x") {
		return 0, fmt.Errorf("benchtime %q must be time-based", benchTime)
	}
	d, err := time.ParseDuration(benchTime)
	if err != nil {
		return 0, fmt.Errorf("unable to parse -test.benchtime=%q: %w", benchTime, err)
	}
	return d, nil
}

type benchmarkShape struct {
	name             string
	tracesPerBatch   int
	spansPerTrace    int
	payloadBytes     int
	parallelism      int
	targetReqPerSec  int
	decisionWait     time.Duration
	numTraces        uint64
	policyPercentage float64
	require2xDecisionWait bool
}

func (s benchmarkShape) spansPerRequest() int {
	return s.tracesPerBatch * s.spansPerTrace
}

func (s benchmarkShape) payload() string {
	if s.payloadBytes <= 0 {
		return ""
	}
	return strings.Repeat("x", s.payloadBytes)
}

func startFixedRateLimiter(targetReqPerSec int) (acquire func(), stop func()) {
	if targetReqPerSec <= 0 {
		return func() {}, func() {}
	}

	interval := time.Second / time.Duration(targetReqPerSec)
	if interval <= 0 {
		interval = time.Nanosecond
	}

	tokens := make(chan struct{}, targetReqPerSec)
	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				select {
				case tokens <- struct{}{}:
				default:
				}
			}
		}
	}()

	return func() { <-tokens }, func() { close(done) }
}

func benchmarkBatch(seed uint64, shape benchmarkShape) ptrace.Traces {
	td := ptrace.NewTraces()
	rs := td.ResourceSpans().AppendEmpty()
	ss := rs.ScopeSpans().AppendEmpty()
	payload := shape.payload()
	spanSeq := seed*1_000_003 + 1

	for traceOffset := range shape.tracesPerBatch {
		traceID := uInt64ToTraceID(seed*65_537 + uint64(traceOffset))
		for spanOffset := range shape.spansPerTrace {
			span := ss.Spans().AppendEmpty()
			span.SetTraceID(traceID)
			span.SetSpanID(uInt64ToSpanID(spanSeq + uint64(spanOffset)))
			if payload != "" {
				span.Attributes().PutStr("payload", payload)
			}
		}
	}

	return td
}

func uInt64ToTraceID(v uint64) pcommon.TraceID {
	var id pcommon.TraceID
	for i := range 8 {
		id[i] = byte(v >> (8 * i))
		id[i+8] = byte((v + 0x9e3779b97f4a7c15) >> (8 * i))
	}
	return id
}

func uInt64ToSpanID(v uint64) pcommon.SpanID {
	var id pcommon.SpanID
	for i := range 8 {
		id[i] = byte(v >> (8 * i))
	}
	return id
}

func dirSizeBytes(path string) (uint64, error) {
	if path == "" {
		return 0, nil
	}
	var total uint64
	err := filepath.WalkDir(path, func(_ string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		total += uint64(info.Size())
		return nil
	})
	if os.IsNotExist(err) {
		return 0, nil
	}
	return total, err
}
