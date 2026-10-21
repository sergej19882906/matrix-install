#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Резервное копирование: локальные бэкапы + выгрузка в S3 (rclone) + таймер.
# ---------------------------------------------------------------------------

install_rclone() {
	have rclone && { ok "rclone уже установлен"; return 0; }
	log "Установка rclone"
	if curl -fsSL https://rclone.org/install.sh 2>/dev/null | bash >/dev/null 2>&1; then
		have rclone && { ok "rclone установлен"; return 0; }
	fi
	# Запасной путь — из репозитория дистрибутива
	case "$OS_FAMILY" in
		debian) pkg_install rclone ;;
		rhel)   pkg_install rclone ;;
		arch)   pkg_install rclone ;;
		alpine) pkg_install rclone ;;
	esac
	have rclone || warn "rclone недоступен — S3-выгрузка отключена"
}

setup_rclone_s3() {
	if [[ -z "${S3_BUCKET:-}" ]]; then
		log "S3-бакет не задан — выгрузка в S3 отключена"
		return 0
	fi
	install_rclone
	have rclone || return 0

	local conf="$STACK_DIR/rclone/rclone.conf"
	mkdir -p "$STACK_DIR/rclone"
	cat >"$conf" <<EOF
[matrix-s3]
type = s3
provider = Other
env_auth = false
access_key_id = ${S3_ACCESS_KEY}
secret_access_key = ${S3_SECRET_KEY}
endpoint = ${S3_ENDPOINT}
region = ${S3_REGION}
acl = private
storage_class = STANDARD
EOF
	chmod 600 "$conf"
	printf 'RCLONE_CONFIG=%s\n' "$conf" >>"$STACK_DIR/.env"
	printf 'S3_REMOTE=matrix-s3:%s\n' "$S3_BUCKET" >>"$STACK_DIR/.env"
	ok "S3-конфигурация rclone готова (${S3_ENDPOINT} / ${S3_BUCKET})"
}

install_backup_system() {
	[[ "${ENABLE_BACKUP:-1}" == "1" ]] || { log "Резервное копирование отключено"; return 0; }

	step "Настройка резервного копирования"
	mkdir -p "$STACK_DIR/backup"
	chmod 700 "$STACK_DIR/backup"
	install -m 0755 "$SCRIPT_DIR/ops/backup.sh" "$STACK_DIR/bin/backup.sh"
	install -m 0755 "$SCRIPT_DIR/ops/restore.sh" "$STACK_DIR/bin/restore.sh"

	setup_rclone_s3

	install_systemd_timer matrix-backup "$STACK_DIR/bin/backup.sh" \
		"*-*-* 03:30:00" "Резервное копирование Matrix (БД, медиа, конфиги)"

	# Первое пробное копирование
	if "$STACK_DIR/bin/backup.sh" --quiet; then
		ok "Тестовый бэкап выполнен"
	else
		warn "Тестовый бэкап не удался — проверьте $STACK_DIR/bin/backup.sh --verbose"
	fi
}
