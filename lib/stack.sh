#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Ядро стека: подготовка каталогов, рендеринг конфигов, docker compose,
# получение сертификатов Let's Encrypt.
# ---------------------------------------------------------------------------

STACK_DIR="${STACK_DIR:-/opt/matrix}"
TPL_DIR="$SCRIPT_DIR/templates"

# ---------------------------------------------------------------------------
prepare_stack_dir() {
	step "Подготовка каталога стека: $STACK_DIR"
	mkdir -p \
		"$STACK_DIR"/{postgres/init,synapse/bridges,synapse/media_store,element,nginx/conf.d,coturn,synapse-admin,certbot/www,certbot/conf,bin,logs,backup,mas,keycloak/data,keycloak/import,bridges,monitoring/prometheus,monitoring/grafana/provisioning/datasources,monitoring/grafana/provisioning/dashboards,monitoring/grafana/dashboards,monitoring/grafana/data,rclone} \
		"$STACK_DIR"/well-known/.well-known/matrix

	# Права доступа под контейнеры
	chown -R 8008:8008 "$STACK_DIR/synapse" 2>/dev/null || true
	chmod -R u+rwX "$STACK_DIR/synapse"
	chmod 0777 "$STACK_DIR/mas" "$STACK_DIR/keycloak/data" 2>/dev/null || true
	chmod 0777 "$STACK_DIR/monitoring/grafana/data" 2>/dev/null || true
	chmod 0755 "$STACK_DIR"

	# Рабочие скрипты
	install -m 0755 "$SCRIPT_DIR/ops/"*.sh "$STACK_DIR/bin/" 2>/dev/null || true

	ok "Каталоги подготовлены"
}

# ---------------------------------------------------------------------------
# docker compose helper
# ---------------------------------------------------------------------------
compose_files() {
	local files=("$STACK_DIR/docker-compose.yml")
	[[ "${ENABLE_MAS:-1}" == "1" ]] && files+=("$STACK_DIR/docker-compose.auth.yml")
	[[ "${ENABLE_KEYCLOAK:-1}" == "1" ]] && files+=("$STACK_DIR/docker-compose.keycloak.yml")
	[[ "${ENABLE_TURN:-1}" == "1" ]] && files+=("$STACK_DIR/docker-compose.turn.yml")
	[[ "${ENABLE_BRIDGES:-1}" == "1" ]] && files+=("$STACK_DIR/docker-compose.bridges.yml")
	[[ "${ENABLE_MONITORING:-1}" == "1" ]] && files+=("$STACK_DIR/docker-compose.monitoring.yml")
	printf '%s\n' "${files[@]}"
}

# dc <docker compose args...>
dc() {
	local -a args=()
	local f
	while IFS= read -r f; do
		[[ -f "$f" ]] && args+=(-f "$f")
	done < <(compose_files)
	docker compose "${args[@]}" --project-directory "$STACK_DIR" "$@"
}

# ---------------------------------------------------------------------------
# Рендеринг конфигурации
# ---------------------------------------------------------------------------
render_stack() {
	step "Рендеринг конфигурации сервисов"

	# --- Docker Compose ---
	render "$TPL_DIR/docker-compose.yml" "$STACK_DIR/docker-compose.yml"

	# --- Postgres ---
	render "$TPL_DIR/postgres/init/01-databases.sql" "$STACK_DIR/postgres/init/01-databases.sql"

	# --- Synapse ---
	render "$TPL_DIR/synapse/homeserver.yaml" "$STACK_DIR/synapse/homeserver.yaml"
	render "$TPL_DIR/synapse/log.config" "$STACK_DIR/synapse/log.config"

	# --- Блок аутентификации Synapse ---
	local auth_part="$STACK_DIR/synapse/auth-part.yaml"
	if [[ "${ENABLE_MAS:-0}" == "1" ]]; then
		render "$TPL_DIR/synapse/auth-mas.yaml" "$auth_part"
	elif [[ "${ENABLE_OIDC:-1}" == "1" ]]; then
		render "$TPL_DIR/synapse/auth-oidc.yaml" "$auth_part"
	else
		cat >"$auth_part" <<'EOF'
password_config:
  enabled: true
EOF
	fi
	cat "$auth_part" >>"$STACK_DIR/synapse/homeserver.yaml"
	rm -f "$auth_part"

	# --- Element ---
	render "$TPL_DIR/element/config.json" "$STACK_DIR/element/config.json"

	# --- synapse-admin ---
	render "$TPL_DIR/synapse-admin/config.json" "$STACK_DIR/synapse-admin/config.json"

	# --- coturn ---
	if [[ "${ENABLE_TURN:-1}" == "1" ]]; then
		render "$TPL_DIR/coturn/turnserver.conf" "$STACK_DIR/coturn/turnserver.conf"
		render "$TPL_DIR/docker-compose.turn.yml" "$STACK_DIR/docker-compose.turn.yml"
	else
		rm -f "$STACK_DIR/docker-compose.turn.yml"
	fi

	# --- nginx (финальная версия — с TLS) ---
	render "$TPL_DIR/nginx/nginx.conf" "$STACK_DIR/nginx/nginx.conf"
	render "$TPL_DIR/nginx/conf.d/ssl.inc" "$STACK_DIR/nginx/conf.d/ssl.inc"
	render "$TPL_DIR/nginx/conf.d/10-matrix.conf" "$STACK_DIR/nginx/conf.d/10-matrix.conf"
	render "$TPL_DIR/nginx/conf.d/20-element.conf" "$STACK_DIR/nginx/conf.d/20-element.conf"
	[[ "${ENABLE_MAS:-1}" == "1" ]] && render "$TPL_DIR/nginx/conf.d/30-mas.conf" "$STACK_DIR/nginx/conf.d/30-mas.conf"
	[[ "${ENABLE_KEYCLOAK:-1}" == "1" ]] && render "$TPL_DIR/nginx/conf.d/40-keycloak.conf" "$STACK_DIR/nginx/conf.d/40-keycloak.conf"
	render "$TPL_DIR/nginx/conf.d/50-admin.conf" "$STACK_DIR/nginx/conf.d/50-admin.conf"
	[[ "${ENABLE_MONITORING:-1}" == "1" ]] && render "$TPL_DIR/nginx/conf.d/60-grafana.conf" "$STACK_DIR/nginx/conf.d/60-grafana.conf"
	[[ -n "${APEX_DOMAIN:-}" ]] && render "$TPL_DIR/nginx/conf.d/70-wellknown.conf" "$STACK_DIR/nginx/conf.d/70-wellknown.conf"
	if [[ "${ENABLE_MAS:-0}" == "1" ]]; then
		render "$TPL_DIR/nginx/conf.d/mas-compat.inc" "$STACK_DIR/nginx/conf.d/mas-compat.inc"
	else
		: >"$STACK_DIR/nginx/conf.d/mas-compat.inc"
	fi

	ok "Конфигурация отрендерена в $STACK_DIR"
}

# ---------------------------------------------------------------------------
# /.well-known/matrix
# ---------------------------------------------------------------------------
render_wellknown() {
	local wk="$STACK_DIR/well-known/.well-known/matrix"
	mkdir -p "$wk"
	cat >"$wk/client" <<EOF
{
  "m.homeserver": {
    "base_url": "https://${MATRIX_DOMAIN}",
    "server_name": "${SERVER_NAME}"
  }
}
EOF
	cat >"$wk/server" <<EOF
{
  "m.server": "${MATRIX_DOMAIN}:443"
}
EOF
	ok "Файлы /.well-known/matrix сгенерированы"
}

# ---------------------------------------------------------------------------
# Let's Encrypt
# ---------------------------------------------------------------------------
cert_domains() {
	local -a d=("$MATRIX_DOMAIN" "$ELEMENT_DOMAIN" "$ADMIN_DOMAIN")
	[[ "${ENABLE_MAS:-1}" == "1" ]] && d+=("$MAS_DOMAIN")
	[[ "${ENABLE_KEYCLOAK:-1}" == "1" ]] && d+=("$KEYCLOAK_DOMAIN")
	[[ "${ENABLE_MONITORING:-1}" == "1" ]] && d+=("$GRAFANA_DOMAIN")
	[[ "${ENABLE_TURN:-1}" == "1" ]] && d+=("$TURN_DOMAIN")
	printf '%s\n' "${d[@]}"
}

render_nginx_bootstrap() {
	rm -f "$STACK_DIR"/nginx/conf.d/*.conf "$STACK_DIR"/nginx/conf.d/*.inc
	render "$TPL_DIR/nginx/bootstrap.conf" "$STACK_DIR/nginx/conf.d/00-bootstrap.conf"
}

render_nginx_final() {
	rm -f "$STACK_DIR"/nginx/conf.d/*.conf "$STACK_DIR"/nginx/conf.d/*.inc
	render "$TPL_DIR/nginx/conf.d/ssl.inc" "$STACK_DIR/nginx/conf.d/ssl.inc"
	render "$TPL_DIR/nginx/conf.d/10-matrix.conf" "$STACK_DIR/nginx/conf.d/10-matrix.conf"
	render "$TPL_DIR/nginx/conf.d/20-element.conf" "$STACK_DIR/nginx/conf.d/20-element.conf"
	[[ "${ENABLE_MAS:-1}" == "1" ]] && render "$TPL_DIR/nginx/conf.d/30-mas.conf" "$STACK_DIR/nginx/conf.d/30-mas.conf"
	[[ "${ENABLE_KEYCLOAK:-1}" == "1" ]] && render "$TPL_DIR/nginx/conf.d/40-keycloak.conf" "$STACK_DIR/nginx/conf.d/40-keycloak.conf"
	render "$TPL_DIR/nginx/conf.d/50-admin.conf" "$STACK_DIR/nginx/conf.d/50-admin.conf"
	[[ "${ENABLE_MONITORING:-1}" == "1" ]] && render "$TPL_DIR/nginx/conf.d/60-grafana.conf" "$STACK_DIR/nginx/conf.d/60-grafana.conf"
	[[ -n "${APEX_DOMAIN:-}" ]] && render "$TPL_DIR/nginx/conf.d/70-wellknown.conf" "$STACK_DIR/nginx/conf.d/70-wellknown.conf"
	if [[ "${ENABLE_MAS:-0}" == "1" ]]; then
		render "$TPL_DIR/nginx/conf.d/mas-compat.inc" "$STACK_DIR/nginx/conf.d/mas-compat.inc"
	else
		: >"$STACK_DIR/nginx/conf.d/mas-compat.inc"
	fi
}

certbot_run() {
	docker run --rm \
		-v "$STACK_DIR/certbot/conf:/etc/letsencrypt" \
		-v "$STACK_DIR/certbot/www:/var/www/certbot" \
		certbot/certbot:latest "$@"
}

obtain_certificates() {
	if [[ "${SKIP_CERTS:-0}" == "1" ]]; then
		warn "Сертификаты пропущены (--skip-certs). Разместите их в $STACK_DIR/certbot/conf/live/$LETSENCRYPT_CERT/"
		return 0
	fi

	step "Получение сертификатов Let's Encrypt"
	[[ -f "$STACK_DIR/certbot/conf/live/$LETSENCRYPT_CERT/fullchain.pem" ]] && {
		ok "Сертификат уже существует — продление выполняется таймером"
		render_nginx_final
		return 0
	}

	render_nginx_bootstrap
	log "Запускаю nginx (bootstrap) и postgres"
	dc up -d postgres nginx >/dev/null
	wait_http "http://127.0.0.1/nginx-health" 90 || warn "nginx-health не отвечает, продолжаю"

	local -a domains=()
	while IFS= read -r d; do domains+=(-d "$d"); done < <(cert_domains)
	log "Домены в сертификате: ${domains[*]}"

	# Проверяем, что домены резолвятся в этот сервер
	local d ip
	for d in "${domains[@]}"; do
		ip="$(getent hosts "$d" 2>/dev/null | awk '{print $1; exit}')"
		if [[ -z "$ip" ]]; then
			warn "Домен $d не резолвится — Let's Encrypt может не пройти валидацию"
		fi
	done

	local rc=0
	certbot_run certonly --webroot -w /var/www/certbot \
		--email "$ADMIN_EMAIL" --agree-tos --no-eff-email --non-interactive \
		--rsa-key-size 4096 --keep-until-expiring \
		--cert-name "$LETSENCRYPT_CERT" "${domains[@]}" || rc=$?

	if [[ $rc -ne 0 ]]; then
		warn "Webroot-валидация не удалась, пробую standalone (порт 80 освобождается)"
		dc stop nginx >/dev/null 2>&1 || true
		sleep 3
		local -a sdomains=()
		for d in "${domains[@]}"; do sdomains+=(-d "$d"); done
		certbot_run certonly --standalone \
			--email "$ADMIN_EMAIL" --agree-tos --no-eff-email --non-interactive \
			--rsa-key-size 4096 --keep-until-expiring \
			--cert-name "$LETSENCRYPT_CERT" "${sdomains[@]}" || {
			err "Не удалось получить сертификат."
			err "Проверьте: 1) DNS всех доменов указывает на $PUBLIC_IP; 2) порт 80 открыт снаружи; 3) ACME не заблокирован."
			err "Либо установите сертификат вручную в $STACK_DIR/certbot/conf/live/$LETSENCRYPT_CERT/ и запустите с --skip-certs"
			return 1
		}
	fi

	render_nginx_final
	# nginx сейчас работает с bootstrap-конфигурацией; финальная (с TLS)
	# применится при пересоздании контейнера в start_nginx — там уже
	# запущены все апстримы, и DNS-имена корректно разрешатся.
	ok "Сертификаты получены: $LETSENCRYPT_CERT"
}

# ---------------------------------------------------------------------------
# Запуск стека
# ---------------------------------------------------------------------------
start_stack() {
	step "Запуск сервисов"
	dc pull >/dev/null 2>&1 || warn "Часть образов не удалось обновить (продолжаю с локальными)"

	# Создаём все контейнеры заранее: так nginx корректно разрешает
	# DNS-имена всех сервисов (mas, keycloak, grafana) при старте
	dc create >/dev/null 2>&1 || warn "dc create завершился с ошибкой (не критично)"

	# Сначала поднимаем всё, кроме nginx: nginx резолвит апстримы при старте
	# и не может подняться, пока соответствующие контейнеры не запущены.
	local services
	services="$(dc config --services 2>/dev/null | grep -v '^nginx$' | tr '\n' ' ')"
	if [[ -n "$services" ]]; then
		# shellcheck disable=SC2086
		dc up -d $services >/dev/null 2>&1 || warn "Не все сервисы поднялись - смотрите: dc ps"
	fi

	ok "Контейнеры запущены (nginx поднимается последним)"
}

# nginx поднимается последним: он резолвит DNS-имена всех апстримов
# (synapse, element-web, mas, keycloak, grafana, synapse-admin) при старте.
start_nginx() {
	step "Запуск nginx"
	dc up -d --force-recreate nginx >/dev/null 2>&1 || warn "nginx не поднялся - смотрите: dc logs nginx"
	sleep 3
	if dc exec -T nginx nginx -t >/dev/null 2>&1; then
		ok "nginx работает, конфигурация корректна"
	else
		warn "nginx: конфигурация не прошла проверку"
		dc logs nginx 2>&1 | tail -10
	fi
}

wait_services_ready() {
	step "Ожидание готовности сервисов"
	if dc exec -T postgres pg_isready -U matrix -d postgres >/dev/null 2>&1; then
		ok "postgres готов"
	else
		warn "postgres не отвечает"
	fi
	if dc exec -T synapse python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8008/health',timeout=5)" >/dev/null 2>&1; then
		ok "Synapse готов"
	else
		warn "Synapse не отвечает — смотрите: docker logs matrix-synapse"
	fi
}
