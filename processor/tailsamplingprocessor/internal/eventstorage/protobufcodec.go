// Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
// or more contributor license agreements. Licensed under the Elastic License 2.0;
// you may not use this file except in compliance with the Elastic License 2.0.

package eventstorage

import (
	"go.opentelemetry.io/collector/pdata/ptrace"
)

// ProtobufCodec is an implementation of Codec, using protobuf encoding.
type ProtobufCodec struct{}

// DecodeEvents decodes data as protobuf into event.
func (ProtobufCodec) DecodeEvents(data []byte, event *Events) error {
	m := ptrace.ProtoUnmarshaler{}
	traces, err := m.UnmarshalTraces(data)
	if err != nil {
		return err
	}
	*event = traces
	return nil
}

// EncodeEvents encodes event as protobuf.
func (ProtobufCodec) EncodeEvents(event *Events) ([]byte, error) {
	m := ptrace.ProtoMarshaler{}
	return m.MarshalTraces(*event)
}
