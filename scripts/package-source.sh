#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "source packaging: $*" >&2
  exit 1
}

[[ $# -eq 2 ]] || fail "usage: $0 TAG OUTPUT_DIRECTORY"
tag=$1
output_dir=$2
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "tag must use vMAJOR.MINOR.PATCH"
[[ "$(git cat-file -t "$tag" 2>/dev/null || true)" == "tag" ]] ||
  fail "$tag must be an annotated tag"

version=${tag#v}
archive_name="HealthKitGPXExporter-${version}-source.tar.gz"
mkdir -p "$output_dir"

write_sha256() {
  local file=$1
  if command -v sha256sum >/dev/null; then
    sha256sum "$file"
  elif command -v shasum >/dev/null; then
    shasum -a 256 "$file"
  else
    fail "sha256sum or shasum is required"
  fi
}

git archive \
  --format=tar \
  --prefix="HealthKitGPXExporter-${version}/" \
  "$tag^{commit}" |
  gzip -n -9 >"$output_dir/$archive_name"

(
  cd "$output_dir"
  write_sha256 "$archive_name" >"${archive_name}.sha256"
  if command -v sha256sum >/dev/null; then
    sha256sum --check "${archive_name}.sha256"
  else
    shasum -a 256 --check "${archive_name}.sha256"
  fi
)

echo "source packaging: created $output_dir/$archive_name"
