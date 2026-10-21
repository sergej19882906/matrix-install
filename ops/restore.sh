#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Восстановление Matrix-стека из резервной копии.
#
#   ./restore.sh --list                      список локальных бэкапов
#   ./restore.sh --file matrix-backup-*.tar.gz[.enc] [--yes]
#   ./restore.sh --file ... --passphrase "..."
#
# ВНИМАНИЕ: восстановление перезаписывает базы данных!
# ---------------------------------------------------------------------------
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/opt/matrix}"
BACKUP_DIR="${BACKUP_DIR:-$STACK_DIR/backup}"
FILE=""
ASSUME_YES=0
PASSPHRASE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--list) ls -lh "$BACKUP_DIR"/matrix-backup-* 2>/dev/null || echo "Бэкапов нет"; exit 0 ;;
		--file) FILE=$2; shift 2 ;;
		--passphrase) PASSPHRASE=$2; shift 2 ;;
		--yes|-y) ASSUME_YES=1; shift ;;
		*) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
	esac
done

[[ -n "$FILE" ]] || { echo "Укажите --file <архив>" >&2; exit 1; }
[[ -f "$FILE" ]] || { echo "Файл не найден: $FILE" >&2; exit 1; }

cd "$STACK_DIR"
# shellcheck disable=SC1091
source "$STACK_DIR/.env"

if [[ $ASSUME_YES -ne 1 ]]; then
	echo "Будет выполнено восстановление в $STACK_DIR (базы данных будут перезаписаны)."
	read -r -p "Продолжить? [y/N] " ans
	[[ "$ans" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/matrix-restore-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cp "$FILE" "$WORK/archive.tar.gz"
if [[ "$FILE" == *.enc ]]; then
	[[ -n "$PASSPHRASE" ]] || PASSPHRASE="${BACKUP_PASSPHRASE:-}"
	[[ -n "$PASSPHRASE" ]] || { echo "Нужен пароль шифрования (--passphrase)"; exit 1; }
	openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
		-in "$WORK/archive.tar.gz" -out "$WORK/plain.tar.gz" -pass "pass:$PASSPHRASE"
	mv "$WORK/plain.tar.gz" "$WORK/archive.tar.gz"
fi

tar -xzf "$WORK/archive.tar.gz" -C "$WORK"
echo "Содержимое архива:"
ls -1 "$WORK"

compose() { docker compose -f "$STACK_DIR/docker-compose.yml" --project-directory "$STACK_DIR" "$@"; }

echo "Остановка сервисов..."
compose stop synapse mas keycloak 2>/dev/null || true

for db in synapse mas keycloak; do
	if [[ -f "$WORK/${db}.sql.gz" ]]; then
		echo "Восстановление базы $db..."
		gunzip -c "$WORK/${db}.sql.gz" | compose exec -T postgres psql -U matrix -d "$db" -v ON_ERROR_STOP=0 >/dev/null
		echo "  $db — восстановлена"
	fi
done

if [[ -f "$WORK/media_store.tar.gz" ]]; then
	echo "Восстановление медиа-хранилища..."
	compose up -d postgres >/dev/null
	tar -xzf "$WORK/media_store.tar.gz" -C "$STACK_DIR/synapse"
	echo "  медиа — восстановлено"
fi

echo "Запуск сервисов..."
compose up -d
echo "Готово. Проверка: docker compose -f $STACK_DIR/docker-compose.yml ps"
