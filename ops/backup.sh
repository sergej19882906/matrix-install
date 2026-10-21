#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Резервное копирование Matrix-стека:
#   - дампы PostgreSQL (synapse, mas, keycloak)
#   - медиа-хранилище Synapse
#   - конфигурация (yaml/toml/json/электронные сертификаты)
#   - шифрование AES-256 (если задан BACKUP_PASSPHRASE)
#   - выгрузка в S3 через rclone (если задан S3_REMOTE)
# ---------------------------------------------------------------------------
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/opt/matrix}"
BACKUP_DIR="${BACKUP_DIR:-$STACK_DIR/backup}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
[[ "${1:-}" == "--verbose" ]] && set -x

log() { [[ $QUIET -eq 1 ]] || echo "[backup] $*"; }
err() { echo "[backup][FAIL] $*" >&2; }

cd "$STACK_DIR"
[[ -f "$STACK_DIR/.env" ]] || { err "Нет файла $STACK_DIR/.env"; exit 1; }
# shellcheck disable=SC1091
source "$STACK_DIR/.env"

: "${BACKUP_PASSPHRASE:=}"
: "${S3_REMOTE:=}"
: "${RCLONE_CONFIG:=$STACK_DIR/rclone/rclone.conf}"
export RCLONE_CONFIG

TS="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/matrix-backup-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

compose() { docker compose -f "$STACK_DIR/docker-compose.yml" --project-directory "$STACK_DIR" "$@"; }

log "Начало резервного копирования ($TS)"

# --- 1. Дампы баз данных --------------------------------------------------
for db in synapse mas keycloak; do
	if ! compose exec -T postgres pg_isready -U matrix -d "$db" >/dev/null 2>&1; then
		log "База $db отсутствует — пропускаю"
		continue
	fi
	log "Дамп базы $db"
	compose exec -T postgres pg_dump -U matrix -d "$db" --clean --if-exists --no-owner \
		| gzip -9 >"$WORK/${db}.sql.gz"
done

# --- 2. Медиа-хранилище ---------------------------------------------------
if [[ -d "$STACK_DIR/synapse/media_store" ]]; then
	log "Архивирование медиа-хранилища"
	tar -czf "$WORK/media_store.tar.gz" -C "$STACK_DIR/synapse" media_store 2>/dev/null || true
fi

# --- 3. Конфигурация ------------------------------------------------------
log "Архивирование конфигурации"
tar -czf "$WORK/config.tar.gz" -C "$STACK_DIR" \
	--exclude=backup --exclude='.env' --exclude='*.log' \
	synapse/homeserver.yaml synapse/log.config synapse/bridges \
	mas/config.yaml keycloak/import nginx/conf.d coturn element monitoring/prometheus \
	2>/dev/null || true

# --- 4. Метаданные --------------------------------------------------------
{
	echo "created: $TS"
	echo "host: $(hostname)"
	echo "stack: $STACK_DIR"
	echo "version: ${MATRIX_VERSION:-unknown}"
	compose version 2>/dev/null || true
} >"$WORK/manifest.txt"

# --- 5. Сборка архива -----------------------------------------------------
ARCHIVE="$BACKUP_DIR/matrix-backup-$TS.tar.gz"
tar -czf "$ARCHIVE" -C "$WORK" .
log "Архив создан: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

# --- 6. Шифрование --------------------------------------------------------
if [[ -n "$BACKUP_PASSPHRASE" ]]; then
	ENC="$ARCHIVE.enc"
	openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
		-in "$ARCHIVE" -out "$ENC" -pass "pass:$BACKUP_PASSPHRASE"
	rm -f "$ARCHIVE"
	ARCHIVE="$ENC"
	log "Архив зашифрован (AES-256)"
fi

# --- 7. Выгрузка в S3 -----------------------------------------------------
if [[ -n "$S3_REMOTE" ]]; then
	if command -v rclone >/dev/null 2>&1; then
		log "Выгрузка в S3: $S3_REMOTE"
		rclone copy "$ARCHIVE" "$S3_REMOTE/matrix/" --progress --transfers 1
		log "Загружено: $S3_REMOTE/matrix/$(basename "$ARCHIVE")"
	else
		err "rclone не найден — S3-выгрузка пропущена"
	fi
fi

# --- 8. Ротация -----------------------------------------------------------
log "Удаление бэкапов старше $RETENTION_DAYS дней"
find "$BACKUP_DIR" -maxdepth 1 -name 'matrix-backup-*' -type f -mtime "+$RETENTION_DAYS" -delete 2>/dev/null || true

log "Готово"
