#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Обновление стека: новые образы, перезапуск, миграции БД, чистка.
#   ./upgrade.sh [--backup]
# ---------------------------------------------------------------------------
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/opt/matrix}"
cd "$STACK_DIR"

if [[ "${1:-}" == "--backup" ]]; then
	echo "=== Резервная копия перед обновлением ==="
	"$STACK_DIR/bin/backup.sh" --quiet || echo "Предупреждение: бэкап не удался, продолжаю"
fi

COMPOSE_FILES=(-f "$STACK_DIR/docker-compose.yml")
for f in docker-compose.auth.yml docker-compose.keycloak.yml docker-compose.turn.yml docker-compose.bridges.yml docker-compose.monitoring.yml; do
	[[ -f "$STACK_DIR/$f" ]] && COMPOSE_FILES+=(-f "$STACK_DIR/$f")
done

dc() { docker compose "${COMPOSE_FILES[@]}" --project-directory "$STACK_DIR" "$@"; }

echo "=== Скачивание образов ==="
dc pull

echo "=== Перезапуск сервисов ==="
dc up -d --remove-orphans

echo "=== Миграции базы данных ==="
echo "Synapse и MAS применяют миграции автоматически при старте."

echo "=== Очистка неиспользуемых образов ==="
docker image prune -f

echo "=== Состояние ==="
dc ps
