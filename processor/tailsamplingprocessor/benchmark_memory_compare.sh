#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BENCH_SCRIPT="$SCRIPT_DIR/benchmark_memory.sh"
VERBOSE="false"

usage() {
  cat <<'EOF'
Run tail sampling memory benchmark and print a compact comparison summary.

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
  - Both backends (inmemory and pebble) always run under identical settings.
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

inmemory_line=$(extract_line '^mode=inmemory ')
pebble_line=$(extract_line '^mode=pebble ')

if [[ -z "$inmemory_line" || -z "$pebble_line" ]]; then
  echo "unable to parse benchmark output for both modes; raw output:" >&2
  cat "$run_log" >&2
  exit 1
fi

decision_wait=$(extract_value_after_colon 'decision_wait:')
effective_duration=$(extract_value_after_colon 'effective_duration:')
rate_worker=$(extract_value_after_colon 'rate/worker:')
workers=$(extract_value_after_colon 'workers:')
child_spans=$(extract_value_after_colon 'child_spans:')
load_size_mb=$(extract_value_after_colon 'load_size_mb:')
output_dir=$(extract_value_after_colon 'output_dir:')

im_samples=$(extract_field "$inmemory_line" "samples")
im_peak=$(extract_field "$inmemory_line" "peak_mb")
im_avg=$(extract_field "$inmemory_line" "avg_mb")
im_final=$(extract_field "$inmemory_line" "final_mb")

pb_samples=$(extract_field "$pebble_line" "samples")
pb_peak=$(extract_field "$pebble_line" "peak_mb")
pb_avg=$(extract_field "$pebble_line" "avg_mb")
pb_final=$(extract_field "$pebble_line" "final_mb")

read -r delta_peak pct_peak delta_avg pct_avg delta_final pct_final ratio_peak ratio_avg ratio_final <<EOF
$(awk -v im_peak="$im_peak" -v pb_peak="$pb_peak" \
      -v im_avg="$im_avg" -v pb_avg="$pb_avg" \
      -v im_final="$im_final" -v pb_final="$pb_final" '
  BEGIN {
    dpeak = im_peak - pb_peak
    davg = im_avg - pb_avg
    dfinal = im_final - pb_final
    ppeak = (pb_peak == 0 ? 0 : (dpeak / pb_peak) * 100.0)
    pavg = (pb_avg == 0 ? 0 : (davg / pb_avg) * 100.0)
    pfinal = (pb_final == 0 ? 0 : (dfinal / pb_final) * 100.0)
    rpeak = (pb_peak == 0 ? 0 : im_peak / pb_peak)
    ravg = (pb_avg == 0 ? 0 : im_avg / pb_avg)
    rfinal = (pb_final == 0 ? 0 : im_final / pb_final)
    printf "%.2f %.2f %.2f %.2f %.2f %.2f %.2f %.2f %.2f\n",
           dpeak, ppeak, davg, pavg, dfinal, pfinal, rpeak, ravg, rfinal
  }')
EOF

echo "=== tail sampling memory comparison ==="
echo "settings: decision_wait=${decision_wait}, effective_duration=${effective_duration}, rate/worker=${rate_worker}, workers=${workers}, child_spans=${child_spans}, load_size_mb=${load_size_mb}"
echo
printf "%-10s %8s %10s %10s %10s\n" "mode" "samples" "peak_mb" "avg_mb" "final_mb"
printf "%-10s %8s %10s %10s %10s\n" "inmemory" "$im_samples" "$im_peak" "$im_avg" "$im_final"
printf "%-10s %8s %10s %10s %10s\n" "pebble" "$pb_samples" "$pb_peak" "$pb_avg" "$pb_final"
echo
printf "%-30s %10.2f MB (%+.2f%%, %.2fx)\n" "peak delta (im - pebble):" "$delta_peak" "$pct_peak" "$ratio_peak"
printf "%-30s %10.2f MB (%+.2f%%, %.2fx)\n" "avg delta (im - pebble):" "$delta_avg" "$pct_avg" "$ratio_avg"
printf "%-30s %10.2f MB (%+.2f%%, %.2fx)\n" "final delta (im - pebble):" "$delta_final" "$pct_final" "$ratio_final"
echo "artifacts: $output_dir"
