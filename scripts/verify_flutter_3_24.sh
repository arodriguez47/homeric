#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="$repository_root/packages/homeric"
playground_dir="$package_dir/examples/playground"

check_manifest() {
  local missing=0
  local target

  for target in "$package_dir/test" "$playground_dir/test"; do
    if [[ ! -d "$target" ]]; then
      echo "Missing compatibility target: ${target#"$repository_root/"}" >&2
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    return 2
  fi

  echo "package tests: test"
  echo "playground tests: test"
  echo "manifest valid"
}

if [[ "${1:-}" == "--check-manifest" ]]; then
  check_manifest
  exit 0
fi

check_manifest

flutter_bin="${1:-${HOMERIC_FLUTTER_3_24:-}}"
if [[ -z "$flutter_bin" ]]; then
  echo "Pass a Flutter 3.24 SDK binary or set HOMERIC_FLUTTER_3_24." >&2
  exit 2
fi
if [[ ! -x "$flutter_bin" ]]; then
  echo "Flutter binary is not executable: $flutter_bin" >&2
  exit 2
fi

version_json="$($flutter_bin --version --machine)"
framework_version="$(
  printf '%s' "$version_json" |
    sed -n 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
)"
if [[ "$framework_version" != 3.24.* ]]; then
  echo "Expected Flutter 3.24.x, found ${framework_version:-unknown}." >&2
  exit 2
fi

echo "Using Flutter $framework_version"

work_root="$(mktemp -d "${TMPDIR:-/tmp}/homeric-flutter-3.24.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT
tar \
  --exclude='.git' \
  --exclude='.dart_tool' \
  --exclude='build' \
  -C "$repository_root" \
  -cf - . | tar -C "$work_root" -xf -
package_dir="$work_root/packages/homeric"
playground_dir="$package_dir/examples/playground"

(
  cd "$package_dir"
  "$flutter_bin" pub get
  "$flutter_bin" analyze lib test
  "$flutter_bin" test test
)

(
  cd "$playground_dir"
  "$flutter_bin" pub get
  "$flutter_bin" analyze lib test integration_test benchmark
  "$flutter_bin" test test
)

echo "Flutter 3.24 compatibility gate passed"
