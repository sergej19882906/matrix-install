#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Финализация: регистрация, админ, делегирование well-known, проверки, итоги.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Включение/выключение публичной регистрации
# ---------------------------------------------------------------------------
apply_registration_policy() {
	local hs="$STACK_DIR/synapse/homeserver.yaml"
	if [[ "${ENABLE_MAS:-0}" == "1" ]]; then
		# Synapse запрещает enable_registration при делегировании в MAS
		sed -i 's/^enable_registration: true/enable_registration: false/' "$hs"
		sed -i 's/^enable_registration: false/enable_registration: false/' "$hs"
		warn "С MAS включена публичная регистрация невозможна (Synapse запрещает enable_registration)."
		ok "Регистрация: через MAS/Keycloak"
	elif [[ "${PUBLIC_REGISTRATION:-0}" == "1" ]]; then
		sed -i 's/^enable_registration: false/enable_registration: true/' "$hs"
		ok "Публичная регистрация включена"
	else
		sed -i 's/^enable_registration: true/enable_registration: false/' "$hs"
		ok "Публичная регистрация отключена"
	fi
}

# ---------------------------------------------------------------------------
# Создание администратора
# ---------------------------------------------------------------------------
create_admin_user() {
	step "Создание администратора"
	local user="${SYNAPSE_ADMIN_USERNAME:-admin}"
	local pass
	pass="$(grep -m1 '^ADMIN_PASSWORD=' "$STACK_DIR/.env" 2>/dev/null | cut -d= -f2-)"
	if [[ -z "$pass" ]]; then
		pass="$(passw 20)"
		sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$pass|" "$STACK_DIR/.env"
		grep -q '^ADMIN_PASSWORD=' "$STACK_DIR/.env" || printf 'ADMIN_PASSWORD=%s\n' "$pass" >>"$STACK_DIR/.env"
		chmod 600 "$STACK_DIR/.env"
	fi

	# 1) Legacy-режим MAS: пользователя создаёт MAS
	if [[ "${ENABLE_MAS:-0}" == "1" ]]; then
		if dc exec -T mas mas-cli manage register-user -y "$user" --password "$pass" \
			--email "$ADMIN_EMAIL" --admin >/dev/null 2>&1; then
			ok "Администратор $user создан через MAS"
		else
			warn "Не удалось создать администратора через MAS (возможно, он уже существует)"
		fi
	else
		# 2) Обычный режим: штатная регистрация Synapse
		if dc exec -T synapse register_new_matrix_user -u "$user" -p "$pass" -a >/dev/null 2>&1; then
			ok "Администратор $user создан"
		else
			warn "register_new_matrix_user не отработал (возможно, пользователь уже существует)"
		fi
	fi

	printf '\n╔══════════════════════════════════════════════════╗\n'
	printf '║  Администратор Matrix                            ║\n'
	printf '║  Логин:  %-42s ║\n' "@$user:$SERVER_NAME"
	printf '║  Пароль: %-42s ║\n' "$pass"
	printf '╚══════════════════════════════════════════════════╝\n'
	printf 'Пароль также сохранён в %s\n\n' "$STACK_DIR/.env"
}

# ---------------------------------------------------------------------------
# Делегирование через matrix.org (необязательно)
# ---------------------------------------------------------------------------
delegate_to_matrix_org() {
	local token="${MATRIX_ORG_TOKEN:-}"
	if [[ -z "$token" ]]; then
		log "MATRIX_ORG_TOKEN не задан — делегирование на matrix.org пропущено"
		return 0
	fi
	step "Делегирование server_name через matrix.org"
	local resp
	resp="$(curl -fsS -X POST \
		-H "Authorization: Bearer $token" \
		-H "Content-Type: application/json" \
		-d "{\"homeserver\":\"${MATRIX_DOMAIN}\",\"server_name\":\"${SERVER_NAME}\"}" \
		https://matrix-client.matrix.org/_matrix/client/v3/account/delegation 2>&1)" && {
		ok "Делегирование зарегистрировано: $resp"
	} || warn "Не удалось зарегистрировать делегирование: $resp"
}

# ---------------------------------------------------------------------------
# Итоговая проверка
# ---------------------------------------------------------------------------
verify_installation() {
	step "Проверка установки"

	# Synapse
	if dc exec -T synapse python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8008/health',timeout=5)" >/dev/null 2>&1; then
		ok "Synapse: /health отвечает"
	else
		warn "Synapse: health-check не прошёл"
	fi

	# Версии Matrix
	local versions
	versions="$(curl -fsS --max-time 10 "https://${MATRIX_DOMAIN}/_matrix/client/versions" 2>/dev/null || true)"
	if [[ -n "$versions" ]]; then
		ok "Клиентский API доступен ($(printf '%s' "$versions" | jq -r '.versions[-1]' 2>/dev/null || echo '?'))"
	else
		warn "Клиентский API не отвечает по https://${MATRIX_DOMAIN}/_matrix/client/versions"
		warn "Проверьте DNS и сертификат для $MATRIX_DOMAIN"
	fi

	# Методы входа
	local flows
	flows="$(curl -fsS --max-time 10 "https://${MATRIX_DOMAIN}/_matrix/client/v3/login" 2>/dev/null || true)"
	if [[ -n "$flows" ]]; then
		local types
		types="$(printf '%s' "$flows" | jq -r '[.flows[].type] | join(", ")' 2>/dev/null || echo '?')"
		ok "Методы входа: $types"
	else
		warn "Не удалось получить список методов входа"
	fi

	# Element
	if curl -fsS --max-time 10 "https://${ELEMENT_DOMAIN}/" >/dev/null 2>&1; then
		ok "Element Web доступен"
	else
		warn "Element Web не отвечает по https://${ELEMENT_DOMAIN}/"
	fi

	# TURN
	if [[ "${ENABLE_TURN:-1}" == "1" ]]; then
		if tcp_open 127.0.0.1 3478; then ok "TURN (3478) слушает"; else warn "TURN (3478) не слушает"; fi
	fi

	# Мосты
	if [[ "${ENABLE_BRIDGES:-1}" == "1" ]]; then
		local b
		for b in mautrix-telegram mautrix-whatsapp mautrix-signal mautrix-discord matrix-appservice-irc; do
			local state
			state="$(dc ps --format '{{.Service}} {{.State}}' 2>/dev/null | grep -E "^${b} " | awk '{print $2}' | head -1)"
			if [[ "$state" == "running" ]]; then ok "Мост $b запущен"; else warn "Мост $b: ${state:-не найден}"; fi
		done
	fi

	# Мониторинг
	if [[ "${ENABLE_MONITORING:-1}" == "1" ]]; then
		if curl -fsS --max-time 5 "http://127.0.0.1:3000/api/health" >/dev/null 2>&1; then
			ok "Grafana отвечает"
		else
			warn "Grafana не отвечает"
		fi
	fi
}

# ---------------------------------------------------------------------------
print_summary() {
	local admin_pass
	admin_pass="$(grep '^ADMIN_PASSWORD=' "$STACK_DIR/.env" 2>/dev/null | cut -d= -f2-)"
	local grafana_pass
	grafana_pass="$(grep '^GRAFANA_ADMIN_PASSWORD=' "$STACK_DIR/.env" 2>/dev/null | cut -d= -f2-)"

	cat <<EOF

${C_BLD}${C_CYN}══════════════════════════════════════════════════════════════
  УСТАНОВКА ЗАВЕРШЕНА
${C_RST}${C_BLD}${C_CYN}══════════════════════════════════════════════════════════════${C_RST}

  Homeserver : https://${MATRIX_DOMAIN}/
  Element    : https://${ELEMENT_DOMAIN}/
$( [[ "${ENABLE_KEYCLOAK:-1}" == "1" ]] && printf '  Keycloak  : https://%s/  (%s / %s)\n' "$KEYCLOAK_DOMAIN" "$KEYCLOAK_ADMIN_USER" "$KEYCLOAK_ADMIN_PASSWORD" )
$( [[ "${ENABLE_MAS:-0}" == "1" ]] && printf '  MAS (legacy): https://%s/\n' "$MAS_DOMAIN" )
  Админка    : https://${ADMIN_DOMAIN}/
$( [[ "${ENABLE_MONITORING:-1}" == "1" ]] && printf '  Grafana   : https://%s/  (admin / %s)\n' "$GRAFANA_DOMAIN" "$grafana_pass" )
  TURN       : ${TURN_DOMAIN} (turn/turns, 3478/5349)

  Вход       : $( [[ "${ENABLE_MAS:-0}" == "1" ]] && echo "legacy MAS + Keycloak" || { [[ "${ENABLE_OIDC:-1}" == "1" ]] && echo "пароль + SSO через Keycloak" || echo "локальный пароль"; } )
  Админ Matrix: @${SYNAPSE_ADMIN_USERNAME:-admin}:${SERVER_NAME} / ${admin_pass}

  Стек       : ${STACK_DIR}
  Логи       : cd ${STACK_DIR} && docker compose logs -f
  Бэкапы    : ${STACK_DIR}/bin/backup.sh  (таймер: matrix-backup.timer)

${C_BLD}${C_YEL}ЧТО СДЕЛАТЬ ДАЛЬШЕ${C_RST}
  1. Проверить DNS: все домены должны указывать на ${PUBLIC_IP}
  2. Открыть вход в мессенджере: https://${ELEMENT_DOMAIN}/
  3. Войти через SSO (Keycloak) на https://${KEYCLOAK_DOMAIN}/
  4. Залогиниться в мосты (QR/код) — смотрите логи:
       cd ${STACK_DIR} && docker compose logs -f mautrix-whatsapp
  5. Проверить федерацию: https://matrix.org/client-element/room/#/directory
  6. Настроить делегирование на matrix.org (опционально):
       export MATRIX_ORG_TOKEN=<токен> && bash ${SCRIPT_DIR}/install.sh --delegate-only

EOF
}
