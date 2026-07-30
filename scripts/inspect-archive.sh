#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "archive inspection: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: $0 PATH_TO_XCARCHIVE"
archive_path=$1
app_path="$archive_path/Products/Applications/HealthKitGPXExporter.app"
info_plist="$app_path/Info.plist"

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
source_entitlements="$repo_root/HealthKitGPXExporter/HealthKitGPXExporter/HealthKitGPXExporter.entitlements"
plist_buddy=/usr/libexec/PlistBuddy

[[ -d "$archive_path" ]] || fail "missing archive: $archive_path"
[[ -d "$app_path" ]] || fail "missing archived app: $app_path"
[[ -f "$info_plist" ]] || fail "missing archived Info.plist"
[[ -x "$app_path/HealthKitGPXExporter" ]] || fail "missing archived executable"
[[ -x "$plist_buddy" ]] || fail "PlistBuddy is required"

assert_plist() {
  local file=$1
  local key=$2
  local expected=$3
  local actual
  actual=$("$plist_buddy" -c "Print :$key" "$file" 2>/dev/null) ||
    fail "missing $key in $file"
  [[ "$actual" == "$expected" ]] ||
    fail "$key expected '$expected', found '$actual'"
}

assert_plist "$info_plist" CFBundleIdentifier com.minghsuy.HealthKitGPXExporter
assert_plist "$info_plist" CFBundleShortVersionString 1.0
assert_plist "$info_plist" CFBundleVersion 2
assert_plist "$info_plist" MinimumOSVersion 26.2
assert_plist \
  "$info_plist" \
  NSHealthShareUsageDescription \
  "Export your cycling workouts and heart rate data to GPX files for analysis in your own tools."
assert_plist \
  "$info_plist" \
  NSHealthUpdateUsageDescription \
  "This app does not write to HealthKit."

assert_plist "$source_entitlements" com.apple.developer.healthkit true
assert_plist \
  "$source_entitlements" \
  com.apple.developer.icloud-container-identifiers:0 \
  iCloud.com.minghsuy.HealthKitGPXExporter
assert_plist \
  "$source_entitlements" \
  com.apple.developer.icloud-services:0 \
  CloudDocuments
assert_plist \
  "$source_entitlements" \
  com.apple.developer.ubiquity-container-identifiers:0 \
  iCloud.com.minghsuy.HealthKitGPXExporter

[[ ! -e "$app_path/_CodeSignature" ]] ||
  fail "unsigned preflight archive unexpectedly contains _CodeSignature"
[[ ! -e "$app_path/embedded.mobileprovision" ]] ||
  fail "unsigned preflight archive unexpectedly contains a provisioning profile"

echo "archive inspection: metadata, usage descriptions, and source entitlements are valid"
