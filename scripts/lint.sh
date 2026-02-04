#!/bin/bash
set -euo pipefail
# SC1091: Not following sourced files (shellcheck can't resolve dynamic paths)
# SC2016: Single quotes are intentional in default value strings
shellcheck --exclude=SC1091,SC2016 scripts/*.sh claudebox-dev.sh tests/*.sh tests/lib/*.sh
