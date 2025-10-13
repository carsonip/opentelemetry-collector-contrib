// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package tracelimiter // import "github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor/internal/tracelimiter"

import (
	"context"
	"time"

	"go.opentelemetry.io/collector/pdata/pcommon"
)

// NoopTracesLimiter is a no-op limiter, effectively unlimited.
type NoopTracesLimiter struct{}

func NewNoopTracesLimiter() *NoopTracesLimiter {
	return &NoopTracesLimiter{}
}

func (l *NoopTracesLimiter) AcceptTrace(ctx context.Context, _ pcommon.TraceID, _ time.Time) {
	return
}

func (l *NoopTracesLimiter) OnDeleteTrace() {
	return
}
