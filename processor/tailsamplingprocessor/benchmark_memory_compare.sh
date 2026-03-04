#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BENCH_SCRIPT="$SCRIPT_DIR/benchmark_memory.sh"
VERBOSE="false"

usage() {
  cat <<'EOF'
Run tail sampling memory benchmark and print a compact matrix summary.

Usage:
  bash processor/tailsamplingprocessor/benchmark_memory_compare.sh [options] [benchmark_memory.sh options]

Options:
  --verbose                      Also print raw benchmark output
  -h, --help                     Show this help

Examples:
  bash processor/tailsamplingprocessor/benchmark_memory_compare.sh \
    --decision-wait 15s --duration 35s --rate 0 --workers 32 --child-spans 10 --load-size-mb 1

Notes:
  - All non-wrapper arguments are forwarded to benchmark_memory.sh.
  - The benchmark runs 4 scenarios:
      inmemory_root_false, inmemory_root_true, pebble_root_false, pebble_root_true
EOF
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ ! -x "$BENCH_SCRIPT" ]]; then
  chmod +x "$BENCH_SCRIPT"
fi

run_log=$(mktemp "${TMPDIR:-/tmp}/tailsampling-compare-XXXXXX.log")
cleanup() {
  rm -f "$run_log"
}
trap cleanup EXIT

if ! bash "$BENCH_SCRIPT" "${ARGS[@]}" >"$run_log" 2>&1; then
  echo "benchmark run failed; raw output:" >&2
  cat "$run_log" >&2
  exit 1
fi

if [[ "$VERBOSE" == "true" ]]; then
  cat "$run_log"
fi

extract_line() {
  local pattern="$1"
  awk -v p="$pattern" '$0 ~ p { print; exit }' "$run_log"
}

extract_value_after_colon() {
  local prefix="$1"
  awk -v key="$prefix" '
    index($0, key) == 1 {
      value = $0
      sub("^" key, "", value)
      gsub(/^[[:space:]]+/, "", value)
      print value
      exit
    }' "$run_log"
}

extract_field() {
  local line="$1"
  local key="$2"
  awk -v key="$key" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ "^" key "=") {
          split($i, kv, "=")
          print kv[2]
          exit
        }
      }
    }' <<<"$line"
}

inmemory_root_false_line=$(extract_line '^mode=inmemory_root_false ')
inmemory_root_true_line=$(extract_line '^mode=inmemory_root_true ')
pebble_root_false_line=$(extract_line '^mode=pebble_root_false ')
pebble_root_true_line=$(extract_line '^mode=pebble_root_true ')

if [[ -z "$inmemory_root_false_line" || -z "$inmemory_root_true_line" || -z "$pebble_root_false_line" || -z "$pebble_root_true_line" ]]; then
  echo "unable to parse benchmark output for all 4 modes; raw output:" >&2
  cat "$run_log" >&2
  exit 1
fi

decision_wait=$(extract_value_after_colon 'decision_wait:')
effective_duration=$(extract_value_after_colon 'effective_duration:')
rate_worker=$(extract_value_after_colon 'rate/worker:')
workers=$(extract_value_after_colon 'workers:')
child_spans=$(extract_value_after_colon 'child_spans:')
load_size_mb=$(extract_value_after_colon 'load_size_mb:')
sample_pct=$(extract_value_after_colon 'sample_pct:')
split_trace_requests=$(extract_value_after_colon 'split_trace_requests:')
output_dir=$(extract_value_after_colon 'output_dir:')

print_mode_row() {
  local label="$1"
  local line="$2"
  local samples peak avg final cpu_avg cpu_peak recv_sps trace_sps est_take_sps append_sps actual_take_sps sampled_sps
  samples=$(extract_field "$line" "samples")
  peak=$(extract_field "$line" "peak_mb")
  avg=$(extract_field "$line" "avg_mb")
  final=$(extract_field "$line" "final_mb")
  cpu_avg=$(extract_field "$line" "cpu_avg_pct")
  cpu_peak=$(extract_field "$line" "cpu_peak_pct")
  recv_sps=$(extract_field "$line" "recv_sps")
  trace_sps=$(extract_field "$line" "trace_sps")
  est_take_sps=$(extract_field "$line" "estimated_take_sps")
  append_sps=$(extract_field "$line" "append_sps")
  actual_take_sps=$(extract_field "$line" "actual_take_sps")
  sampled_sps=$(extract_field "$line" "sampled_sps")
  printf "%-22s %8s %9s %9s %9s %8s %8s %9s %9s %9s %9s %9s %10s\n" "$label" "$samples" "$peak" "$avg" "$final" "$cpu_avg" "$cpu_peak" "$recv_sps" "$trace_sps" "$est_take_sps" "$append_sps" "$actual_take_sps" "$sampled_sps"
}

print_delta_block() {
  local title="$1"
  local line_a="$2"
  local line_b="$3"
  local a_peak a_avg a_final a_cpu_avg a_cpu_peak a_recv a_trace a_take a_append a_actual_take a_sampled
  local b_peak b_avg b_final b_cpu_avg b_cpu_peak b_recv b_trace b_take b_append b_actual_take b_sampled
  a_peak=$(extract_field "$line_a" "peak_mb")
  a_avg=$(extract_field "$line_a" "avg_mb")
  a_final=$(extract_field "$line_a" "final_mb")
  a_cpu_avg=$(extract_field "$line_a" "cpu_avg_pct")
  a_cpu_peak=$(extract_field "$line_a" "cpu_peak_pct")
  a_recv=$(extract_field "$line_a" "recv_sps")
  a_trace=$(extract_field "$line_a" "trace_sps")
  a_take=$(extract_field "$line_a" "estimated_take_sps")
  a_append=$(extract_field "$line_a" "append_sps")
  a_actual_take=$(extract_field "$line_a" "actual_take_sps")
  a_sampled=$(extract_field "$line_a" "sampled_sps")
  b_peak=$(extract_field "$line_b" "peak_mb")
  b_avg=$(extract_field "$line_b" "avg_mb")
  b_final=$(extract_field "$line_b" "final_mb")
  b_cpu_avg=$(extract_field "$line_b" "cpu_avg_pct")
  b_cpu_peak=$(extract_field "$line_b" "cpu_peak_pct")
  b_recv=$(extract_field "$line_b" "recv_sps")
  b_trace=$(extract_field "$line_b" "trace_sps")
  b_take=$(extract_field "$line_b" "estimated_take_sps")
  b_append=$(extract_field "$line_b" "append_sps")
  b_actual_take=$(extract_field "$line_b" "actual_take_sps")
  b_sampled=$(extract_field "$line_b" "sampled_sps")

  echo
  echo "$title"
  awk \
    -v a_peak="$a_peak" -v a_avg="$a_avg" -v a_final="$a_final" \
    -v a_cpu_avg="$a_cpu_avg" -v a_cpu_peak="$a_cpu_peak" \
    -v a_recv="$a_recv" -v a_trace="$a_trace" -v a_take="$a_take" -v a_append="$a_append" -v a_actual_take="$a_actual_take" -v a_sampled="$a_sampled" \
    -v b_peak="$b_peak" -v b_avg="$b_avg" -v b_final="$b_final" \
    -v b_cpu_avg="$b_cpu_avg" -v b_cpu_peak="$b_cpu_peak" \
    -v b_recv="$b_recv" -v b_trace="$b_trace" -v b_take="$b_take" -v b_append="$b_append" -v b_actual_take="$b_actual_take" -v b_sampled="$b_sampled" '
    function line(name, d, base) {
      pct = (base == 0 ? 0 : (d / base) * 100.0)
      ratio = (base == 0 ? 0 : (d + base) / base)
      printf "%-30s %10.2f (%+.2f%%, %.2fx)\n", name, d, pct, ratio
    }
    BEGIN {
      line("peak delta:", b_peak - a_peak, a_peak)
      line("avg delta:", b_avg - a_avg, a_avg)
      line("final delta:", b_final - a_final, a_final)
      line("avg CPU delta:", b_cpu_avg - a_cpu_avg, a_cpu_avg)
      line("peak CPU delta:", b_cpu_peak - a_cpu_peak, a_cpu_peak)
      line("recv throughput delta:", b_recv - a_recv, a_recv)
      line("trace throughput delta:", b_trace - a_trace, a_trace)
      line("estimated take/s delta:", b_take - a_take, a_take)
      line("append/s delta:", b_append - a_append, a_append)
      line("actual take/s delta:", b_actual_take - a_actual_take, a_actual_take)
      line("sampled throughput delta:", b_sampled - a_sampled, a_sampled)
    }'
}

echo "=== tail sampling memory comparison ==="
echo "settings: decision_wait=${decision_wait}, effective_duration=${effective_duration}, rate/worker=${rate_worker}, workers=${workers}, child_spans=${child_spans}, load_size_mb=${load_size_mb}, sample_pct=${sample_pct}, split_trace_requests=${split_trace_requests}"
echo
printf "%-22s %8s %9s %9s %9s %8s %8s %9s %9s %9s %9s %9s %10s\n" "mode" "samples" "peak_mb" "avg_mb" "final_mb" "cpu_avg" "cpu_peak" "recv_sps" "trace_sps" "est_take" "append_sps" "take_sps" "sampled_sps"
print_mode_row "inmemory_root_false" "$inmemory_root_false_line"
print_mode_row "inmemory_root_true" "$inmemory_root_true_line"
print_mode_row "pebble_root_false" "$pebble_root_false_line"
print_mode_row "pebble_root_true" "$pebble_root_true_line"

print_delta_block "storage delta at sample_on_root=false (pebble - inmemory):" "$inmemory_root_false_line" "$pebble_root_false_line"
print_delta_block "storage delta at sample_on_root=true (pebble - inmemory):" "$inmemory_root_true_line" "$pebble_root_true_line"
print_delta_block "root-only delta in inmemory (true - false):" "$inmemory_root_false_line" "$inmemory_root_true_line"
print_delta_block "root-only delta in pebble (true - false):" "$pebble_root_false_line" "$pebble_root_true_line"

echo "artifacts: $output_dir"
