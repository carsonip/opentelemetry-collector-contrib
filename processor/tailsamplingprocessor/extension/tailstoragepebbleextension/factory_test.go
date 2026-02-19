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
