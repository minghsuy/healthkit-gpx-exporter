#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
preflight_source="$repo_root/scripts/release-preflight.sh"

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/healthkit-release-preflight.XXXXXX")
cleanup() {
  case "$tmp_root" in
    "${TMPDIR:-/tmp}"/healthkit-release-preflight.*) rm -rf -- "$tmp_root" ;;
    *) echo "refusing to remove unexpected path: $tmp_root" >&2 ;;
  esac
}
trap cleanup EXIT

new_fixture() {
  local fixture=$1
  mkdir -p \
    "$fixture/scripts" \
    "$fixture/release/evidence" \
    "$fixture/HealthKitGPXExporter/HealthKitGPXExporter.xcodeproj"
  cp "$preflight_source" "$fixture/scripts/release-preflight.sh"
  cp "$repo_root/scripts/package-source.sh" "$fixture/scripts/package-source.sh"
  cp \
    "$repo_root/HealthKitGPXExporter/HealthKitGPXExporter.xcodeproj/project.pbxproj" \
    "$fixture/HealthKitGPXExporter/HealthKitGPXExporter.xcodeproj/project.pbxproj"
  cp "$repo_root/CHANGELOG.md" "$fixture/CHANGELOG.md"
  printf '%s\n' \
    "# v1.0.0 release evidence" \
    "" \
    "Status: READY" \
    "" \
    "- [x] Release gates complete." \
    "- Evidence: fixture" \
    >"$fixture/release/evidence/v1.0.0.md"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name "Release Contract Test"
  git -C "$fixture" config user.email "release-contract@example.invalid"
  git -C "$fixture" add .
  git -C "$fixture" commit -qm "initial"
  git -C "$fixture" branch -M main
  git -C "$fixture" remote add origin "$fixture"
  git -C "$fixture" update-ref refs/remotes/origin/main HEAD
}

expect_failure() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "expected failure: $description" >&2
    exit 1
  fi
}

candidate="$tmp_root/candidate"
new_fixture "$candidate"
"$candidate/scripts/release-preflight.sh" --candidate >/dev/null

missing_changelog="$tmp_root/missing-changelog"
new_fixture "$missing_changelog"
sed -i.bak '/^## \[1[.]0[.]0\] - /,$d' "$missing_changelog/CHANGELOG.md"
rm "$missing_changelog/CHANGELOG.md.bak"
expect_failure \
  "candidate without a matching changelog entry" \
  "$missing_changelog/scripts/release-preflight.sh" --candidate

missing_target_settings="$tmp_root/missing-target-settings"
new_fixture "$missing_target_settings"
settings_file="$missing_target_settings/HealthKitGPXExporter/HealthKitGPXExporter.xcodeproj/project.pbxproj"
awk '
  !removed && /MARKETING_VERSION = 1[.]0;/ { removed = 1; next }
  { print }
' "$settings_file" >"${settings_file}.tmp"
mv "${settings_file}.tmp" "$settings_file"
expect_failure \
  "candidate missing a target build setting" \
  "$missing_target_settings/scripts/release-preflight.sh" --candidate

lightweight="$tmp_root/lightweight"
new_fixture "$lightweight"
git -C "$lightweight" tag v1.0.0
expect_failure \
  "lightweight release tag" \
  env GITHUB_REF_NAME=v1.0.0 \
    "$lightweight/scripts/release-preflight.sh" --tag

wrong_version="$tmp_root/wrong-version"
new_fixture "$wrong_version"
git -C "$wrong_version" tag -am "v1.0.0" v1.0.0
expect_failure \
  "tag and marketing version mismatch" \
  env GITHUB_REF_NAME=v1.0.1 \
    "$wrong_version/scripts/release-preflight.sh" --tag

blocked_evidence="$tmp_root/blocked-evidence"
new_fixture "$blocked_evidence"
sed -i.bak 's/Status: READY/Status: BLOCKED/' \
  "$blocked_evidence/release/evidence/v1.0.0.md"
rm "$blocked_evidence/release/evidence/v1.0.0.md.bak"
git -C "$blocked_evidence" add release/evidence/v1.0.0.md
git -C "$blocked_evidence" commit -qm "block release evidence"
git -C "$blocked_evidence" update-ref refs/remotes/origin/main HEAD
git -C "$blocked_evidence" tag -am "v1.0.0" v1.0.0
expect_failure \
  "incomplete manual release evidence" \
  env GITHUB_REF_NAME=v1.0.0 \
    "$blocked_evidence/scripts/release-preflight.sh" --tag

not_main="$tmp_root/not-main"
new_fixture "$not_main"
echo "different commit" >"$not_main/branch-only.txt"
git -C "$not_main" add branch-only.txt
git -C "$not_main" commit -qm "branch-only"
git -C "$not_main" tag -am "v1.0.0" v1.0.0
expect_failure \
  "tagged commit not synchronized with origin/main" \
  env GITHUB_REF_NAME=v1.0.0 \
    "$not_main/scripts/release-preflight.sh" --tag

annotated="$tmp_root/annotated"
new_fixture "$annotated"
git -C "$annotated" tag -am "v1.0.0" v1.0.0
(
  cd "$annotated"
  GITHUB_REF_NAME=v1.0.0 ./scripts/release-preflight.sh --tag >/dev/null
  ./scripts/package-source.sh v1.0.0 "$annotated/dist" >/dev/null
  (
    cd "$annotated/dist"
    if command -v sha256sum >/dev/null; then
      sha256sum --check "HealthKitGPXExporter-1.0.0-source.tar.gz.sha256" >/dev/null
    else
      shasum -a 256 --check "HealthKitGPXExporter-1.0.0-source.tar.gz.sha256" \
        >/dev/null
    fi
  )
  tar -tzf "$annotated/dist/HealthKitGPXExporter-1.0.0-source.tar.gz" |
    grep -Fxq "HealthKitGPXExporter-1.0.0/CHANGELOG.md"
)

echo "release preflight tests: passed"
