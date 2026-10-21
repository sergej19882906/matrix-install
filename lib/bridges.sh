#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Мосты: WhatsApp, Telegram, Signal, Discord (mautrix) и IRC (appservice-irc).
# Конфиги генерируются, регистрации кладутся в synapse/bridges/*.yaml —
# Synapse подхватывает их при старте (app_service_config_files).
# ---------------------------------------------------------------------------

# Токены генерируются один раз и переиспользуются при повторных установках.
bridge_token() {
	local name=$1 kind=$2
	local file="$STACK_DIR/bridges/tokens.env"
	[[ -f "$file" ]] || {
		mkdir -p "$(dirname "$file")"
		printf '# Токены мостов (сгенерированы автоматически)\n' >"$file"
		chmod 600 "$file"
	}
	local val
	val="$(sed -n "s/^${name}_${kind}=//p" "$file" | tail -1)"
	if [[ -z "$val" ]]; then
		val="$(hex 32)"
		printf '%s_%s=%s\n' "$name" "$kind" "$val" >>"$file"
		chmod 600 "$file"
	fi
	printf '%s' "$val"
}

# ---------------------------------------------------------------------------
# Регистрация application service для Synapse
# ---------------------------------------------------------------------------
write_as_registration() {
	local id=$1 sender=$2 port=$3
	# Имя сервиса в docker-compose (используется как DNS-имя из сети matrix)
	local svc="$id"
	case "$id" in
		telegram) svc="mautrix-telegram" ;;
		whatsapp) svc="mautrix-whatsapp" ;;
		signal)   svc="mautrix-signal" ;;
		discord)  svc="mautrix-discord" ;;
		irc)      svc="matrix-appservice-irc" ;;
	esac
	cat >"$STACK_DIR/synapse/bridges/${id}.yaml" <<EOF
id: ${id}
url: http://${svc}:${port}
as_token: $(bridge_token "$id" as)
hs_token: $(bridge_token "$id" hs)
rate_limited: false
sender_localpart: ${sender}
namespaces:
  users:
    - regex: "@${id}_.*:${SERVER_NAME}"
      exclusive: true
  aliases:
    - regex: "@${id}_.*:${SERVER_NAME}"
      exclusive: true
  rooms: []
EOF
}

# ---------------------------------------------------------------------------
# Общая часть конфига mautrix-мостов
# ---------------------------------------------------------------------------
mau_config() {
	local name=$1 sender=$2 displayname=$3 prefix=$4 extra=$5
	cat >"$STACK_DIR/bridges/${name}/config.yaml" <<EOF
homeserver:
  address: http://synapse:8008
  domain: ${SERVER_NAME}
  appservice:
    as_token: $(bridge_token "$name" as)
    hs_token: $(bridge_token "$name" hs)
    bot:
      username: ${sender}
      displayname: ${displayname}
      intent: display
  database:
    type: postgres
    uri: postgres://bridgebot:${BRIDGE_DB_PASSWORD}@postgres:5432/bridgebot
    prefix: ${prefix}
    maxConns: 10

appservice:
  ephemeral: true
  protocols:
    - ${name}

bridge:
  permissions:
    "*":
      - relay
      - "@${ADMIN_USERNAME}:${SERVER_NAME}"
  encryption:
    allow: true
    require: false
  portal:
    enabled: false
  displayname: ${displayname}
  bot:
    username: ${sender}
    displayname: ${displayname}
    intent: display
  media_store:
    type: postgres
    uri: postgres://bridgebot:${BRIDGE_DB_PASSWORD}@postgres:5432/bridgebot
    prefix: ${prefix}media_
    maxConns: 10
  double_puppet:
    server:
      url: http://synapse:8008
      domain: ${SERVER_NAME}
      appservice:
        as_token: $(bridge_token "$name" as)
        hs_token: $(bridge_token "$name" hs)
        bot:
          username: ${sender}
          displayname: ${displayname}
          intent: display
EOF
	if [[ -n "$extra" ]]; then
		printf '%s\n' "$extra" >>"$STACK_DIR/bridges/${name}/config.yaml"
	fi
}

# ---------------------------------------------------------------------------
render_bridges() {
	[[ "${ENABLE_BRIDGES:-1}" == "1" ]] || { log "Мосты отключены в конфигурации"; return 0; }

	step "Генерация конфигурации мостов"
	mkdir -p "$STACK_DIR/bridges"/{telegram,whatsapp,signal,discord,irc}
	render "$TPL_DIR/docker-compose.bridges.yml" "$STACK_DIR/docker-compose.bridges.yml"

	# --- Telegram ---
	mau_config telegram telegrambot "Telegram Bridge" mautrix_telegram_ "telegram:
  api_id: \"${TELEGRAM_API_ID}\"
  api_hash: \"${TELEGRAM_API_HASH}\"
  bot_token: \"\"
  use_registration_service: false
"
	write_as_registration telegram telegrambot 29325

	# --- WhatsApp ---
	mau_config whatsapp whatsappbot "WhatsApp Bridge" mautrix_whatsapp_ "whatsapp:
  bridgebot:
    displayname: WhatsApp bridge bot
"
	write_as_registration whatsapp whatsappbot 29325

	# --- Signal ---
	mau_config signal signalbot "Signal Bridge" mautrix_signal_ "signal:
  bridgebot:
    displayname: Signal bridge bot
"
	write_as_registration signal signalbot 29325

	# --- Discord ---
	mau_config discord discordbot "Discord Bridge" mautrix_discord_ "discord:
  token: \"${DISCORD_TOKEN}\"
  use_token: true
  bot:
    username: ${DISCORD_BOT_NAME:-discordbot}
    displayname: Discord bridge bot
"
	write_as_registration discord discordbot 29325

	# --- IRC ---
	local irc_conf="$STACK_DIR/bridges/irc/config.yaml"
	cat >"$irc_conf" <<EOF
ircServer:
  - hostname: "${IRC_SERVER:-irc.libera.chat}"
    port: ${IRC_PORT:-6697}
    tls: true
    bot:
      nick: "${IRC_NICK:-matrixbridge}"
      username: "${IRC_NICK:-matrixbridge}"
      password: "${IRC_PASSWORD:-}"
      realname: "Matrix IRC bridge"
      register: ${IRC_REGISTER_NICK:-true}
    channels:
      - - "${IRC_CHANNEL:-#matrix}"
        - key: "${IRC_CHANNEL:-#matrix}"
          aliases:
            - "${IRC_CHANNEL:-#matrix}:${SERVER_NAME}"
    dynamicChannels: true
    allowMentions: true
    port: ${IRC_PORT:-6697}

matrix:
  homeserver:
    url: "http://synapse:8008"
    domain: "${SERVER_NAME}"
    userIdSuffix: ""
    appservice:
      token: "$(bridge_token irc hs)"
      url: "http://matrix-appservice-irc:9999"
      asToken: "$(bridge_token irc as)"
  login:
    type: "m.login.password"
    username: "ircbot"
    password: "$(bridge_token irc as)"
  port: 9999
  bindAddress: "0.0.0.0"
  serverName: "ircbot"
  messageFormat: "[\$nick] \$message"
  quitMessage: "Связь с Matrix потеряна"
  stripIrrelevantMentions: false
EOF
	write_as_registration irc ircbot 9999

	chown -R 8008:8008 "$STACK_DIR/synapse/bridges" 2>/dev/null || true
	ok "Конфигурация мостов создана"
}

# ---------------------------------------------------------------------------
# Регистрация списка appservice-файлов в homeserver.yaml
# ---------------------------------------------------------------------------
update_synapse_appservices() {
	local files=()
	local f
	for f in "$STACK_DIR"/synapse/bridges/*.yaml; do
		[[ -e "$f" ]] || continue
		# Путь внутри контейнера Synapse (каталог /data монтируется в ./synapse)
		files+=("\"/data/bridges/$(basename "$f")\"")
	done
	local list
	if [[ ${#files[@]} -gt 0 ]]; then
		list="[$(IFS=,; echo "${files[*]}")]"
	else
		list="[]"
	fi
	if grep -q '__APP_SERVICE_FILES__' "$STACK_DIR/synapse/homeserver.yaml"; then
		sed -i "s|__APP_SERVICE_FILES__|${list}|" "$STACK_DIR/synapse/homeserver.yaml"
	else
		sed -i "s|^app_service_config_files:.*|app_service_config_files: ${list}|" "$STACK_DIR/synapse/homeserver.yaml"
	fi
	ok "Приложения прописаны в homeserver.yaml: ${list}"
}

# ---------------------------------------------------------------------------
# Старт мостов
# ---------------------------------------------------------------------------
start_bridges() {
	[[ "${ENABLE_BRIDGES:-1}" == "1" ]] || return 0
	step "Запуск мостов"
	dc up -d mautrix-telegram mautrix-whatsapp mautrix-signal mautrix-discord matrix-appservice-irc || warn "Не все мосты поднялись"
	dc logs --tail=3 mautrix-telegram 2>/dev/null | sed 's/^/  telegram: /' || true
}
