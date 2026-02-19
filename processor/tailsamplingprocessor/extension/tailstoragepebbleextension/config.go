// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package tailstoragepebbleextension // import "github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor/extension/tailstoragepebbleextension"

import "errors"

type Config struct {
	// Directory is where the extension stores Pebble DB files.
	Directory string `mapstructure:"directory"`
}

func (c *Config) Validate() error {
	if c.Directory == "" {
		return errors.New("directory must be set")
	}
	return nil
}
