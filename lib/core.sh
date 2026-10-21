#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Ядро: логирование, обработка ошибок, общие утилиты.
# ---------------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
	C_RED='\033[0;31m'
	C_GRN='\033[0;32m'
	C_YEL='\033[0;33m'
	C_BLU='\033[0;34m'
	C_CYN='\033[0;36m'
	C_BLD='\033[1m'
	C_RST='\033[0m'
else
	C_RED='' C_GRN='' C_YEL='' C_BLU='' C_CYN='' C_BLD='' C_RST=''
fi

TS() { date '+%H:%M:%S'; }

log()  { printf '%s[%s]%s %s\n' "$C_BLU" "$(TS)" "$C_RST" "$*"; }
step() { printf '\n%s▶ %s%s\n' "$C_BLD$C_CYN" "$*" "$C_RST"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[ WARN ]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[ FAIL ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

on_err() {
	local code=$? line=${1:-?}
	err "Установка прервана (строка ${line}, код ${code})"
	err "Команда: ${BASH_COMMAND:-неизвестна}"
	err "Лог: ${LOG_FILE:-/var/log/matrix-install.log}"
	exit "$code"
}
trap 'on_err "$LINENO"' ERR

# --- утилиты ---------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

hex()   { openssl rand -hex "${1:-32}"; }

# Пароль без спецсимволов (только буквы/цифры) — безопасен для URL и YAML.
passw() { openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

utcnow() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

require_root() {
	[[ "${EUID}" -eq 0 ]] || die "Нужен root. Запустите: sudo bash install.sh"
}

# retry <команда...> — повторять до <max> раз с нарастающей паузой.
retry() {
	local n=0 max=30 delay=1
	while true; do
		if "$@"; then return 0; fi
		n=$((n + 1))
		[[ $n -ge $max ]] && return 1
		sleep "$delay"
		delay=$(( delay < 10 ? delay + 1 : 10 ))
	done
}

# Ждём HTTP-ответа по URL.
wait_http() {
	local url=$1 timeout=${2:-90} end
	end=$((SECONDS + timeout))
	while ((SECONDS < end)); do
		if curl -fsS -o /dev/null --max-time 6 "$url" 2>/dev/null; then return 0; fi
		sleep 2
	done
	return 1
}

# Проверка TCP-порта (без nc).
tcp_open() {
	local host=$1 port=$2
	timeout 3 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null
}

# Свободный IP-подсеть в 172.x для docker-сети (избегаем конфликтов).
pick_free_subnet() {
	local candidate
	for candidate in 172.28.0.0/16 172.29.0.0/16 172.30.0.0/16 172.31.0.0/16 10.180.0.0/16; do
		local base="${candidate%/*}"
		if ! ip -4 route 2>/dev/null | grep -qE "${base//./\\.}[[:space:]]"; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	printf '%s' "172.28.0.0/16"
}

# Публичный IP сервера (внешний, с фолбэком на локальный).
detect_public_ip() {
	local ip=""
	ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
	if [[ ! "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
		ip="$(curl -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)"
	fi
	if [[ ! "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
		ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
	fi
	[[ -n "${ip:-}" ]] || ip="127.0.0.1"
	printf '%s' "$ip"
}

# --- рендеринг шаблонов ---------------------------------------------------

# Список переменных, разрешённых для подстановки в шаблоны.
ALLOWED_VARS=""
allowed_vars_set() {
	local v
	ALLOWED_VARS=""
	for v in "$@"; do
		ALLOWED_VARS+=" \${${v}}"
	done
}

# render <src> <dst> — подстановка только разрешённых переменных.
render() {
	local src=$1 dst=$2
	[[ -f "$src" ]] || die "Шаблон не найден: $src"
	mkdir -p "$(dirname "$dst")"
	envsubst "$ALLOWED_VARS" <"$src" >"$dst"
}

# --- интерактивные вопросы -------------------------------------------------

# ask <переменная> <вопрос> [значение_по_умолчанию] [секрет?]
ask() {
	local __var=$1 __q=$2 __def=${3:-} __secret=${4:-} __ans
	if [[ "$INTERACTIVE" != "1" ]]; then
		printf '%s' "$__def"
		return 0
	fi
	if [[ -n "$__def" ]]; then
		printf '%s [%s]: ' "$__q" "$__def" >&2
	else
		printf '%s: ' "$__q" >&2
	fi
	if [[ "$__secret" == "1" ]]; then
		read -r -s __ans
		printf '\n' >&2
		[[ -n "$__ans" ]] || __ans="$__def"
	else
		read -r __ans || __ans="$__def"
		[[ -n "$__ans" ]] || __ans="$__def"
	fi
	printf '%s' "$__ans"
}

ask_yes_no() {
	local __q=$1 __def=${2:-y} __ans
	if [[ "$INTERACTIVE" != "1" ]]; then
		[[ "$__def" == "y" ]]
		return $?
	fi
	local hint="y/N"
	[[ "$__def" == "y" ]] && hint="Y/n"
	printf '%s [%s]: ' "$__q" "$hint" >&2
	read -r __ans || __ans=""
	[[ -z "$__ans" ]] && __ans="$__def"
	[[ "$__ans" =~ ^[Yy] ]]
}

ask_secret() {
	ask "$1" "$2" "$3" "1"
}

banner() {
	printf '%s\n' "$C_BLD$C_CYN"
	cat <<'BANNER'
   ┌──────────────────────────────────────────────────┐
   │   Matrix Server — автоматическая установка        │
   │   Synapse · Element · MAS · Keycloak · Мосты     │
   │   coturn · nginx/TLS · Prometheus/Grafana · S3    │
   └──────────────────────────────────────────────────┘
BANNER
	printf '%s\n' "$C_RST"
}
