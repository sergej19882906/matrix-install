#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Аутентификация:
#   • Keycloak — OIDC/SSO-провайдер (нативный OIDC Synapse или legacy MAS)
#   • MAS      — legacy-режим (задеприкейтирован, требует старого Synapse)
# ---------------------------------------------------------------------------

render_auth_stack() {
	step "Рендеринг аутентификации"

	# --- Keycloak ---
	if [[ "${ENABLE_KEYCLOAK:-1}" == "1" ]]; then
		render "$TPL_DIR/docker-compose.keycloak.yml" "$STACK_DIR/docker-compose.keycloak.yml"
		render "$TPL_DIR/keycloak/realm.json" "$STACK_DIR/keycloak/import/matrix-realm.json"
	else
		rm -f "$STACK_DIR/docker-compose.keycloak.yml"
	fi

	# --- MAS (legacy) ---
	if [[ "${ENABLE_MAS:-0}" == "1" ]]; then
		render "$TPL_DIR/docker-compose.auth.yml" "$STACK_DIR/docker-compose.auth.yml"
		render "$TPL_DIR/mas/config.yaml" "$STACK_DIR/mas/config.yaml"
		chmod 600 "$STACK_DIR/mas/config.yaml"
	else
		rm -f "$STACK_DIR/docker-compose.auth.yml" "$STACK_DIR/mas/config.yaml"
	fi

	ok "Конфигурация аутентификации готова"
}

# Проверка конфигурации MAS бинарём mas-cli (если включён legacy-режим)
verify_mas_config() {
	[[ "${ENABLE_MAS:-0}" == "1" ]] || return 0
	have docker || return 0
	log "Проверка конфигурации MAS (mas-cli config check)"
	if docker run --rm \
		-v "$STACK_DIR/mas/config.yaml:/config.yaml:ro" \
		"ghcr.io/matrix-org/matrix-authentication-service:${MAS_VERSION:-latest}" \
		config check --config=/config.yaml >/dev/null 2>&1; then
		ok "Конфигурация MAS корректна"
	else
		warn "mas-cli config check не прошёл — проверьте $STACK_DIR/mas/config.yaml"
		docker run --rm -v "$STACK_DIR/mas/config.yaml:/config.yaml:ro" \
			"ghcr.io/matrix-org/matrix-authentication-service:${MAS_VERSION:-latest}" \
			config check --config=/config.yaml 2>&1 | tail -20 || true
	fi
}

start_auth_stack() {
	if [[ "${ENABLE_KEYCLOAK:-1}" == "1" ]]; then
		step "Запуск Keycloak"
		dc up -d keycloak
	fi
	if [[ "${ENABLE_MAS:-0}" == "1" ]]; then
		step "Запуск MAS (legacy-режим)"
		dc up -d mas mas-worker
	fi
	return 0
}

verify_auth_stack() {
	if [[ "${ENABLE_KEYCLOAK:-1}" == "1" ]]; then
		step "Проверка Keycloak"
		if dc exec -T keycloak curl -fsS "http://127.0.0.1:8080/realms/matrix" >/dev/null 2>&1; then
			ok "Realm 'matrix' импортирован в Keycloak"
		else
			warn "Realm не найден. Импорт выполняется при первом старте Keycloak."
			warn "Перезапуск: cd $STACK_DIR && docker compose up -d --force-recreate keycloak"
			warn "Логин: ${KEYCLOAK_ADMIN_USER} / $(grep -m1 '^KEYCLOAK_ADMIN_PASSWORD=' "$STACK_DIR/.env" | cut -d= -f2-)"
		fi
	fi
	if [[ "${ENABLE_MAS:-0}" == "1" ]]; then
		step "Проверка MAS"
		if dc exec -T mas mas-cli doctor >/dev/null 2>&1; then
			ok "MAS отвечает"
		else
			warn "MAS не отвечает — проверьте: docker logs matrix-mas"
		fi
	fi
}
