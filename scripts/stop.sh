#!/usr/bin/env bash
# Stop the server and free its ~93 GiB of memory.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_recipe
cd "$RECIPE_DIR" && ./flash stop
