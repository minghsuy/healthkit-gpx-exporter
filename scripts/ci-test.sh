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
work_root=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/healthkit-xcode.XXXXXX")
cleanup() {
  case "$work_root" in
    "${RUNNER_TEMP:-${TMPDIR:-/tmp}}"/healthkit-xcode.*) rm -rf -- "$work_root" ;;
    *) echo "refusing to remove unexpected path: $work_root" >&2 ;;
  esac
}
trap cleanup EXIT

derived_data="$work_root/DerivedData"
archive_path="$work_root/HealthKitGPXExporter.xcarchive"

xcode_version=$(xcodebuild -version)
printf '%s\n' "$xcode_version"
[[ "$(printf '%s\n' "$xcode_version" | sed -n '1p')" == "Xcode 26.2" ]] ||
  { echo "Xcode 26.2 is required" >&2; exit 1; }

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

xcodebuild \
  -project "$project" \
  -scheme "$scheme" \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  test

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
