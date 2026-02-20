#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

usage() {
  cat <<'EOF'
Compare tailsamplingprocessor memory usage under high load.

Runs two scenarios:
  1) default in-memory tail storage
  2) tail_storage_pebble extension

The telemetry generation duration is always clamped to at least:
  2 * decision_wait

Usage:
  bash processor/tailsamplingprocessor/benchmark_memory.sh [options]

Options:
  --decision-wait <duration>    Tail sampling decision_wait (default: 5s)
  --duration <duration>         Requested load duration (default: 20s)
  --rate <float>                Traces per second per worker (default: 2000)
  --workers <int>               telemetrygen workers (default: 4)
  --child-spans <int>           Child spans per trace (default: 2)
  --load-size-mb <int>          Telemetry payload size per span in MB (default: 0)
  --batch-size <int>            telemetrygen batch size (default: 200)
  --num-traces <int>            tail_sampling.num_traces (default: 500000)
  --sample-interval <seconds>   RSS sample interval (default: 0.5)
  --otlp-port <int>             OTLP gRPC port for collector (default: 4317)
  --otelcol-bin <path>          Use existing otelcontribcol binary
  --telemetrygen-bin <path>     Use existing telemetrygen binary
  --output-dir <path>           Directory for logs/samples (default: temp dir)
  --skip-build                  Do not build binaries automatically
  --keep-artifacts              Keep temporary files when output-dir omitted
  -h, --help                    Show this help
EOF
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)

DECISION_WAIT="5s"
REQUESTED_DURATION="20s"
RATE="2000"
WORKERS="4"
CHILD_SPANS="2"
LOAD_SIZE_MB="0"
BATCH_SIZE="200"
NUM_TRACES="500000"
SAMPLE_INTERVAL="0.5"
OTLP_PORT="4317"
OTELCOL_BIN=""
TELEMETRYGEN_BIN=""
OUTPUT_DIR=""
SKIP_BUILD="false"
KEEP_ARTIFACTS="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --decision-wait) DECISION_WAIT="$2"; shift 2 ;;
    --duration) REQUESTED_DURATION="$2"; shift 2 ;;
    --rate) RATE="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --child-spans) CHILD_SPANS="$2"; shift 2 ;;
    --load-size-mb) LOAD_SIZE_MB="$2"; shift 2 ;;
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --num-traces) NUM_TRACES="$2"; shift 2 ;;
    --sample-interval) SAMPLE_INTERVAL="$2"; shift 2 ;;
    --otlp-port) OTLP_PORT="$2"; shift 2 ;;
    --otelcol-bin) OTELCOL_BIN="$2"; shift 2 ;;
    --telemetrygen-bin) TELEMETRYGEN_BIN="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD="true"; shift ;;
    --keep-artifacts) KEEP_ARTIFACTS="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

duration_to_seconds() {
  local d="$1"
  if [[ -z "$d" || "$d" == "0" ]]; then
    echo "0.000000000"
    return
  fi

  local rest="$d"
  local total="0.000000000"
  local num unit factor

  while [[ -n "$rest" ]]; do
    if [[ "$rest" =~ ^([+-]?[0-9]*\.?[0-9]+)(ns|us|µs|ms|s|m|h)(.*)$ ]]; then
      num="${BASH_REMATCH[1]}"
      unit="${BASH_REMATCH[2]}"
      rest="${BASH_REMATCH[3]}"
    else
      echo "invalid duration: $d" >&2
      return 1
    fi

    case "$unit" in
      ns) factor="0.000000001" ;;
      us|µs) factor="0.000001" ;;
      ms) factor="0.001" ;;
      s) factor="1" ;;
      m) factor="60" ;;
      h) factor="3600" ;;
      *) echo "invalid duration unit: $unit" >&2; return 1 ;;
    esac

    total=$(awk -v t="$total" -v n="$num" -v f="$factor" 'BEGIN { printf "%.9f", (t + 0) + (n + 0) * (f + 0) }')
  done

  echo "$total"
}

max_float() {
  awk -v a="$1" -v b="$2" 'BEGIN { if (a + 0 >= b + 0) printf "%.9f\n", a + 0; else printf "%.9f\n", b + 0 }'
}

mul_float() {
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.9f\n", (a + 0) * (b + 0) }'
}

to_go_seconds() {
  awk -v a="$1" 'BEGIN { printf "%.3fs\n", a + 0 }'
}

DW_SEC=$(duration_to_seconds "$DECISION_WAIT")
REQ_SEC=$(duration_to_seconds "$REQUESTED_DURATION")
MIN_SEC=$(mul_float "$DW_SEC" "2")
LOAD_SEC=$(max_float "$REQ_SEC" "$MIN_SEC")
LOAD_DURATION=$(to_go_seconds "$LOAD_SEC")
POST_WAIT_SEC=$(max_float "$DW_SEC" "1")

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR=$(mktemp -d -t tailsampling-membench-XXXXXX)
  CREATED_OUTPUT_DIR="true"
else
  mkdir -p "$OUTPUT_DIR"
  CREATED_OUTPUT_DIR="false"
fi

cleanup() {
  if [[ "${COLLECTOR_PID:-}" != "" ]] && kill -0 "$COLLECTOR_PID" 2>/dev/null; then
    kill "$COLLECTOR_PID" >/dev/null 2>&1 || true
    wait "$COLLECTOR_PID" >/dev/null 2>&1 || true
  fi
  if [[ "${CREATED_OUTPUT_DIR:-false}" == "true" ]] && [[ "$KEEP_ARTIFACTS" != "true" ]]; then
    rm -rf "$OUTPUT_DIR"
  fi
}
trap cleanup EXIT

if [[ "$SKIP_BUILD" != "true" ]]; then
  if [[ -z "$OTELCOL_BIN" ]]; then
    OTELCOL_BIN="$OUTPUT_DIR/otelcontribcol"
    (cd "$REPO_ROOT/cmd/otelcontribcol" && go build -o "$OTELCOL_BIN" .)
  fi
  if [[ -z "$TELEMETRYGEN_BIN" ]]; then
    TELEMETRYGEN_BIN="$OUTPUT_DIR/telemetrygen"
    (cd "$REPO_ROOT/cmd/telemetrygen" && go build -o "$TELEMETRYGEN_BIN" .)
  fi
fi

: "${OTELCOL_BIN:?missing --otelcol-bin or build step}"
: "${TELEMETRYGEN_BIN:?missing --telemetrygen-bin or build step}"

wait_for_port() {
  local host="$1"
  local port="$2"
  local timeout_sec="$3"
  local start
  start=$(date +%s)
  while true; do
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout_sec )); then
      return 1
    fi
    sleep 0.2
  done
}

rss_kb() {
  local pid="$1"
  awk '/VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0"
}

make_config() {
  local mode="$1"
  local cfg="$2"
  local pebble_dir="$3"
  if [[ "$mode" == "inmemory" ]]; then
    cat >"$cfg" <<EOF
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:${OTLP_PORT}

processors:
  tail_sampling:
    decision_wait: ${DECISION_WAIT}
    num_traces: ${NUM_TRACES}
    policies:
      - name: always
        type: always_sample

exporters:
  nop:

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [tail_sampling]
      exporters: [nop]
EOF
    return
  fi

  cat >"$cfg" <<EOF
extensions:
  tail_storage_pebble/local:
    directory: ${pebble_dir}

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:${OTLP_PORT}

processors:
  tail_sampling:
    decision_wait: ${DECISION_WAIT}
    num_traces: ${NUM_TRACES}
    tail_storage: tail_storage_pebble/local
    policies:
      - name: always
        type: always_sample

exporters:
  nop:

service:
  extensions: [tail_storage_pebble/local]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [tail_sampling]
      exporters: [nop]
EOF
}

run_mode() {
  local mode="$1"
  local mode_dir="$OUTPUT_DIR/$mode"
  local cfg="$mode_dir/config.yaml"
  local log="$mode_dir/collector.log"
  local samples="$mode_dir/rss_samples.csv"
  local pebble_dir="$mode_dir/pebble"
  mkdir -p "$mode_dir" "$pebble_dir"

  make_config "$mode" "$cfg" "$pebble_dir"
  : >"$samples"
  echo "elapsed_seconds,rss_kb" >>"$samples"

  "$OTELCOL_BIN" --config "$cfg" >"$log" 2>&1 &
  COLLECTOR_PID=$!

  if ! wait_for_port "127.0.0.1" "$OTLP_PORT" 20; then
    echo "collector failed to open port for mode=$mode; see $log" >&2
    return 1
  fi

  "$TELEMETRYGEN_BIN" traces \
    --otlp-endpoint "127.0.0.1:${OTLP_PORT}" \
    --otlp-insecure \
    --duration "$LOAD_DURATION" \
    --workers "$WORKERS" \
    --rate "$RATE" \
    --child-spans "$CHILD_SPANS" \
    --size "$LOAD_SIZE_MB" \
    --batch \
    --batch-size "$BATCH_SIZE" \
    >/dev/null 2>&1 &
  local telemetry_pid=$!

  local start_s now_s elapsed_s total_runtime_s
  start_s=$(date +%s.%N)
  total_runtime_s=$(awk -v a="$LOAD_SEC" -v b="$POST_WAIT_SEC" 'BEGIN { printf "%.9f", (a + 0) + (b + 0) }')

  while true; do
    now_s=$(date +%s.%N)
    elapsed_s=$(awk -v n="$now_s" -v s="$start_s" 'BEGIN { printf "%.9f", (n + 0) - (s + 0) }')
    local rss
    rss=$(rss_kb "$COLLECTOR_PID")
    awk -v elapsed="$elapsed_s" -v rss="$rss" 'BEGIN { printf "%.3f,%d\n", elapsed + 0, rss + 0 }' >>"$samples"

    local telemetry_alive="false"
    if kill -0 "$telemetry_pid" 2>/dev/null; then
      telemetry_alive="true"
    fi

    if [[ "$telemetry_alive" == "false" ]] && awk -v e="$elapsed_s" -v t="$total_runtime_s" 'BEGIN { exit !(e + 0 >= t + 0) }'; then
      break
    fi
    sleep "$SAMPLE_INTERVAL"
  done

  wait "$telemetry_pid"

  kill "$COLLECTOR_PID" >/dev/null 2>&1 || true
  wait "$COLLECTOR_PID" >/dev/null 2>&1 || true
  COLLECTOR_PID=""

  MODE="$mode" awk -F',' '
    NR==1 { next }
    {
      c++
      sum+=$2
      if ($2 > max) max=$2
      last=$2
    }
    END {
      if (c == 0) {
        printf "mode=%s samples=0 peak_mb=0 avg_mb=0 final_mb=0\n", ENVIRON["MODE"]
        exit
      }
      printf "mode=%s samples=%d peak_mb=%.2f avg_mb=%.2f final_mb=%.2f\n",
             ENVIRON["MODE"], c, max/1024.0, (sum/c)/1024.0, last/1024.0
    }' "$samples"
}

echo "=== tail sampling memory benchmark ==="
echo "decision_wait:      $DECISION_WAIT"
echo "requested_duration: $REQUESTED_DURATION"
echo "effective_duration: $LOAD_DURATION (>= 2 * decision_wait)"
echo "rate/worker:        $RATE spans/s"
echo "workers:            $WORKERS"
echo "child_spans:        $CHILD_SPANS"
echo "load_size_mb:       $LOAD_SIZE_MB"
echo "sample_interval:    ${SAMPLE_INTERVAL}s"
echo "output_dir:         $OUTPUT_DIR"
echo

INMEMORY_SUMMARY=$(run_mode "inmemory")
PEBBLE_SUMMARY=$(run_mode "pebble")

echo "=== results ==="
echo "$INMEMORY_SUMMARY"
echo "$PEBBLE_SUMMARY"
echo
echo "Raw RSS samples:"
echo "  $OUTPUT_DIR/inmemory/rss_samples.csv"
echo "  $OUTPUT_DIR/pebble/rss_samples.csv"
echo "Collector logs:"
echo "  $OUTPUT_DIR/inmemory/collector.log"
echo "  $OUTPUT_DIR/pebble/collector.log"

