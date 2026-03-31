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
  --sampling-strategy <value>   tail_sampling.sampling_strategy (default: trace-complete)
  --policy <value>              tail_sampling policy: always_sample|probabilistic (default: always_sample)
  --sampling-percentage <float> probabilistic sampling percentage (default: 1)
  --duration <duration>         Requested load duration (default: 2 * decision_wait)
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
SAMPLING_STRATEGY="trace-complete"
POLICY="always_sample"
SAMPLING_PERCENTAGE="1"
REQUESTED_DURATION=""
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
    --sampling-strategy) SAMPLING_STRATEGY="$2"; shift 2 ;;
    --policy) POLICY="$2"; shift 2 ;;
    --sampling-percentage) SAMPLING_PERCENTAGE="$2"; shift 2 ;;
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

if [[ "$POLICY" != "always_sample" && "$POLICY" != "probabilistic" ]]; then
  echo "invalid --policy: $POLICY (expected always_sample or probabilistic)" >&2
  exit 1
fi

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
MIN_SEC=$(mul_float "$DW_SEC" "2")
if [[ -n "$REQUESTED_DURATION" ]]; then
  REQ_SEC=$(duration_to_seconds "$REQUESTED_DURATION")
  LOAD_SEC="$REQ_SEC"
else
  LOAD_SEC="$MIN_SEC"
  REQUESTED_DURATION=$(to_go_seconds "$MIN_SEC")
fi
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

port_is_free() {
  local port="$1"
  if ss -H -ltn "sport = :${port}" 2>/dev/null | awk 'NF { found = 1 } END { exit found ? 0 : 1 }'; then
    return 1
  fi
  return 0
}

allocate_metrics_port() {
  local attempt port
  for attempt in $(seq 1 200); do
    port=$((20000 + (RANDOM % 40000)))
    if port_is_free "$port"; then
      echo "$port"
      return 0
    fi
  done
  echo "failed to allocate a free metrics port" >&2
  return 1
}

rss_kb() {
  local pid="$1"
  awk '/VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0"
}

proc_cpu_jiffies() {
  local pid="$1"
  awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null || echo ""
}

capture_metrics() {
  local port="$1"
  local out="$2"
  curl -fsS "http://127.0.0.1:${port}/metrics" >"$out"
}

sum_prom_metric_from_file() {
  local file="$1"
  local metric="$2"
  awk -v metric="$metric" '
    $0 ~ "^" metric "([ {]|$)" { sum += $NF; found = 1 }
    END {
      if (found) {
        printf "%.0f\n", sum + 0
      } else {
        print ""
      }
    }' "$file"
}

sum_prom_metric_with_label_from_file() {
  local file="$1"
  local metric="$2"
  local label_filter="$3"
  awk -v metric="$metric" -v label_filter="$label_filter" '
    $0 ~ "^" metric "([ {]|$)" && index($0, label_filter) > 0 { sum += $NF; found = 1 }
    END {
      if (found) {
        printf "%.0f\n", sum + 0
      } else {
        print ""
      }
    }' "$file"
}

extract_metric_any_name() {
  local file="$1"
  shift
  local metric
  for metric in "$@"; do
    local v
    v=$(sum_prom_metric_from_file "$file" "$metric")
    if [[ -n "$v" ]]; then
      echo "$v"
      return 0
    fi
  done
  echo "0"
}

extract_metric_any_name_with_label() {
  local file="$1"
  local label_filter="$2"
  shift 2
  local metric
  for metric in "$@"; do
    local v
    v=$(sum_prom_metric_with_label_from_file "$file" "$metric" "$label_filter")
    if [[ -n "$v" ]]; then
      echo "$v"
      return 0
    fi
  done
  echo "0"
}

make_config() {
  local mode="$1"
  local cfg="$2"
  local pebble_dir="$3"
  local metrics_port="$4"
  local policy_block
  if [[ "$POLICY" == "probabilistic" ]]; then
    policy_block=$(cat <<EOF
    policies:
      - name: probabilistic
        type: probabilistic
        probabilistic:
          sampling_percentage: ${SAMPLING_PERCENTAGE}
EOF
)
  else
    policy_block=$(cat <<'EOF'
    policies:
      - name: always
        type: always_sample
EOF
)
  fi

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
    sampling_strategy: ${SAMPLING_STRATEGY}
    num_traces: ${NUM_TRACES}
${policy_block}

exporters:
  nop:

service:
  telemetry:
    metrics:
      level: detailed
      readers:
        - pull:
            exporter:
              prometheus:
                host: 127.0.0.1
                port: ${metrics_port}
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
    sampling_strategy: ${SAMPLING_STRATEGY}
    num_traces: ${NUM_TRACES}
    tail_storage: tail_storage_pebble/local
${policy_block}

exporters:
  nop:

service:
  extensions: [tail_storage_pebble/local]
  telemetry:
    metrics:
      level: detailed
      readers:
        - pull:
            exporter:
              prometheus:
                host: 127.0.0.1
                port: ${metrics_port}
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
  local metrics_start_file="$mode_dir/metrics_start.prom"
  local metrics_end_file="$mode_dir/metrics_end.prom"
  local pebble_dir="$mode_dir/pebble"
  local metrics_port
  mkdir -p "$mode_dir" "$pebble_dir"

  metrics_port=$(allocate_metrics_port)
  make_config "$mode" "$cfg" "$pebble_dir" "$metrics_port"
  : >"$samples"
  echo "elapsed_seconds,rss_kb,cpu_pct" >>"$samples"

  "$OTELCOL_BIN" --config "$cfg" >"$log" 2>&1 &
  COLLECTOR_PID=$!

  if ! wait_for_port "127.0.0.1" "$OTLP_PORT" 20; then
    echo "collector failed to open port for mode=$mode; see $log" >&2
    return 1
  fi
  if ! wait_for_port "127.0.0.1" "$metrics_port" 20; then
    echo "collector failed to open metrics port for mode=$mode; see $log" >&2
    return 1
  fi
  if ! capture_metrics "$metrics_port" "$metrics_start_file"; then
    echo "collector metrics endpoint unavailable for mode=$mode; see $log" >&2
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
  local hz prev_cpu_jiffies prev_cpu_time_s
  start_s=$(date +%s.%N)
  hz=$(getconf CLK_TCK 2>/dev/null || echo "100")
  prev_cpu_jiffies=$(proc_cpu_jiffies "$COLLECTOR_PID")
  prev_cpu_time_s="$start_s"
  total_runtime_s=$(awk -v a="$LOAD_SEC" -v b="$POST_WAIT_SEC" 'BEGIN { printf "%.9f", (a + 0) + (b + 0) }')

  while true; do
    now_s=$(date +%s.%N)
    elapsed_s=$(awk -v n="$now_s" -v s="$start_s" 'BEGIN { printf "%.9f", (n + 0) - (s + 0) }')
    local rss
    local cpu_jiffies cpu_pct
    rss=$(rss_kb "$COLLECTOR_PID")
    cpu_jiffies=$(proc_cpu_jiffies "$COLLECTOR_PID")
    cpu_pct=$(awk -v curr="${cpu_jiffies:-}" -v prev="${prev_cpu_jiffies:-}" -v now="$now_s" -v ptime="$prev_cpu_time_s" -v hz="$hz" '
      BEGIN {
        if (curr == "" || prev == "" || hz + 0 <= 0) {
          print "0.00"
          exit
        }
        dt = (now + 0) - (ptime + 0)
        dj = (curr + 0) - (prev + 0)
        if (dt <= 0 || dj < 0) {
          print "0.00"
          exit
        }
        printf "%.2f", (dj / (hz + 0)) / dt * 100.0
      }')
    awk -v elapsed="$elapsed_s" -v rss="$rss" -v cpu="$cpu_pct" 'BEGIN { printf "%.3f,%d,%.2f\n", elapsed + 0, rss + 0, cpu + 0 }' >>"$samples"
    prev_cpu_jiffies="$cpu_jiffies"
    prev_cpu_time_s="$now_s"

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

  if ! capture_metrics "$metrics_port" "$metrics_end_file"; then
    echo "collector metrics endpoint unavailable after load for mode=$mode; see $log" >&2
    return 1
  fi

  kill "$COLLECTOR_PID" >/dev/null 2>&1 || true
  wait "$COLLECTOR_PID" >/dev/null 2>&1 || true
  COLLECTOR_PID=""

  local recv_start recv_end recv_delta recv_sps
  local sampled_traces_start sampled_traces_end sampled_traces_delta sampled_traces_sps
  local non_sampled_traces_start non_sampled_traces_end non_sampled_traces_delta
  local total_trace_decisions_delta sampled_rate_pct
  recv_start=$(extract_metric_any_name "$metrics_start_file" "otelcol_receiver_accepted_spans" "otelcol_receiver_accepted_spans_total")
  recv_end=$(extract_metric_any_name "$metrics_end_file" "otelcol_receiver_accepted_spans" "otelcol_receiver_accepted_spans_total")
  sampled_traces_start=$(extract_metric_any_name_with_label "$metrics_start_file" 'sampled="true"' "otelcol_processor_tail_sampling_global_count_traces_sampled" "otelcol_processor_tail_sampling_global_count_traces_sampled_total")
  sampled_traces_end=$(extract_metric_any_name_with_label "$metrics_end_file" 'sampled="true"' "otelcol_processor_tail_sampling_global_count_traces_sampled" "otelcol_processor_tail_sampling_global_count_traces_sampled_total")
  non_sampled_traces_start=$(extract_metric_any_name_with_label "$metrics_start_file" 'sampled="false"' "otelcol_processor_tail_sampling_global_count_traces_sampled" "otelcol_processor_tail_sampling_global_count_traces_sampled_total")
  non_sampled_traces_end=$(extract_metric_any_name_with_label "$metrics_end_file" 'sampled="false"' "otelcol_processor_tail_sampling_global_count_traces_sampled" "otelcol_processor_tail_sampling_global_count_traces_sampled_total")
  recv_delta=$(awk -v e="$recv_end" -v s="$recv_start" 'BEGIN { d = (e + 0) - (s + 0); if (d < 0) d = 0; printf "%.0f", d }')
  sampled_traces_delta=$(awk -v e="$sampled_traces_end" -v s="$sampled_traces_start" 'BEGIN { d = (e + 0) - (s + 0); if (d < 0) d = 0; printf "%.0f", d }')
  non_sampled_traces_delta=$(awk -v e="$non_sampled_traces_end" -v s="$non_sampled_traces_start" 'BEGIN { d = (e + 0) - (s + 0); if (d < 0) d = 0; printf "%.0f", d }')
  total_trace_decisions_delta=$(awk -v st="$sampled_traces_delta" -v nst="$non_sampled_traces_delta" 'BEGIN { printf "%.0f", (st + 0) + (nst + 0) }')
  recv_sps=$(awk -v d="$recv_delta" -v t="$LOAD_SEC" 'BEGIN { if (t + 0 <= 0) { print "0.00"; exit } printf "%.2f", (d + 0) / (t + 0) }')
  sampled_traces_sps=$(awk -v d="$sampled_traces_delta" -v t="$LOAD_SEC" 'BEGIN { if (t + 0 <= 0) { print "0.00"; exit } printf "%.2f", (d + 0) / (t + 0) }')
  sampled_rate_pct=$(awk -v st="$sampled_traces_delta" -v td="$total_trace_decisions_delta" 'BEGIN { if (td + 0 <= 0) { print "0.00"; exit } printf "%.2f", ((st + 0) / (td + 0)) * 100.0 }')

  MODE="$mode" RECV_DELTA="$recv_delta" RECV_SPS="$recv_sps" SAMPLED_TRACES_DELTA="$sampled_traces_delta" SAMPLED_TRACES_SPS="$sampled_traces_sps" SAMPLED_RATE_PCT="$sampled_rate_pct" awk -F',' '
    NR==1 { next }
    {
      c++
      sum_rss+=$2
      if ($2 > max_rss) max_rss=$2
      last_rss=$2
      sum_cpu+=$3
      if ($3 > max_cpu) max_cpu=$3
      last_cpu=$3
    }
    END {
      if (c == 0) {
        printf "mode=%s samples=0 peak_mb=0 avg_mb=0 final_mb=0 cpu_avg_pct=0 cpu_peak_pct=0 cpu_final_pct=0 recv_spans=0 sampled_traces=0 recv_sps=0 sampled_traces_sps=0 sampled_rate_pct=0\n", ENVIRON["MODE"]
        exit
      }
      printf "mode=%s samples=%d peak_mb=%.2f avg_mb=%.2f final_mb=%.2f cpu_avg_pct=%.2f cpu_peak_pct=%.2f cpu_final_pct=%.2f recv_spans=%s sampled_traces=%s recv_sps=%s sampled_traces_sps=%s sampled_rate_pct=%s\n",
             ENVIRON["MODE"], c, max_rss/1024.0, (sum_rss/c)/1024.0, last_rss/1024.0, (sum_cpu/c), max_cpu, last_cpu,
             ENVIRON["RECV_DELTA"], ENVIRON["SAMPLED_TRACES_DELTA"], ENVIRON["RECV_SPS"], ENVIRON["SAMPLED_TRACES_SPS"], ENVIRON["SAMPLED_RATE_PCT"]
    }' "$samples"
}

echo "=== tail sampling memory benchmark ==="
echo "decision_wait:      $DECISION_WAIT"
echo "sampling_strategy:  $SAMPLING_STRATEGY"
echo "policy:             $POLICY"
if [[ "$POLICY" == "probabilistic" ]]; then
  echo "sampling_percentage:${SAMPLING_PERCENTAGE}"
fi
echo "requested_duration: $REQUESTED_DURATION"
echo "effective_duration: $LOAD_DURATION"
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
echo "Collector metrics snapshots:"
echo "  $OUTPUT_DIR/inmemory/metrics_start.prom"
echo "  $OUTPUT_DIR/inmemory/metrics_end.prom"
echo "  $OUTPUT_DIR/pebble/metrics_start.prom"
echo "  $OUTPUT_DIR/pebble/metrics_end.prom"

