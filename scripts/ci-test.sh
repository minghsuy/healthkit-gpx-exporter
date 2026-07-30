#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
cd "$repo_root"

command -v xcodebuild >/dev/null ||
  { echo "xcodebuild is required (run this script on macOS)" >&2; exit 1; }
command -v xcrun >/dev/null ||
  { echo "xcrun is required (run this script on macOS)" >&2; exit 1; }

project="HealthKitGPXExporter/HealthKitGPXExporter.xcodeproj"
scheme="HealthKitGPXExporter"
mode=${1:-all}
[[ "$mode" == "all" || "$mode" == "build" || "$mode" == "test" || "$mode" == "archive" ]] ||
  { echo "usage: $0 [all|build|test|archive]" >&2; exit 64; }

cleanup_work_root=false
if [[ -n "${HEALTHKIT_CI_WORK_ROOT:-}" ]]; then
  work_root=$HEALTHKIT_CI_WORK_ROOT
  case "$work_root" in
    "${RUNNER_TEMP:?RUNNER_TEMP is required}"/healthkit-xcode*) ;;
    *) echo "HEALTHKIT_CI_WORK_ROOT must be a healthkit-xcode path under RUNNER_TEMP" >&2; exit 1 ;;
  esac
  mkdir -p "$work_root"
elif [[ -n "${RUNNER_TEMP:-}" ]]; then
  work_root="$RUNNER_TEMP/healthkit-xcode"
  mkdir -p "$work_root"
else
  work_root=$(mktemp -d "${TMPDIR:-/tmp}/healthkit-xcode.XXXXXX")
  cleanup_work_root=true
fi

cleanup() {
  if [[ "$cleanup_work_root" == "true" ]]; then
    case "$work_root" in
      "${TMPDIR:-/tmp}"/healthkit-xcode.*) rm -rf -- "$work_root" ;;
      *) echo "refusing to remove unexpected path: $work_root" >&2 ;;
    esac
  fi
}
trap cleanup EXIT

derived_data="$work_root/DerivedData"
archive_path="$work_root/HealthKitGPXExporter.xcarchive"
result_bundle="$work_root/TestResults.xcresult"

xcode_version=$(xcodebuild -version)
printf '%s\n' "$xcode_version"
[[ "$(printf '%s\n' "$xcode_version" | sed -n '1p')" == "Xcode 26.2" ]] ||
  { echo "Xcode 26.2 is required" >&2; exit 1; }

run_builds() {
  for configuration in Debug Release; do
    xcodebuild \
      -project "$project" \
      -scheme "$scheme" \
      -configuration "$configuration" \
      -destination "generic/platform=iOS Simulator" \
      -derivedDataPath "$derived_data" \
      CODE_SIGNING_ALLOWED=NO \
      build
  done
}

run_tests() {
  local device_id
  device_id=$(
    xcrun simctl list devices available -j |
      ruby -rjson -e '
        runtimes = JSON.parse(STDIN.read).fetch("devices")
        runtime = runtimes.keys.find { |key| key.end_with?(".iOS-26-2") }
        abort "iOS 26.2 simulator runtime is unavailable" unless runtime
        devices = runtimes.fetch(runtime)
        iphone = devices.find { |device| device["isAvailable"] && device["name"].start_with?("iPhone") }
        abort "no available iOS 26.2 iPhone simulator" unless iphone
        puts iphone.fetch("udid")
      '
  )

  python3 - "$device_id" <<'PY'
import subprocess
import sys

device_id = sys.argv[1]
subprocess.run(
    ["xcrun", "simctl", "shutdown", device_id],
    check=False,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
subprocess.run(["xcrun", "simctl", "boot", device_id], check=True, timeout=30)
subprocess.run(
    ["xcrun", "simctl", "bootstatus", device_id, "-b"],
    check=True,
    timeout=180,
)
PY

  xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$device_id" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_bundle" \
    -parallel-testing-enabled NO \
    -maximum-parallel-testing-workers 1 \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 120 \
    -maximum-test-execution-time-allowance 300 \
    CODE_SIGNING_ALLOWED=NO \
    test
}

run_archive() {
  xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$archive_path" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    archive

  "$repo_root/scripts/inspect-archive.sh" "$archive_path"
}

case "$mode" in
  all)
    run_builds
    run_tests
    run_archive
    ;;
  build) run_builds ;;
  test) run_tests ;;
  archive) run_archive ;;
esac
