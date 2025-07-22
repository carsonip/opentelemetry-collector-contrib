// Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
// or more contributor license agreements. Licensed under the Elastic License 2.0;
// you may not use this file except in compliance with the Elastic License 2.0.

package eventstorage

import (
	"encoding/binary"
	"time"

	"go.opentelemetry.io/collector/pdata/ptrace"
)

// ProtobufCodec is an implementation of Codec, using protobuf encoding.
type ProtobufCodec struct{}

// DecodeEvents decodes data as protobuf into event.
func (ProtobufCodec) DecodeEvents(data []byte, event *Events) error {
	m := ptrace.ProtoUnmarshaler{}
	traces, err := m.UnmarshalTraces(data[16:])
	if err != nil {
		return err
	}
	event.Traces = traces
	event.SpanCount = binary.BigEndian.Uint64(data[0:8])
	ts := int64(binary.BigEndian.Uint64(data[8:16]))
	event.ArrivalTime = time.Unix(0, ts)
	return nil
}

// EncodeEvents encodes event as protobuf.
func (ProtobufCodec) EncodeEvents(event *Events) ([]byte, error) {
	m := ptrace.ProtoMarshaler{}
	b, err := m.MarshalTraces(event.Traces)
	if err != nil {
		return nil, err
	}
	payload := make([]byte, 16+len(b))
	copy(payload[16:], b)
	binary.BigEndian.PutUint64(payload[0:8], event.SpanCount)
	binary.BigEndian.PutUint64(payload[8:16], uint64(event.ArrivalTime.UnixNano()))
	return payload, nil
}
