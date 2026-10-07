#!/usr/bin/env bash
# Embed the launch module so the installed CLI remains self-contained.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${1:-agentbox}"
[[ "$image" =~ ^[a-zA-Z0-9./:@_-]+$ ]] || { echo 'Invalid image reference' >&2; exit 1; }
awk -v image="$image" -v library="$script_dir/launch-common.sh" '
  /^# @launch-common$/ { while ((getline line < library) > 0) print line; close(library); next }
  { gsub(/PLACEHOLDER_IMAGE_NAME/, image); print }
' "$script_dir/agentbox-template.sh"
