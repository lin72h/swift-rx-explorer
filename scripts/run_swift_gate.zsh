#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 -- "usage: run_swift_gate.zsh --tier fast|full --run-dir DIR --lit-jobs N --watchdog-cpu-seconds N [--build-dir DIR] [--target TARGET] [--swiftc PATH] [--watchdog PATH] [--ninja PATH]"
  exit 2
}

tier=""
run_dir=""
lit_jobs=""
watchdog_cpu_seconds=""
build_dir="${SWIFT_GATE_BUILD_DIR:-}"
target_override=""
swiftc="${SWIFT_GATE_SWIFTC:-}"
watchdog=""
ninja_bin="${NINJA:-ninja}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)
      tier="${2:-}"; shift 2 ;;
    --run-dir)
      run_dir="${2:-}"; shift 2 ;;
    --lit-jobs)
      lit_jobs="${2:-}"; shift 2 ;;
    --watchdog-cpu-seconds)
      watchdog_cpu_seconds="${2:-}"; shift 2 ;;
    --build-dir)
      build_dir="${2:-}"; shift 2 ;;
    --target)
      target_override="${2:-}"; shift 2 ;;
    --swiftc)
      swiftc="${2:-}"; shift 2 ;;
    --watchdog)
      watchdog="${2:-}"; shift 2 ;;
    --ninja)
      ninja_bin="${2:-}"; shift 2 ;;
    *)
      usage ;;
  esac
done

[[ -n "$tier" && -n "$run_dir" && -n "$lit_jobs" && -n "$watchdog_cpu_seconds" ]] || usage

if [[ -n "$target_override" ]]; then
  target="$target_override"
else
  case "$tier" in
    fast) target="check-swift-freebsd-x86_64" ;;
    full) target="check-swift-all-freebsd-x86_64" ;;
    *) usage ;;
  esac
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "$build_dir" ]]; then
  build_dir="/Users/me/wip-rnx/nx-/swift-source-vx-632/build/rnx-vx-swift632-selfhost-install1/swift-freebsd-x86_64"
fi
if [[ -z "$watchdog" ]]; then
  watchdog="${repo_root}/bin/cpu_watchdog"
fi

[[ -x "$watchdog" ]] || { print -u2 -- "missing executable watchdog: $watchdog"; exit 2; }
[[ -d "$build_dir" ]] || { print -u2 -- "missing build dir: $build_dir"; exit 2; }
command -v "$ninja_bin" >/dev/null 2>&1 || { print -u2 -- "missing ninja executable: $ninja_bin"; exit 2; }
if [[ -n "$swiftc" && ! -x "$swiftc" ]]; then
  print -u2 -- "swiftc path is not executable: $swiftc"
  exit 2
fi

mkdir -p "$run_dir"

raw_log="${run_dir}/${tier}.raw.log"
watchdog_log="${run_dir}/${tier}.watchdog.log"
rc_file="${run_dir}/${tier}.rc"
invocation_file="${run_dir}/${tier}.invocation.txt"

{
  print -r -- "tier=${tier}"
  print -r -- "target=${target}"
  print -r -- "build_dir=${build_dir}"
  print -r -- "lit_jobs=${lit_jobs}"
  print -r -- "watchdog_cpu_seconds=${watchdog_cpu_seconds}"
  print -r -- "watchdog=${watchdog}"
  print -r -- "ninja=${ninja_bin}"
  print -r -- "swiftc=${swiftc}"
  print -r -- "raw_log=${raw_log}"
  print -r -- "watchdog_log=${watchdog_log}"
  print -r -- "command=env LIT_OPTS='-j ${lit_jobs}' ${watchdog} --cpu-budget-seconds ${watchdog_cpu_seconds} --poll-seconds 5 --status-seconds 60 --log ${watchdog_log} -- ${ninja_bin} -C ${build_dir} ${target}"
} > "$invocation_file"

set +e
env LIT_OPTS="-j ${lit_jobs}" "$watchdog" \
  --cpu-budget-seconds "$watchdog_cpu_seconds" \
  --poll-seconds 5 \
  --status-seconds 60 \
  --log "$watchdog_log" \
  -- "$ninja_bin" -C "$build_dir" "$target" > >(tee "$raw_log") 2>&1
rc=$?
set -e

print -r -- "$rc" > "$rc_file"
exit "$rc"
