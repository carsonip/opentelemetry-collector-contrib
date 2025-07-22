// Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
// or more contributor license agreements. Licensed under the Elastic License 2.0;
// you may not use this file except in compliance with the Elastic License 2.0.

package eventstorage

import (
	"go.opentelemetry.io/collector/pdata/ptrace"
)

// ProtobufCodec is an implementation of Codec, using protobuf encoding.
type ProtobufCodec struct{}

// DecodeEvent decodes data as protobuf into event.
func (ProtobufCodec) DecodeEvent(data []byte, event *Events) error {
	m := ptrace.ProtoUnmarshaler{}
	t, err := m.UnmarshalTraces(data)
	if err != nil {
		return err
	}
	*event = t
	return nil
}

// EncodeEvent encodes event as protobuf.
func (ProtobufCodec) EncodeEvent(event *Events) ([]byte, error) {
	m := ptrace.ProtoMarshaler{}
	return m.MarshalTraces(*event)
}
