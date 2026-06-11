#!/usr/bin/env bash
# Reproducible rename: super_editor -> homeric across all vendored packages.
#
# Idempotent: running this multiple times has no effect after the first run.
# Run from the repo root.
#
# This script exists so the provenance from super_editor is auditable: anyone
# can re-vendor the upstream packages at a given commit and re-apply this rename
# to reproduce the homeric tree byte-for-byte.

set -euo pipefail

cd "$(dirname "$0")/.."

# Mapping of upstream package name -> homeric package name.
# Order matters: longer prefixes first to avoid partial-substring matches.
declare -a RENAMES=(
  "super_editor_markdown:homeric_markdown"
  "super_editor:homeric"
  "super_text_layout:homeric_text_layout"
  "attributed_text:homeric_attributed_text"
)

echo "Renaming package identifiers in Dart and YAML files..."
for mapping in "${RENAMES[@]}"; do
  from="${mapping%%:*}"
  to="${mapping##*:}"
  echo "  $from -> $to"

  # Rewrite Dart imports/exports and pubspec names.
  # We constrain the find to packages/ to avoid touching docs.
  find packages -type f \( -name "*.dart" -o -name "*.yaml" -o -name "*.md" \) -print0 \
    | xargs -0 sed -i "s|\\bpackage:${from}/|package:${to}/|g"

  # Rewrite pubspec "name:" declarations.
  find packages -type f -name "pubspec.yaml" -print0 \
    | xargs -0 sed -i "s|^name: ${from}\$|name: ${to}|g"

  # Rewrite intra-monorepo path dependencies (if any).
  find packages -type f -name "pubspec.yaml" -print0 \
    | xargs -0 sed -i "s|  ${from}:|  ${to}:|g"
done

echo "Done. Run 'melos bootstrap' next."
