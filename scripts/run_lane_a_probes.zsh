#!/usr/bin/env zsh
# Lane A probe harness (thin orchestration only). Compiles each probe in
# probes/lane-a/*.swift with the Xcode-default Swift 6.4 toolchain, runs it,
# and captures the raw JSON vector output + return code. Produces a combined
# vectors.json + provenance/invocation. No hang surface (probes are deterministic
# and sub-second); the external watchdog is therefore not required here.
set -euo pipefail

usage() {
  print -u2 -- "usage: run_lane_a_probes.zsh --run-dir DIR [--probe-dir DIR] [--swift PATH]"
  exit 2
}

run_dir=""
probe_dir=""
swift_bin="${SWIFT_GATE_SWIFTC:-/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) run_dir="${2:-}"; shift 2 ;;
    --probe-dir) probe_dir="${2:-}"; shift 2 ;;
    --swift) swift_bin="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$run_dir" ]] || usage

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -n "$probe_dir" ]] || probe_dir="${repo_root}/probes/lane-a"
[[ -x "$swift_bin" ]] || { print -u2 -- "missing swift: $swift_bin"; exit 2; }
mkdir -p "$run_dir"

# Capture exact toolchain identity for provenance.
swift_version="$(env -u TOOLCHAINS "$swift_bin" --version 2>&1 | head -1)"
swift_sha256="$(shasum -a 256 "$swift_bin" | awk '{print $1}')"

{
  print -r -- "harness=run_lane_a_probes.zsh"
  print -r -- "probe_dir=$probe_dir"
  print -r -- "swift_bin=$swift_bin"
  print -r -- "swift_version=$swift_version"
  print -r -- "swift_sha256=$swift_sha256"
  print -r -- "host=$(uname -a)"
  print -r -- "macos=$(sw_vers -productVersion)"
  print -r -- "git_head=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)"
} > "$run_dir/invocation.txt"

# Run each probe and capture raw output + rc (thin orchestration only).
# JSON assembly of the combined vector set is done by the Elixir validator.
for src in "$probe_dir"/*.swift; do
  [[ -f "$src" ]] || continue
  name="$(basename "$src" .swift)"
  raw="$run_dir/$name.raw.json"
  rc_file="$run_dir/$name.rc"
  src_sha="$(shasum -a 256 "$src" | awk '{print $1}')"

  set +e
  env -u TOOLCHAINS "$swift_bin" "$src" > "$raw" 2>"$run_dir/$name.stderr"
  rc=$?
  set -e
  print -r -- "$rc" > "$rc_file"
  print -r -- "probe=$name src_sha256=$src_sha rc=$rc" >> "$run_dir/invocation.txt"

  if (( rc != 0 )); then
    print -u2 -- "probe $name failed rc=$rc (see $run_dir/$name.stderr)"
    continue
  fi
done

print -r -- "captured probes into $run_dir"

