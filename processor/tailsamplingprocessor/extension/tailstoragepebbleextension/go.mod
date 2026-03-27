module github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor/extension/tailstoragepebbleextension

go 1.25.0

require (
	github.com/cockroachdb/pebble/v2 v2.1.4
	github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor v0.148.0
	github.com/stretchr/testify v1.11.1
	go.opentelemetry.io/collector/component v1.54.1-0.20260326211300-c04f6776a74c
	go.opentelemetry.io/collector/component/componenttest v0.148.1-0.20260326211300-c04f6776a74c
	go.opentelemetry.io/collector/confmap v1.54.1-0.20260326211300-c04f6776a74c
	go.opentelemetry.io/collector/consumer/consumertest v0.148.1-0.20260326211300-c04f6776a74c
	go.opentelemetry.io/collector/extension v1.54.1-0.20260326211300-c04f6776a74c
	go.opentelemetry.io/collector/extension/extensiontest v0.148.1-0.20260326211300-c04f6776a74c
	go.opentelemetry.io/collector/pdata v1.54.1-0.20260326211300-c04f6776a74c
	go.opentelemetry.io/collector/processor/processortest v0.148.1-0.20260326211300-c04f6776a74c
	go.uber.org/zap v1.27.1
)

replace github.com/open-telemetry/opentelemetry-collector-contrib/processor/tailsamplingprocessor => ../..

require (
	github.com/DataDog/zstd v1.5.7 // indirect
	github.com/RaduBerinde/axisds v0.1.0 // indirect
	github.com/RaduBerinde/btreemap v0.0.0-20250419174037-3d62b7205d54 // indirect
	github.com/alecthomas/participle/v2 v2.1.4 // indirect
	github.com/antchfx/xmlquery v1.5.1 // indirect
	github.com/antchfx/xpath v1.3.6 // indirect
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/cockroachdb/crlib v0.0.0-20241112164430-1264a2edc35b // indirect
	github.com/cockroachdb/errors v1.11.3 // indirect
	github.com/cockroachdb/logtags v0.0.0-20230118201751-21c54148d20b // indirect
	github.com/cockroachdb/redact v1.1.5 // indirect
	github.com/cockroachdb/swiss v0.0.0-20251224182025-b0f6560f979b // indirect
	github.com/cockroachdb/tokenbucket v0.0.0-20230807174530-cc333fc44b06 // indirect
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/elastic/go-grok v0.3.1 // indirect
	github.com/elastic/lunes v0.2.0 // indirect
	github.com/getsentry/sentry-go v0.27.0 // indirect
	github.com/go-logr/logr v1.4.3 // indirect
	github.com/go-logr/stdr v1.2.2 // indirect
	github.com/go-viper/mapstructure/v2 v2.5.0 // indirect
	github.com/gobwas/glob v0.2.3 // indirect
	github.com/goccy/go-json v0.10.6 // indirect
	github.com/gogo/protobuf v1.3.2 // indirect
	github.com/golang/groupcache v0.0.0-20241129210726-2c02b8208cf8 // indirect
	github.com/golang/protobuf v1.5.4 // indirect
	github.com/golang/snappy v0.0.5-0.20231225225746-43d5d4cd4e0e // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/hashicorp/go-version v1.8.0 // indirect
	github.com/hashicorp/golang-lru v1.0.2 // indirect
	github.com/hashicorp/golang-lru/v2 v2.0.7 // indirect
	github.com/iancoleman/strcase v0.3.0 // indirect
	github.com/json-iterator/go v1.1.12 // indirect
	github.com/klauspost/compress v1.18.2 // indirect
	github.com/klauspost/cpuid/v2 v2.3.0 // indirect
	github.com/knadh/koanf/maps v0.1.2 // indirect
	github.com/knadh/koanf/providers/confmap v1.0.0 // indirect
	github.com/knadh/koanf/v2 v2.3.3 // indirect
	github.com/kr/pretty v0.3.1 // indirect
	github.com/kr/text v0.2.0 // indirect
	github.com/magefile/mage v1.15.0 // indirect
	github.com/matttproud/golang_protobuf_extensions v1.0.4 // indirect
	github.com/minio/minlz v1.0.1-0.20250507153514-87eb42fe8882 // indirect
	github.com/mitchellh/copystructure v1.2.0 // indirect
	github.com/mitchellh/reflectwalk v1.0.2 // indirect
	github.com/modern-go/concurrent v0.0.0-20180306012644-bacd9c7ef1dd // indirect
	github.com/modern-go/reflect2 v1.0.3-0.20250322232337-35a7c28c31ee // indirect
	github.com/open-telemetry/opentelemetry-collector-contrib/internal/coreinternal v0.148.0 // indirect
	github.com/open-telemetry/opentelemetry-collector-contrib/internal/filter v0.148.0 // indirect
	github.com/open-telemetry/opentelemetry-collector-contrib/pkg/ottl v0.148.0 // indirect
	github.com/pkg/errors v0.9.1 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	github.com/prometheus/client_golang v1.16.0 // indirect
	github.com/prometheus/client_model v0.3.0 // indirect
	github.com/prometheus/common v0.42.0 // indirect
	github.com/prometheus/procfs v0.10.1 // indirect
	github.com/rogpeppe/go-internal v1.14.1 // indirect
	github.com/twmb/murmur3 v1.1.8 // indirect
	github.com/ua-parser/uap-go v0.0.0-20251207011819-db9adb27a0b8 // indirect
	github.com/zeebo/xxh3 v1.1.0 // indirect
	go.opentelemetry.io/auto/sdk v1.2.1 // indirect
	go.opentelemetry.io/collector/client v1.54.1-0.20260326211300-c04f6776a74c // indirect
	go.opentelemetry.io/collector/component/componentstatus v0.148.1-0.20260326211300-c04f6776a74c // indirect
	go.opentelemetry.io/collector/consumer v1.54.1-0.20260326211300-c04f6776a74c // indirect
	go.opentelemetry.io/collector/consumer/xconsumer v0.148.1-0.20260326211300-c04f6776a74c // indirect
	go.opentelemetry.io/collector/featuregate v1.54.1-0.20260326211300-c04f6776a74c // indirect
	go.opentelemetry.io/collector/internal/componentalias v0.148.1-0.20260326211300-c04f6776a74c // indirect
	go.opentelemetry.io/collector/pdata/pprofile v0.148.1-0.20260326211300-c04f6776a74c // indirect
	go.opentelemetry.io/collector/pdata/testdata v0.148.1-0.20260326211300-c04f6776a74c // indirect
	go.opentelemetry.io/collector/pipeline v1.54.1-0.20260326211300-c04f6776a74c // indirect
	go.opentelemetry.io/collector/processor v1.54.1-0.20260326211300-c04f6776a74c // indirect
	go.opentelemetry.io/collector/processor/xprocessor v0.148.1-0.20260326211300-c04f6776a74c // indirect
	go.opentelemetry.io/otel v1.42.0 // indirect
	go.opentelemetry.io/otel/metric v1.42.0 // indirect
	go.opentelemetry.io/otel/sdk v1.42.0 // indirect
	go.opentelemetry.io/otel/sdk/metric v1.42.0 // indirect
	go.opentelemetry.io/otel/trace v1.42.0 // indirect
	go.uber.org/multierr v1.11.0 // indirect
	go.yaml.in/yaml/v3 v3.0.4 // indirect
	golang.org/x/exp v0.0.0-20240506185415-9bf2ced13842 // indirect
	golang.org/x/net v0.51.0 // indirect
	golang.org/x/sys v0.41.0 // indirect
	golang.org/x/text v0.34.0 // indirect
	golang.org/x/time v0.15.0 // indirect
	google.golang.org/grpc v1.79.3 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)
