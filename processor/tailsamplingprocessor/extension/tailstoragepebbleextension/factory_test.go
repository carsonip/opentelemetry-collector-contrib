// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package tailstoragepebbleextension

import (
	"testing"

	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/collector/component/componenttest"
	"go.opentelemetry.io/collector/extension/extensiontest"
	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/ptrace"
)

type tailStorage interface {
	Append(traceID pcommon.TraceID, rss ptrace.ResourceSpans)
	Take(traceID pcommon.TraceID) (ptrace.Traces, bool)
	Delete(traceID pcommon.TraceID)
}

func TestFactoryCreateAndUse(t *testing.T) {
	f := NewFactory()
	cfg := f.CreateDefaultConfig().(*Config)
	cfg.Directory = t.TempDir()

	ext, err := f.Create(
		t.Context(),
		extensiontest.NewNopSettings(f.Type()),
		cfg,
	)
	require.NoError(t, err)
	require.NotNil(t, ext)

	require.NoError(t, ext.Start(t.Context(), componenttest.NewNopHost()))
	t.Cleanup(func() {
		require.NoError(t, ext.Shutdown(t.Context()))
	})

	storage, ok := ext.(tailStorage)
	require.True(t, ok)

	traceID := pcommon.TraceID([16]byte{1, 2, 3, 4})
	td := ptrace.NewTraces()
	rss := td.ResourceSpans().AppendEmpty()
	rss.ScopeSpans().AppendEmpty().Spans().AppendEmpty().SetTraceID(traceID)
	storage.Append(traceID, rss)

	out, found := storage.Take(traceID)
	require.True(t, found)
	require.Equal(t, 1, out.SpanCount())
}

func TestDeleteRemovesOnlyTargetTrace(t *testing.T) {
	f := NewFactory()
	cfg := f.CreateDefaultConfig().(*Config)
	cfg.Directory = t.TempDir()

	ext, err := f.Create(
		t.Context(),
		extensiontest.NewNopSettings(f.Type()),
		cfg,
	)
	require.NoError(t, err)
	require.NotNil(t, ext)

	require.NoError(t, ext.Start(t.Context(), componenttest.NewNopHost()))
	t.Cleanup(func() {
		require.NoError(t, ext.Shutdown(t.Context()))
	})

	storage, ok := ext.(tailStorage)
	require.True(t, ok)

	traceID1 := pcommon.TraceID([16]byte{1, 2, 3, 4})
	traceID2 := pcommon.TraceID([16]byte{1, 2, 3, 5})

	// Append multiple entries for traceID1 to exercise range deletion.
	for i := range 3 {
		td := ptrace.NewTraces()
		rss := td.ResourceSpans().AppendEmpty()
		span := rss.ScopeSpans().AppendEmpty().Spans().AppendEmpty()
		span.SetTraceID(traceID1)
		span.SetName("trace1-span")
		span.SetSpanID(pcommon.SpanID([8]byte{byte(i + 1)}))
		storage.Append(traceID1, rss)
	}

	td2 := ptrace.NewTraces()
	rss2 := td2.ResourceSpans().AppendEmpty()
	rss2.ScopeSpans().AppendEmpty().Spans().AppendEmpty().SetTraceID(traceID2)
	storage.Append(traceID2, rss2)

	storage.Delete(traceID1)

	_, found := storage.Take(traceID1)
	require.False(t, found)

	out2, found := storage.Take(traceID2)
	require.True(t, found)
	require.Equal(t, 1, out2.SpanCount())
}

func TestTakeRemovesOnlyTargetTrace(t *testing.T) {
	f := NewFactory()
	cfg := f.CreateDefaultConfig().(*Config)
	cfg.Directory = t.TempDir()

	ext, err := f.Create(
		t.Context(),
		extensiontest.NewNopSettings(f.Type()),
		cfg,
	)
	require.NoError(t, err)
	require.NotNil(t, ext)

	require.NoError(t, ext.Start(t.Context(), componenttest.NewNopHost()))
	t.Cleanup(func() {
		require.NoError(t, ext.Shutdown(t.Context()))
	})

	storage, ok := ext.(tailStorage)
	require.True(t, ok)

	traceID1 := pcommon.TraceID([16]byte{9, 9, 9, 1})
	traceID2 := pcommon.TraceID([16]byte{9, 9, 9, 2})

	for i := range 3 {
		td := ptrace.NewTraces()
		rss := td.ResourceSpans().AppendEmpty()
		span := rss.ScopeSpans().AppendEmpty().Spans().AppendEmpty()
		span.SetTraceID(traceID1)
		span.SetSpanID(pcommon.SpanID([8]byte{byte(i + 1)}))
		storage.Append(traceID1, rss)
	}

	td2 := ptrace.NewTraces()
	rss2 := td2.ResourceSpans().AppendEmpty()
	rss2.ScopeSpans().AppendEmpty().Spans().AppendEmpty().SetTraceID(traceID2)
	storage.Append(traceID2, rss2)

	out1, found := storage.Take(traceID1)
	require.True(t, found)
	require.Equal(t, 3, out1.SpanCount())

	_, found = storage.Take(traceID1)
	require.False(t, found)

	out2, found := storage.Take(traceID2)
	require.True(t, found)
	require.Equal(t, 1, out2.SpanCount())
}
