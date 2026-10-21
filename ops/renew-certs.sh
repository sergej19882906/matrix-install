#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Продление сертификатов Let's Encrypt + перезагрузка nginx.
# Запускается системным таймером matrix-certbot-renew.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

STACK_DIR="${STACK_DIR:-/opt/matrix}"
cd "$STACK_DIR"
# shellcheck disable=SC1091
source "$STACK_DIR/.env" 2>/dev/null || true

echo "[certbot] Продление сертификатов: $(date -u '+%F %T UTC')"

docker run --rm \
	-v "$STACK_DIR/certbot/conf:/etc/letsencrypt" \
	-v "$STACK_DIR/certbot/www:/var/www/certbot" \
	certbot/certbot:latest renew --webroot -w /var/www/certbot --quiet

if docker compose -f "$STACK_DIR/docker-compose.yml" --project-directory "$STACK_DIR" \
	exec -T nginx nginx -s reload 2>/dev/null; then
	echo "[certbot] nginx перезагружен"
else
	echo "[certbot] ВНИМАНИЕ: не удалось перезагрузить nginx" >&2
fi
