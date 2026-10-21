#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Автоматическая установка Matrix-сервера (полный функционал)
#
#  Возможности:
#    • Synapse + PostgreSQL
#    • Element Web (веб-клиент)
#    • nginx + Let's Encrypt (TLS для всех доменов)
#    • coturn (TURN/STUN для звонков)
#    • Matrix Authentication Service (MAS) + Keycloak (OIDC/SSO)
#    • Мосты: WhatsApp, Telegram, Signal, Discord, IRC
#    • Панель администратора Synapse
#    • Prometheus + Grafana (дашборд Matrix)
#    • Резервные копии (БД + медиа + конфиги) с выгрузкой в S3
#
#  Использование:
#    sudo bash install.sh                     — интерактивная установка
#    sudo bash install.sh --non-interactive   — с параметрами по умолчанию
#    sudo bash install.sh --reconfigure       — применить новый config/matrix.env
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"
# shellcheck source=lib/finalize.sh
source "$SCRIPT_DIR/lib/finalize.sh"

INTERACTIVE=1
SKIP_DEPS=0
SKIP_DOCKER=0
# shellcheck disable=SC2034  # используется в lib/stack.sh
SKIP_CERTS=0
RECONFIGURE=0
DELEGATE_ONLY=0
LOG_FILE="/var/log/matrix-install.log"

usage() {
	cat <<EOF
Использование: sudo bash install.sh [опции]

  --non-interactive     не задавать вопросов (значения из config/matrix.env)
  --stack-dir <путь>   каталог стека (по умолчанию /opt/matrix)
  --skip-deps          не устанавливать системные пакеты
  --skip-docker        не устанавливать Docker
  --skip-certs         не получать сертификаты Let's Encrypt
  --reconfigure        перегенерировать конфигурацию из config/matrix.env
  --delegate-only      только зарегистрировать делегирование на matrix.org
  -h, --help           эта справка
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--non-interactive) INTERACTIVE=0 ;;
			--stack-dir)
				STACK_DIR="${2:?--stack-dir требует путь}"
				shift
				;;
			--skip-deps) SKIP_DEPS=1 ;;
			--skip-docker) SKIP_DOCKER=1 ;;
			--skip-certs)
				# shellcheck disable=SC2034  # используется в lib/stack.sh
				SKIP_CERTS=1
				;;
			--reconfigure) RECONFIGURE=1 ;;
			--delegate-only) DELEGATE_ONLY=1 ;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				err "Неизвестный аргумент: $1"
				usage
				exit 1
				;;
		esac
		shift
	done
}

# ---------------------------------------------------------------------------
main() {
	parse_args "$@"
	require_root

	# Логирование в файл
	if touch "$LOG_FILE" 2>/dev/null; then
		chmod 640 "$LOG_FILE"
		exec > >(tee -a "$LOG_FILE") 2>&1
	fi

	banner
	log "Каталог скриптов: $SCRIPT_DIR"
	log "Каталог стека:    $STACK_DIR"

	detect_os

	if [[ "$SKIP_DEPS" -eq 0 ]]; then
		install_base_deps
	else
		log "Пропускаю установку зависимостей (--skip-deps)"
	fi

	if [[ "$SKIP_DOCKER" -eq 0 ]]; then
		install_docker
	else
		have docker || die "Docker не найден, а --skip-docker указан"
	fi

	load_config

	if [[ "$RECONFIGURE" -eq 1 && "$INTERACTIVE" == "1" ]]; then
		configure_interactively
	fi

	load_stack_env >/dev/null 2>&1 || true
	generate_stack_env
	load_stack_env

	if [[ "$DELEGATE_ONLY" -eq 1 ]]; then
		delegate_to_matrix_org
		exit 0
	fi

	prepare_stack_dir
	render_stack
	render_wellknown
	render_auth_stack
	render_bridges
	render_monitoring_stack

	# Список appservice-регистраций попадает в homeserver.yaml
	if [[ "${ENABLE_BRIDGES:-1}" == "1" ]]; then
		update_synapse_appservices
	fi
	apply_registration_policy

	# --- Сертификаты (нужен запущенный nginx) ---
	obtain_certificates

	# --- Запуск ---
	start_stack
	start_auth_stack
	start_monitoring_stack
	start_bridges
	start_nginx

	step "Ожидание готовности Synapse"
	if dc exec -T synapse python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8008/health',timeout=5)" >/dev/null 2>&1; then
		ok "Synapse отвечает"
	else
		sleep 25
		dc exec -T synapse python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8008/health',timeout=5)" >/dev/null 2>&1 \
			&& ok "Synapse отвечает" \
			|| warn "Synapse не отвечает — смотрите: docker logs matrix-synapse"
	fi

	verify_mas_config
	verify_auth_stack
	create_admin_user
	delegate_to_matrix_org

	configure_firewall
	install_backup_system

	# Таймер продления сертификатов
	install -m 0755 "$SCRIPT_DIR/ops/renew-certs.sh" "$STACK_DIR/bin/renew-certs.sh"
	install_systemd_timer matrix-certbot-renew "$STACK_DIR/bin/renew-certs.sh" \
		"*-*-* 04:30:00" "Продление сертификатов Let's Encrypt"

	verify_installation
	print_summary
}

main "$@"
