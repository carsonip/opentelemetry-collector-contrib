// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package tailstoragepebbleextension // import "github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor/extension/tailstoragepebbleextension"

import (
	"bytes"
	"encoding/binary"
	"path/filepath"
	"sync/atomic"

	"github.com/cockroachdb/pebble/v2"
	"github.com/cockroachdb/pebble/v2/bloom"
	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/ptrace"
	"go.uber.org/zap"
)

const traceIDSeparator byte = ':'

type pebbleTailStorage struct {
	db      *pebble.DB
	logger  *zap.Logger
	nextSeq atomic.Uint64
}

func newPebbleTailStorage(storageDir string, logger *zap.Logger) (*pebbleTailStorage, error) {
	if logger == nil {
		logger = zap.NewNop()
	}
	cache := pebble.NewCache(16 << 20)
	defer cache.Unref()

	opts := &pebble.Options{
		FormatMajorVersion: pebble.FormatColumnarBlocks,
		Logger:             logger.Sugar(),
		MemTableSize:       16 << 20,
		Comparer:           traceKeyComparer(),
		Cache:              cache,
	}
	opts.Levels[0] = pebble.LevelOptions{
		BlockSize:    32 << 10,
		FilterPolicy: bloom.FilterPolicy(10),
		FilterType:   pebble.TableFilter,
	}

	db, err := pebble.Open(filepath.Join(storageDir, "tailstorage"), opts)
	if err != nil {
		return nil, err
	}

	return &pebbleTailStorage{
		db:     db,
		logger: logger,
	}, nil
}

func (s *pebbleTailStorage) Close() error {
	return s.db.Close()
}

func (s *pebbleTailStorage) Append(traceID pcommon.TraceID, rss ptrace.ResourceSpans) {
	td := ptrace.NewTraces()
	rs := td.ResourceSpans().AppendEmpty()
	rss.MoveTo(rs)

	marshaler := &ptrace.ProtoMarshaler{}
	data, err := marshaler.MarshalTraces(td)
	if err != nil {
		s.logger.Warn("failed to marshal trace payload for tail storage", zap.Error(err))
		return
	}

	key := traceEntryKey(traceID, s.nextSeq.Add(1))
	if err := s.db.Set(key, data, pebble.NoSync); err != nil {
		s.logger.Warn("failed to append trace payload to tail storage", zap.Error(err))
	}
}

func (s *pebbleTailStorage) Take(traceID pcommon.TraceID) (ptrace.Traces, bool) {
	prefix := tracePrefix(traceID)
	out := s.readByTracePrefix(prefix)
	if out.ResourceSpans().Len() == 0 {
		return ptrace.Traces{}, false
	}
	end := tracePrefixUpperBound(prefix)
	if err := s.db.DeleteRange(prefix, end, pebble.NoSync); err != nil {
		s.logger.Warn("failed deleting taken trace payload range from tail storage", zap.Error(err))
	}
	return out, true
}

func (s *pebbleTailStorage) Delete(traceID pcommon.TraceID) {
	prefix := tracePrefix(traceID)
	// Delete all entries for the trace in one range operation instead of
	// iterating keys and deleting one-by-one.
	end := tracePrefixUpperBound(prefix)
	if err := s.db.DeleteRange(prefix, end, pebble.NoSync); err != nil {
		s.logger.Warn("failed deleting trace payload range from tail storage", zap.Error(err))
	}
}

func (s *pebbleTailStorage) readByTracePrefix(prefix []byte) ptrace.Traces {
	iter, err := s.db.NewIter(nil)
	if err != nil {
		s.logger.Warn("failed to create tail storage iterator", zap.Error(err))
		return ptrace.NewTraces()
	}
	defer iter.Close()

	// SeekPrefixGE enables prefix bloom filter usage when configured in Pebble options.
	if ok := iter.SeekPrefixGE(prefix); !ok {
		return ptrace.NewTraces()
	}

	unmarshaler := &ptrace.ProtoUnmarshaler{}
	result := ptrace.NewTraces()
	for ; iter.Valid(); iter.Next() {
		key := iter.Key()
		if !bytes.HasPrefix(key, prefix) {
			break
		}

		val, err := iter.ValueAndErr()
		if err != nil {
			s.logger.Warn("failed reading trace payload from tail storage", zap.Error(err))
			continue
		}

		td, err := unmarshaler.UnmarshalTraces(val)
		if err != nil {
			// Keep going and delete the corrupted payload to avoid repeated failures.
			s.logger.Warn("failed unmarshaling trace payload from tail storage", zap.Error(err))
			continue
		}

		rs := td.ResourceSpans()
		for i := 0; i < rs.Len(); i++ {
			dest := result.ResourceSpans().AppendEmpty()
			rs.At(i).MoveTo(dest)
		}
	}

	if err := iter.Error(); err != nil {
		s.logger.Warn("tail storage iterator error", zap.Error(err))
	}

	return result
}

func tracePrefix(traceID pcommon.TraceID) []byte {
	prefix := make([]byte, 17)
	copy(prefix[:16], traceID[:])
	prefix[16] = traceIDSeparator
	return prefix
}

func tracePrefixUpperBound(prefix []byte) []byte {
	upper := bytes.Clone(prefix)
	upper[len(upper)-1]++
	return upper
}

func traceEntryKey(traceID pcommon.TraceID, seq uint64) []byte {
	key := make([]byte, 25)
	copy(key[:16], traceID[:])
	key[16] = traceIDSeparator
	binary.BigEndian.PutUint64(key[17:], seq)
	return key
}

func traceKeyComparer() *pebble.Comparer {
	comparer := *pebble.DefaultComparer
	comparer.Split = func(k []byte) int {
		if idx := bytes.IndexByte(k, traceIDSeparator); idx != -1 {
			return idx + 1
		}
		return len(k)
	}
	comparer.Compare = func(a, b []byte) int {
		ap := comparer.Split(a)
		bp := comparer.Split(b)
		if prefixCmp := bytes.Compare(a[:ap], b[:bp]); prefixCmp != 0 {
			return prefixCmp
		}
		return comparer.ComparePointSuffixes(a[ap:], b[bp:])
	}
	comparer.Name = "tailsampling.TailStorageComparer"
	return &comparer
}
