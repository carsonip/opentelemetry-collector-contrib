// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

package tailsamplingprocessor // import "github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor"

import "go.opentelemetry.io/collector/featuregate"

var tailStorageExtensionFeatureGate = featuregate.GlobalRegistry().MustRegister(
	"processor.tailsamplingprocessor.tailstorageextension",
	featuregate.StageAlpha,
	featuregate.WithRegisterDescription("When enabled, allows configuring tail_storage to use a tail storage extension implementation."),
)
