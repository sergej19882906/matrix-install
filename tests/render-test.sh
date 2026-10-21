#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Тест рендеринга: генерирует стек во временный каталог и проверяет,
# что все шаблоны корректно подставляются и результат валиден.
#
#   bash tests/render-test.sh
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="${STACK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/matrix-render-XXXXXX")}"
CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/matrix-render-XXXXXX.env")"
export NO_COLOR=1
export INTERACTIVE=0

cd "$SCRIPT_DIR"
# shellcheck source=lib/core.sh
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck source=lib/system.sh
source "$SCRIPT_DIR/lib/system.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/stack.sh
source "$SCRIPT_DIR/lib/stack.sh"
# shellcheck source=lib/mas.sh
source "$SCRIPT_DIR/lib/mas.sh"
# shellcheck source=lib/bridges.sh
source "$SCRIPT_DIR/lib/bridges.sh"
# shellcheck source=lib/monitoring.sh
source "$SCRIPT_DIR/lib/monitoring.sh"
# shellcheck source=lib/finalize.sh
source "$SCRIPT_DIR/lib/finalize.sh"

MODE="${1:-default}"
case "$MODE" in
	default)
		ENABLE_OIDC=1
		ENABLE_MAS=0
		;;
	mas)
		ENABLE_OIDC=1
		ENABLE_MAS=1
		;;
	*)
		echo "Использование: $0 [default|mas]" >&2
		exit 1
		;;
esac

cat >"$CONFIG_FILE" <<EOF
BASE_DOMAIN="matrix.test.local"
SERVER_NAME="matrix.test.local"
ELEMENT_DOMAIN="element.matrix.test.local"
MAS_DOMAIN="mas.matrix.test.local"
KEYCLOAK_DOMAIN="sso.matrix.test.local"
ADMIN_DOMAIN="admin.matrix.test.local"
GRAFANA_DOMAIN="grafana.matrix.test.local"
TURN_DOMAIN="turn.matrix.test.local"
APEX_DOMAIN="example.local"
ADMIN_EMAIL="admin@test.local"
ADMIN_USERNAME="admin"
SYNAPSE_ADMIN_USERNAME="admin"
PUBLIC_REGISTRATION="1"
ENABLE_OIDC="$ENABLE_OIDC"
ENABLE_MAS="$ENABLE_MAS"
ENABLE_KEYCLOAK="1"
ENABLE_BRIDGES="1"
ENABLE_IRC="1"
ENABLE_MONITORING="1"
ENABLE_TURN="1"
ENABLE_BACKUP="1"
TELEGRAM_API_ID="123456"
TELEGRAM_API_HASH="abcdef1234567890"
DISCORD_TOKEN="discord-token-test"
IRC_SERVER="irc.test.local"
IRC_NICK="matrixbridge"
IRC_CHANNEL="#matrix"
IRC_PASSWORD="secret"
EOF

log "Режим: $MODE"
log "Каталог: $STACK_DIR"

load_config
generate_stack_env
load_stack_env
prepare_stack_dir
render_stack
render_wellknown
render_auth_stack
render_bridges
render_monitoring_stack
update_synapse_appservices
apply_registration_policy

# --- Проверки результата ----------------------------------------------------
fail=0
check() {
	if [[ $1 -eq 0 ]]; then
		printf '  [ OK ] %s\n' "$2"
	else
		printf '  [FAIL] %s\n' "$2"
		fail=1
	fi
}

log "Проверка результата"

[[ -f "$STACK_DIR/docker-compose.yml" ]]; check $? "docker-compose.yml создан"
[[ -f "$STACK_DIR/synapse/homeserver.yaml" ]]; check $? "homeserver.yaml создан"
[[ -f "$STACK_DIR/nginx/conf.d/10-matrix.conf" ]]; check $? "конфигурация nginx создана"
[[ -f "$STACK_DIR/element/config.json" ]]; check $? "конфигурация Element создана"
[[ -f "$STACK_DIR/keycloak/import/matrix-realm.json" ]]; check $? "realm Keycloak создан"
[[ -f "$STACK_DIR/monitoring/prometheus/prometheus.yml" ]]; check $? "конфигурация Prometheus создана"
[[ -f "$STACK_DIR/bridges/telegram/config.yaml" ]]; check $? "конфигурация мостов создана"

if [[ "$ENABLE_MAS" == "1" ]]; then
	[[ -f "$STACK_DIR/mas/config.yaml" ]]; check $? "конфигурация MAS создана"
	[[ -f "$STACK_DIR/docker-compose.auth.yml" ]]; check $? "compose-файл MAS создан"
	grep -q 'msc3861' "$STACK_DIR/synapse/homeserver.yaml"; check $? "в homeserver.yaml есть блок msc3861"
else
	grep -q 'oidc_providers' "$STACK_DIR/synapse/homeserver.yaml"; check $? "в homeserver.yaml есть OIDC-провайдер"
	grep -q 'msc3861' "$STACK_DIR/synapse/homeserver.yaml" && {
		echo "  [FAIL] в homeserver.yaml остался msc3861"
		fail=1
	} || printf '  [ OK ] msc3861 отсутствует\n'
fi

# YAML/JSON валидность
if command -v python3 >/dev/null 2>&1; then
	python3 - "$STACK_DIR" <<'PY'
import glob, json, os, re, sys
try:
    import yaml
except ImportError:
    print("  [SKIP] PyYAML не установлен")
    sys.exit(0)

stack = sys.argv[1]
errors = 0
for path in glob.glob(os.path.join(stack, "**", "*.y*ml"), recursive=True):
    txt = re.sub(r"\$\{[^}]*\}", "X", open(path, encoding="utf-8").read())
    try:
        yaml.safe_load(txt)
    except Exception as exc:
        print(f"  [FAIL] YAML: {path}: {exc}")
        errors += 1
for path in glob.glob(os.path.join(stack, "**", "*.json"), recursive=True):
    txt = re.sub(r"\$\{[^}]*\}", "X", open(path, encoding="utf-8").read())
    try:
        json.loads(txt)
    except Exception as exc:
        print(f"  [FAIL] JSON: {path}: {exc}")
        errors += 1
if errors == 0:
    print("  [ OK ] все YAML/JSON корректны")
sys.exit(1 if errors else 0)
PY
	check $? "YAML/JSON валидны"
fi

# docker compose config (если docker доступен)
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
	(
		cd "$STACK_DIR"
		files=(-f docker-compose.yml)
		[[ -f docker-compose.auth.yml ]] && files+=(-f docker-compose.auth.yml)
		[[ -f docker-compose.keycloak.yml ]] && files+=(-f docker-compose.keycloak.yml)
		[[ -f docker-compose.turn.yml ]] && files+=(-f docker-compose.turn.yml)
		[[ -f docker-compose.bridges.yml ]] && files+=(-f docker-compose.bridges.yml)
		[[ -f docker-compose.monitoring.yml ]] && files+=(-f docker-compose.monitoring.yml)
		docker compose "${files[@]}" --project-directory "$STACK_DIR" config --quiet
	) >/dev/null 2>&1
	check $? "docker compose config проходит"
else
	printf '  [SKIP] docker недоступен — проверка compose пропущена\n'
fi

if [[ $fail -eq 0 ]]; then
	ok "Все проверки пройдены"
else
	err "Проверки не пройдены"
	exit 1
fi
