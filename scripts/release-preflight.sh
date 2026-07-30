#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --candidate | --tag" >&2
  exit 64
}

fail() {
  echo "release preflight: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
mode=$1
[[ "$mode" == "--candidate" || "$mode" == "--tag" ]] || usage

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
cd "$repo_root"

project_file="HealthKitGPXExporter/HealthKitGPXExporter.xcodeproj/project.pbxproj"
changelog_file="CHANGELOG.md"

[[ -f "$project_file" ]] || fail "missing $project_file"
[[ -f "$changelog_file" ]] || fail "missing $changelog_file"

versions=$(
  sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);$/\1/p' "$project_file" |
    sort -u
)
version_occurrences=$(
  sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);$/\1/p' "$project_file" |
    awk 'NF { count += 1 } END { print count + 0 }'
)
[[ "$version_occurrences" -eq 6 ]] ||
  fail "expected MARKETING_VERSION in Debug/Release for all three targets, found $version_occurrences"
version_count=$(printf '%s\n' "$versions" | awk 'NF { count += 1 } END { print count + 0 }')
[[ "$version_count" -eq 1 ]] ||
  fail "expected one MARKETING_VERSION across all targets, found: ${versions:-none}"

version=$versions
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] ||
  fail "MARKETING_VERSION must use major.minor or major.minor.patch, found $version"

if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
  release_version="${version}.0"
else
  release_version=$version
fi

build_numbers=$(
  sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);$/\1/p' "$project_file" |
    sort -u
)
build_number_occurrences=$(
  sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);$/\1/p' "$project_file" |
    awk 'NF { count += 1 } END { print count + 0 }'
)
[[ "$build_number_occurrences" -eq 6 ]] ||
  fail "expected CURRENT_PROJECT_VERSION in Debug/Release for all three targets, found $build_number_occurrences"
build_number_count=$(printf '%s\n' "$build_numbers" | awk 'NF { count += 1 } END { print count + 0 }')
[[ "$build_number_count" -eq 1 ]] ||
  fail "expected one CURRENT_PROJECT_VERSION across all targets, found: ${build_numbers:-none}"
[[ "$build_numbers" == "2" ]] ||
  fail "v1.0.0 release candidate must use build number 2, found $build_numbers"

platforms=$(
  sed -nE 's/^[[:space:]]*SUPPORTED_PLATFORMS = "([^"]+)";$/\1/p' "$project_file" |
    sort -u
)
platform_occurrences=$(
  sed -nE 's/^[[:space:]]*SUPPORTED_PLATFORMS = "([^"]+)";$/\1/p' "$project_file" |
    awk 'NF { count += 1 } END { print count + 0 }'
)
[[ "$platform_occurrences" -eq 6 ]] ||
  fail "expected SUPPORTED_PLATFORMS in Debug/Release for all three targets, found $platform_occurrences"
[[ "$platforms" == "iphoneos iphonesimulator" ]] ||
  fail "shipping platforms must be explicit iOS device and simulator targets"

device_families=$(
  sed -nE 's/^[[:space:]]*TARGETED_DEVICE_FAMILY = "([^"]+)";$/\1/p' "$project_file" |
    sort -u
)
device_family_occurrences=$(
  sed -nE 's/^[[:space:]]*TARGETED_DEVICE_FAMILY = "([^"]+)";$/\1/p' "$project_file" |
    awk 'NF { count += 1 } END { print count + 0 }'
)
[[ "$device_family_occurrences" -eq 6 ]] ||
  fail "expected TARGETED_DEVICE_FAMILY in Debug/Release for all three targets, found $device_family_occurrences"
[[ "$device_families" == "1,2" ]] ||
  fail "shipping device families must remain iPhone and iPad"

release_heading="## [$release_version] - "
release_lines=$(grep -F "$release_heading" "$changelog_file" || true)
release_line_count=$(printf '%s\n' "$release_lines" | awk 'NF { count += 1 } END { print count + 0 }')
[[ "$release_line_count" -eq 1 ]] ||
  fail "missing dated changelog heading for $release_version"
release_line=$release_lines
[[ "$release_line" =~ ^##\ \[$release_version\]\ -\ [0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
  fail "changelog heading for $release_version must use YYYY-MM-DD"

release_body=$(awk -v heading="$release_line" '
  $0 == heading { in_release = 1; next }
  in_release && /^## \[/ { exit }
  in_release && /[^[:space:]]/ { print }
' "$changelog_file")
[[ -n "$release_body" ]] || fail "changelog entry for $release_version is empty"

if [[ "$mode" == "--tag" ]]; then
  tag=${GITHUB_REF_NAME:-}
  [[ -n "$tag" ]] || fail "GITHUB_REF_NAME is required in tag mode"
  [[ "$tag" == "v$release_version" ]] ||
    fail "tag $tag does not match MARKETING_VERSION $version"
  [[ "$(git cat-file -t "$tag" 2>/dev/null || true)" == "tag" ]] ||
    fail "$tag must be an annotated tag"
  [[ "$(git rev-parse "$tag^{commit}")" == "$(git rev-parse HEAD)" ]] ||
    fail "$tag does not point at the checked-out commit"
  git show-ref --verify --quiet refs/remotes/origin/main ||
    fail "origin/main is unavailable; fetch it before tag validation"
  git merge-base --is-ancestor HEAD refs/remotes/origin/main ||
    fail "tagged commit is not in synchronized origin/main history"

  evidence_file="release/evidence/v${release_version}.md"
  [[ -f "$evidence_file" ]] ||
    fail "missing manual release evidence: $evidence_file"
  grep -Fxq "Status: READY" "$evidence_file" ||
    fail "$evidence_file is not marked READY"
  if grep -Eq '^- \[ \]' "$evidence_file"; then
    fail "$evidence_file contains incomplete release gates"
  fi
  if grep -Eq ':[[:space:]]*(TBD|BLOCKED)[[:space:]]*$' "$evidence_file"; then
    fail "$evidence_file contains unresolved evidence fields"
  fi
fi

echo "release preflight: marketing $version, tag v$release_version, build $build_numbers ($mode) is valid"
