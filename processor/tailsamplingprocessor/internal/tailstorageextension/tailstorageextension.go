// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package tailstorageextension // import "github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor/internal/tailstorageextension"

import (
	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/ptrace"
)

// TailStorage stores span batches keyed by trace ID for tail-sampling decisions.
//
// Implementations may be in-memory or external (for example, disk-backed),
// but all implementations must provide the same logical behavior:
//   - Append adds spans to the current trace payload for a trace ID.
//   - Take returns the current payload exactly once and makes it unavailable
//     for future reads.
//   - Delete removes any current payload and is safe to call multiple times.
//
// Implementations may perform physical cleanup lazily as long as the operations
// above are logically immediate from the caller's perspective.
//
// Concurrency contract:
//   - TailStorage does not require implementations to provide internal locking.
//   - The current caller is tailsamplingprocessor, and it serializes calls.
//   - Implementations may add internal synchronization, but it is optional.
type TailStorage interface {
	// Append adds a resource-span batch to the current payload for traceID.
	// A moved-from rss must not be used by the caller after this call.
	Append(traceID pcommon.TraceID, rss ptrace.ResourceSpans)

	// Take returns and removes all stored spans for a trace ID.
	//
	// If the trace exists, ok is true and returned spans belong to the caller.
	// A subsequent Take for the same traceID must return ok=false until Append is
	// called again for that traceID.
	Take(traceID pcommon.TraceID) (ptrace.Traces, bool)

	// Delete removes any currently stored payload for traceID.
	//
	// Delete must be idempotent. After Delete returns, Take(traceID) must return
	// ok=false until new data is appended for traceID.
	Delete(traceID pcommon.TraceID)
}
