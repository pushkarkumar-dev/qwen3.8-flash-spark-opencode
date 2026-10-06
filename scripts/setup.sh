#!/usr/bin/env bash
# One-time setup on the DGX Spark.
#
#   1. creates .env with a random API key (if you don't have one yet)
#   2. clones the Blazux recipe at the commit this guide was tested with
#   3. runs the recipe's own setup: builds the vLLM image, downloads the
#      NVFP4 checkpoint (~124 GiB) and prepares the hybrid fp8 layout
#
# Safe to re-run: every step skips what is already done. Takes 30-90 min the
# first time, mostly the download.
#
#   ./scripts/setup.sh
#   RECIPE_COMMIT=main ./scripts/setup.sh     # track the recipe's latest instead
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

step "API key"
if [ ! -f "$ROOT/.env" ]; then
  key="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
  sed "s/^SPARK_API_KEY=.*/SPARK_API_KEY=$key/" "$ROOT/.env.example" > "$ROOT/.env"
  chmod 600 "$ROOT/.env"
  ok "created .env with a new random API key (you'll need it on the Mac: grep SPARK_API_KEY .env)"
else
  ok ".env already exists, leaving it alone"
fi

step "Recipe ($RECIPE_URL @ $RECIPE_COMMIT)"
command -v git >/dev/null || die "git is not installed"
if [ ! -d "$RECIPE_DIR/.git" ]; then
  git clone "$RECIPE_URL" "$RECIPE_DIR"
else
  git -C "$RECIPE_DIR" fetch --quiet origin || warn "could not fetch (offline?), using what is checked out"
fi
if [ "$RECIPE_COMMIT" = main ]; then
  git -C "$RECIPE_DIR" checkout --quiet main
  git -C "$RECIPE_DIR" pull --quiet --ff-only
else
  git -C "$RECIPE_DIR" -c advice.detachedHead=false checkout --quiet "$RECIPE_COMMIT"
fi
ok "recipe at $(git -C "$RECIPE_DIR" log -1 --format='%h  %s' | cut -c1-80)"

step "Recipe setup (image build + ~124 GiB download + hybrid layout)"
cd "$RECIPE_DIR"
./flash doctor || true      # reports what is missing; setup fixes it
./flash setup "$PROFILE"

step "System check"
sw="$(cat /proc/sys/vm/swappiness)"
if [ "$sw" -gt 10 ]; then
  warn "vm.swappiness is $sw; the recipe recommends 10. Run once (needs sudo):"
  echo "      echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf && sudo sysctl --system"
else
  ok "vm.swappiness is $sw"
fi

echo
echo "Setup done. Start the server with: ./scripts/serve.sh"
