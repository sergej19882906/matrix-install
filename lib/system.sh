#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Системный слой: определение ОС, пакеты, Docker Engine, файрвол.
# ---------------------------------------------------------------------------

OS_ID="" OS_VERSION="" OS_CODENAME="" OS_PRETTY="" OS_FAMILY=""

detect_os() {
	[[ -r /etc/os-release ]] || die "Не найден /etc/os-release — не удалось определить ОС"
	# shellcheck disable=SC1091
	source /etc/os-release
	OS_ID="${ID:-unknown}"
	OS_VERSION="${VERSION_ID:-}"
	# shellcheck disable=SC2034  # информационный, используется в логах
	OS_CODENAME="${VERSION_CODENAME:-}"
	OS_PRETTY="${PRETTY_NAME:-${OS_ID} ${OS_VERSION}}"
	case "$OS_ID" in
		debian|ubuntu)                       OS_FAMILY="debian" ;;
		rhel|centos|rocky|almalinux|ol|fedora) OS_FAMILY="rhel" ;;
		arch|manjaro|endeavouros)            OS_FAMILY="arch" ;;
		alpine)                             OS_FAMILY="alpine" ;;
		*)                                   OS_FAMILY="other" ;;
	esac
	log "Обнаружена ОС: ${OS_PRETTY} (семейство: ${OS_FAMILY})"
}

pkg_install() {
	local -a pkgs=("$@")
	[[ ${#pkgs[@]} -gt 0 ]] || return 0
	log "Установка пакетов: ${pkgs[*]}"
	case "$OS_FAMILY" in
		debian)
			export DEBIAN_FRONTEND=noninteractive
			apt-get update -qq
			apt-get install -y --no-install-recommends "${pkgs[@]}"
			;;
		rhel)
			if have dnf; then dnf install -y "${pkgs[@]}"; else yum install -y "${pkgs[@]}"; fi
			;;
		arch)
			pacman -Sy --noconfirm "${pkgs[@]}"
			;;
		alpine)
			apk add --no-cache "${pkgs[@]}"
			;;
		*)
			die "Неизвестное семейство ОС ($OS_ID). Установите вручную: ${pkgs[*]} и запустите с --skip-deps"
			;;
	esac
}

# Базовые зависимости (curl, openssl, jq, envsubst, rsync, tar, python3).
install_base_deps() {
	local -a need=()
	have curl    || need+=(curl)
	have openssl || need+=(openssl)
	have jq      || need+=(jq)
	have rsync   || need+=(rsync)
	have tar     || need+=(tar)
	have python3 || need+=(python3)
	have envsubst || {
		case "$OS_FAMILY" in
			debian) need+=(gettext-base) ;;
			rhel)   need+=(gettext) ;;
			arch)   need+=(gettext) ;;
			alpine) need+=(gettext) ;;
		esac
	}
	if [[ ${#need[@]} -gt 0 ]]; then
		pkg_install "${need[@]}"
	fi
	ok "Системные зависимости на месте"
}

# ---------------------------------------------------------------------------
# Docker Engine + Compose v2
# ---------------------------------------------------------------------------
install_docker() {
	if have docker && docker compose version >/dev/null 2>&1; then
		ok "Docker уже установлен: $(docker --version), $(docker compose version | head -1)"
	else
		step "Установка Docker Engine и Compose v2"
		case "$OS_FAMILY" in
			debian|rhel)
				curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || die "Не удалось скачать get.docker.com"
				sh /tmp/get-docker.sh
				;;
			arch)
				pkg_install docker
				;;
			alpine)
				die "Alpine: Docker ставится только через apk/docker или dockerd. Установите вручную и повторите с --skip-docker"
				;;
			*)
				die "ОС $OS_ID не поддерживается автоматической установкой Docker. Установите Docker вручную и повторите с --skip-docker"
				;;
		esac
	fi

	# Плагин Compose, если его нет
	if ! docker compose version >/dev/null 2>&1; then
		log "Устанавливаю Docker Compose v2 (плагин)"
		local arch; arch="$(uname -m)"
		case "$arch" in
			x86_64)  arch="x86_64" ;;
			aarch64) arch="aarch64" ;;
			armv7l)  arch="armv7" ;;
			*) die "Неподдерживаемая архитектура: $arch" ;;
		esac
		local ver="v2.29.7"
		mkdir -p /usr/local/lib/docker/cli-plugins
		curl -fsSL "https://github.com/docker/compose/releases/download/${ver}/docker-compose-linux-${arch}" \
			-o /usr/local/lib/docker/cli-plugins/docker-compose
		chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
	fi

	# Запуск и автозапуск демона
	if have systemctl; then
		systemctl enable --now docker >/dev/null 2>&1 || true
	else
		if ! pgrep -x dockerd >/dev/null 2>&1; then
			nohup dockerd >/var/log/dockerd.log 2>&1 &
			sleep 5
		fi
	fi
	retry docker info >/dev/null 2>&1 20 || die "Docker-демон не отвечает. Проверьте: systemctl status docker"
	ok "Docker готов: $(docker --version)"
}

# ---------------------------------------------------------------------------
# Файрвол
# ---------------------------------------------------------------------------
configure_firewall() {
	step "Настройка файрвола"
	local ports=(22/tcp 80/tcp 443/tcp 3478/tcp 3478/udp 5349/tcp 5349/udp)

	if have ufw; then
		for p in "${ports[@]}"; do ufw allow "$p" >/dev/null 2>&1 || true; done
		ufw --force enable >/dev/null 2>&1 || true
		ok "ufw: открыты 22, 80, 443, 3478, 5349"
	elif have firewall-cmd; then
		for p in "${ports[@]}"; do firewall-cmd --permanent --add-port="$p" >/dev/null 2>&1 || true; done
		firewall-cmd --reload >/dev/null 2>&1 || true
		ok "firewalld: открыты 22, 80, 443, 3478, 5349"
	else
		warn "Не найден ufw/firewalld — порты откройте вручную: 80, 443, 3478/tcp+udp, 5349/tcp+udp"
	fi
}

# ---------------------------------------------------------------------------
# systemd-таймеры (резервные копии, обновление сертификатов)
# ---------------------------------------------------------------------------
have_systemd() {
	[[ -d /run/systemd/system ]] && have systemctl
}

install_systemd_timer() {
	local name=$1 script=$2 schedule=$3 desc=$4
	have_systemd || { warn "systemd не найден — таймер $name не установлен"; return 0; }
	cat >"/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=${desc}
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${script}
EOF
	cat >"/etc/systemd/system/${name}.timer" <<EOF
[Unit]
Description=${desc} (таймер)

[Timer]
OnCalendar=${schedule}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
	systemctl daemon-reload >/dev/null 2>&1
	systemctl enable --now "${name}.timer" >/dev/null 2>&1 || true
	ok "Таймер ${name} включён (${schedule})"
}
