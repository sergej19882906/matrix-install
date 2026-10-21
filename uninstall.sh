#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Полное удаление Matrix-стека.
#    sudo bash uninstall.sh --purge    — вместе с данными (БД, медиа, сертификаты)
# ---------------------------------------------------------------------------
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/opt/matrix}"
PURGE=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--purge) PURGE=1; shift ;;
		-h|--help)
			echo "Использование: sudo bash uninstall.sh [--purge]"
			echo "  --purge  удалить также данные (volumes, БД, медиа, сертификаты)"
			exit 0
			;;
		*) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
	esac
done

[[ "${EUID}" -eq 0 ]] || { echo "Нужен root" >&2; exit 1; }

echo "Остановка и удаление контейнеров..."
if [[ -f "$STACK_DIR/docker-compose.yml" ]]; then
	cd "$STACK_DIR"
	FILES=(-f "$STACK_DIR/docker-compose.yml")
	for f in docker-compose.auth.yml docker-compose.keycloak.yml docker-compose.turn.yml docker-compose.bridges.yml docker-compose.monitoring.yml; do
		[[ -f "$STACK_DIR/$f" ]] && FILES+=(-f "$STACK_DIR/$f")
	done
	docker compose "${FILES[@]}" --project-directory "$STACK_DIR" down --remove-orphans || true
fi

systemctl disable --now matrix-backup.timer matrix-certbot-renew.timer 2>/dev/null || true
rm -f /etc/systemd/system/matrix-backup.* /etc/systemd/system/matrix-certbot-renew.*
systemctl daemon-reload 2>/dev/null || true

if [[ $PURGE -eq 1 ]]; then
	echo "Удаление данных..."
	docker volume rm -f matrix-postgres-data matrix-prometheus-data 2>/dev/null || true
	rm -rf "$STACK_DIR"
	echo "Каталог $STACK_DIR удалён"
else
	echo "Каталог с данными сохранён: $STACK_DIR"
	echo "Полное удаление: sudo bash uninstall.sh --purge"
fi

echo "Готово."
