// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package tailstoragepebbleextension // import "github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor/extension/tailstoragepebbleextension"

import (
	"context"

	"go.opentelemetry.io/collector/component"
	"go.opentelemetry.io/collector/extension"
)

var Type = component.MustNewType("tail_storage_pebble")

func NewFactory() extension.Factory {
	return extension.NewFactory(
		Type,
		createDefaultConfig,
		createExtension,
		component.StabilityLevelDevelopment,
	)
}

func createDefaultConfig() component.Config {
	return &Config{}
}

func createExtension(_ context.Context, settings extension.Settings, cfg component.Config) (extension.Extension, error) {
	return newExtension(settings, cfg.(*Config)), nil
}
