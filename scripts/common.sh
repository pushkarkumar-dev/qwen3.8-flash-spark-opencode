# Shared helpers for the scripts in this folder. Sourced, not executed.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# .env holds your API key and any overrides (see .env.example).
if [ -f "$ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
fi

RECIPE_URL="${RECIPE_URL:-https://github.com/blazux/qwen3.8-Flash-DGX.git}"
RECIPE_COMMIT="${RECIPE_COMMIT:-5d944b3}"   # the commit this guide was tested with
RECIPE_DIR="${RECIPE_DIR:-$ROOT/qwen3.8-Flash-DGX}"
case "$RECIPE_DIR" in /*) ;; *) RECIPE_DIR="$ROOT/$RECIPE_DIR" ;; esac

PROFILE="${PROFILE:-speed}"
GPU_MEM="${GPU_MEM:-0.76}"
CTX="${CTX:-262144}"
NAME="${NAME:-qwen38-flash}"
PORT="${PORT:-18300}"
SPARK_API_KEY="${SPARK_API_KEY:-}"

c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
[ -t 1 ] || { c_ok=""; c_warn=""; c_err=""; c_dim=""; c_off=""; }
ok()   { printf '  %s✔%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_warn" "$c_off" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$c_err" "$c_off" "$*"; }
info() { printf '  %s·%s %s\n' "$c_dim" "$c_off" "$*"; }
die()  { printf '%s!! %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
step() { printf '\n%s>> %s%s\n' "$c_dim" "$*" "$c_off"; }

need_recipe() {
  [ -x "$RECIPE_DIR/flash" ] || die "recipe not found at $RECIPE_DIR — run ./scripts/setup.sh first"
}

# Memory in GiB from /proc/meminfo (the Spark's CPU and GPU share this pool).
mem_gib() { awk -v k="$1:" '$1==k {printf "%.1f", $2/1048576}' /proc/meminfo; }

container_state() { docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo absent; }

auth_header() { [ -n "$SPARK_API_KEY" ] && printf 'Authorization: Bearer %s' "$SPARK_API_KEY" || printf 'X-No-Auth: 1'; }

lan_addresses() {
  # Physical interfaces only: skip docker bridges and veths.
  local ips; ips="$(ip -4 -o addr show scope global 2>/dev/null | grep -vE ' (docker|br-|veth)' | awk '{split($4,a,"/"); print a[1]}' || true)"
  echo "$(hostname).local $ips" | xargs
}
