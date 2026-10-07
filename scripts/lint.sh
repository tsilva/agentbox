#!/bin/bash
set -euo pipefail
# SC1091: Not following sourced files (shellcheck can't resolve dynamic paths)
# SC2016: Single quotes are intentional in default value strings
# Lint the embedded launch module and template together, as users execute them.
files=()
for file in scripts/*.sh install.sh uninstall.sh style.sh tests/*.sh tests/lib/*.sh; do
  case "$file" in scripts/agentbox-template.sh|scripts/launch-common.sh|scripts/onboarding.sh) ;; *) files+=("$file") ;; esac
done
shellcheck --exclude=SC1091,SC2016 "${files[@]}"
rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
./scripts/render-cli.sh agentbox > "$rendered"
shellcheck --exclude=SC1091,SC2016 "$rendered"
