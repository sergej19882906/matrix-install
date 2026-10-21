# Установка Matrix-сервера с полным функционалом

Автоматический установщик Matrix-стека на Docker Compose. Один скрипт поднимает
homeserver, веб-клиент, SSO, мосты мессенджеров, TURN, админку, мониторинг и
резервное копирование в S3.

```
Synapse + PostgreSQL          MAS + Keycloak (OIDC/SSO)
Element Web                   Мосты: WhatsApp · Telegram · Signal · Discord · IRC
nginx + Let's Encrypt         coturn (TURN/STUN для звонков)
synapse-admin                 Prometheus + Grafana
                              Бэкапы: БД + медиа + конфиги → S3 (rclone)
```

---

## 1. Требования

| Параметр | Значение |
|---|---|
| ОС | Debian 12, Ubuntu 22.04+, RHEL/Rocky/Alma 9+, Fedora, Arch, Alpine (ручная установка Docker) |
| Архитектура | x86_64 / arm64 |
| Ресурсы | минимум 2 vCPU, 4 ГБ RAM, 20 ГБ SSD (для 100+ пользователей — 4 vCPU / 8 ГБ) |
| Порты | 80/tcp, 443/tcp, 3478/tcp+udp, 5349/tcp+udp (SSH — 22) |
| DNS | A-записи на все используемые домены → IP сервера |

Перед установкой убедитесь, что домены резолвятся в IP сервера и порт 80
доступен извне (нужен для валидации Let's Encrypt):

```bash
dig +short matrix.example.com     # должен совпадать с IP сервера
curl -I http://matrix.example.com  # должен отвечать (до установки — 503)
```

---

## 2. Быстрый старт

```bash
# на сервере
git clone <репозиторий> matrix-install   # или скопируйте архив
cd matrix-install

cp config/matrix.env.example config/matrix.env
nano config/matrix.env                     # домены, email, токены мостов

sudo bash install.sh
```

Установщик задаст несколько вопросов, сгенерирует секреты, получит сертификаты,
поднимет сервисы и создаст администратора. Повторный запуск безопасен —
существующие секреты сохраняются.

### Варианты запуска

```bash
sudo bash install.sh                     # интерактивно (по умолчанию)
sudo bash install.sh --non-interactive   # без вопросов, по config/matrix.env
sudo bash install.sh --reconfigure       # применить изменённый config/matrix.env
sudo bash install.sh --skip-certs        # без Let's Encrypt (свои сертификаты)
sudo bash install.sh --stack-dir /srv/matrix
sudo bash uninstall.sh --purge           # полное удаление
```

---

## 3. Что поднимается

| Сервис | Домен | Порт | Назначение |
|---|---|---|---|
| Synapse | `matrix.example.com` | 8008 (внутри) | homeserver, клиентский API + федерация |
| Element Web | `element.example.com` | 80 (внутри) | веб-клиент |
| Keycloak | `sso.example.com` | 8080 (внутри) | OIDC/SSO, свой Identity Server |
| MAS (legacy, опционально) | `mas.example.com` | 8080 (внутри) | аутентификация (только со старым Synapse) |
| synapse-admin | `admin.example.com` | 80 (внутри) | админ-панель |
| Grafana | `grafana.example.com` | 3000 (внутри) | дашборды |
| Prometheus | — | 9090 (localhost) | сбор метрик |
| coturn | `turn.example.com` | 3478/5349 | TURN/STUN для WebRTC |
| Мосты | — | 29325 | WhatsApp, Telegram, Signal, Discord, IRC |

Каталог стека по умолчанию — `/opt/matrix`:

```
/opt/matrix/
├── .env                    # сгенерированные секреты (chmod 600)
├── docker-compose*.yml
├── synapse/                # homeserver.yaml, log.config, bridges/, media_store/
├── mas/config.yaml         # legacy-режим MAS
├── keycloak/import/matrix-realm.json
├── nginx/conf.d/           # конфигурация сайтов
├── coturn/turnserver.conf
├── element/config.json
├── monitoring/             # prometheus/, grafana/
├── certbot/                # сертификаты Let's Encrypt
├── backup/                 # локальные бэкапы
└── bin/                    # backup.sh, restore.sh, upgrade.sh, renew-certs.sh
```

---

## 4. Аутентификация и SSO

### 4.1. Основной режим (по умолчанию): пароли + OIDC через Keycloak

Актуальные версии Synapse поддерживают нативный OIDC — внешний IdP (Keycloak)
работает как поставщик входа, а список доступных методов входа homeserver
отдаёт сам:

```
Element → Synapse /_matrix/client/v3/login → m.login.sso (oidc-keycloak) → Keycloak
         → Synapse /_synapse/client/oidc/callback → сессия
```

Настройки (`config/matrix.env`):

```
ENABLE_OIDC=1       # нативный OIDC Synapse
ENABLE_KEYCLOAK=1   # Keycloak как IdP
```

В Keycloak создаётся realm `matrix` с конфиденциальным клиентом `matrix`
(redirect URI: `https://<MATRIX_DOMAIN>/_synapse/client/oidc/callback`).
Realm импортируется автоматически при первом старте Keycloak.

* Localpart в Matrix = `preferred_username` из Keycloak.
* Новый пользователь создаётся при первом входе через SSO
  (`enable_registration: true` у OIDC-провайдера).
* Локальные пароли Synapse продолжают работать — администратора создаёт
  установщик (`register_new_matrix_user`).
* Realm: `https://<KEYCLOAK_DOMAIN>/realms/matrix`, логин/пароль — в
  `/opt/matrix/.env`.

### 4.2. Legacy-режим: MAS (Matrix Authentication Service)

> **Важно.** Проект MAS официально задеприкейтирован: последний релиз —
> `0.11.0` (сентябрь 2024), репозиторий не обновляется. В Synapse 2026 года
> удалена поддержка `experimental_features.msc3861`, на котором строился MAS,
> а новый интерфейс `matrix_authentication_service` не имеет публичной
> реализации MAS. Поэтому MAS работает **только со старым Synapse**.

```
ENABLE_MAS=1        # legacy-режим
SYNAPSE_VERSION=v1.98.0   # закрепляется автоматически
```

Что делает установщик в этом режиме:

* поднимает `ghcr.io/matrix-org/matrix-authentication-service` (сервер + worker);
* конфигурация MAS — YAML (`mas/config.yaml`), проверяется `mas-cli config check`;
* OIDC-провайдер в MAS указывает на Keycloak (`upstream_oauth2`);
* nginx проксирует `/_matrix/client/*/(login|logout|refresh)` в MAS
  (совместимый слой), остальное — в Synapse;
* администратор создаётся командой `mas-cli manage register-user`.

Если MAS не нужен — оставьте `ENABLE_MAS=0` (режим по умолчанию).

### 4.3. Делегирование на matrix.org

Чтобы клиенты находили ваш сервер по apex-домену, зарегистрируйте делегирование:

```bash
export MATRIX_ORG_TOKEN=<access_token_с_matrix.org>
sudo bash install.sh --delegate-only
```

Либо вручную: https://matrix.org/docs/guides/delegation — указать
`matrix.example.com` и `matrix.example.com:443`.

---

## 5. Мосты

После установки каждый мост требует авторизации в своей сети:

```bash
cd /opt/matrix

docker compose logs -f mautrix-whatsapp    # QR-код WhatsApp в логах
docker compose logs -f mautrix-telegram
docker compose logs -f mautrix-signal
docker compose logs -f mautrix-discord
docker compose logs -f matrix-appservice-irc
```

| Мост | Что нужно |
|---|---|
| Telegram | `api_id`/`api_hash` с [my.telegram.org](https://my.telegram.org) → `config/matrix.env` |
| Discord | токен приложения + бот в сервере → `config/matrix.env` |
| WhatsApp | QR-код в логах при первом запуске |
| Signal | QR-код / номер телефона в логах |
| IRC | `IRC_SERVER`, `IRC_NICK`, `IRC_CHANNEL` → `config/matrix.env` |

Мосты работают в режиме double-puppeting: сообщения пишутся от вашего Matrix-аккаунта.
Администратору (`@admin:server`) даны права `relay` на все мосты.

Регистрации приложений лежат в `/opt/matrix/synapse/bridges/*.yaml` и подхватываются
Synapse при старте.

---

## 6. Мониторинг

* Prometheus — `/_synapse/metrics`, метрики MAS, Keycloak, PostgreSQL, node-exporter, cAdvisor.
* Grafana — дашборд «Matrix — обзор» (provisioned автоматически), папка `Matrix`.
* Доступ: `https://grafana.example.com/` — `admin` / пароль из `/opt/matrix/.env`.

```bash
docker compose -f /opt/matrix/docker-compose.yml -f /opt/matrix/docker-compose.monitoring.yml logs -f prometheus
```

---

## 7. Резервное копирование

```bash
/opt/matrix/bin/backup.sh              # вручную
/opt/matrix/bin/backup.sh --list       # список локальных копий (restore.sh --list)
/opt/matrix/bin/restore.sh --file /opt/matrix/backup/matrix-backup-20260101-033000.tar.gz
```

Состав: `pg_dump` для `synapse`/`mas`/`keycloak`, медиа-хранилище, все конфиги.
Опционально — шифрование AES-256 (`BACKUP_PASSPHRASE`) и выгрузка в S3 через rclone
(`S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` — подойдёт AWS, MinIO,
Selectel, Yandex Cloud и любой S3-совместимый).

Автозапуск: systemd-таймер `matrix-backup.timer` (ежедневно 03:30).
Локальные копии старше `BACKUP_RETENTION_DAYS` удаляются.

Жизненный цикл в S3 (рекомендуется настроить на стороне бакета):
S3 Lifecycle → удалять объекты старше 30/90 дней, неверсионируемые — через 7 дней.

---

## 8. Обновление

```bash
cd /opt/matrix && ./bin/upgrade.sh --backup
```

Образы обновляются, сервисы перезапускаются, миграции БД применяютcя автоматически.
Перед обновлением зафиксируйте версии в `config/matrix.env`
(`SYNAPSE_VERSION=1.x.y` и т.д.), чтобы не получать непроверенные релизы.

---

## 9. Обслуживание

```bash
cd /opt/matrix

docker compose ps                              # состояние
docker compose logs -f synapse                 # логи homeserver
docker compose restart synapse                 # перезапуск
docker compose exec postgres psql -U matrix -d synapse   # SQL
```

Полезные проверки:

```bash
curl -s https://matrix.example.com/_matrix/client/versions | jq
curl -s https://matrix.example.com/_matrix/client/v3/login | jq   # список flow'ов (должен быть m.login.oidc)
curl -s https://matrix.example.com/_synapse/metrics | head
curl -s https://admin.example.com/
```

Полезные файлы:

| Путь | Назначение |
|---|---|
| `/opt/matrix/.env` | все секреты и пароли (chmod 600) |
| `/opt/matrix/synapse/homeserver.yaml` | конфигурация Synapse |
| `/opt/matrix/mas/config.yaml` | конфигурация MAS (legacy-режим) |
| `/opt/matrix/keycloak/import/matrix-realm.json` | realm Keycloak |
| `/opt/matrix/nginx/conf.d/` | сайты nginx |
| `/opt/matrix/certbot/conf/` | сертификаты Let's Encrypt |
| `/var/log/matrix-install.log` | лог установки |

---

## 10. Диагностика типовых проблем

**Synapse не стартует.** Чаще всего — права на каталоги или миграция БД:

```bash
docker compose logs synapse | tail -50
ls -ln /opt/matrix/synapse          # должно быть 8008:8008
docker compose exec postgres psql -U matrix -d synapse -c '\l'
```

Полезно: health-check Synapse — `GET /health` (не `/_synapse/health`),
метрики — `GET /_synapse/metrics` (в конфиге должен быть ресурс `metrics`
в слушателе — он уже прописан).

**nginx не стартует с `host not found in upstream`.** nginx резолвит DNS-имена
апстримов на старте. Запускайте сервисы в порядке: сначала все, затем nginx
(установщик так и делает). Если контейнер был остановлен — сначала поднимите
его, потом `docker compose up -d --force-recreate nginx`.

**MAS не принимает конфиг.** Конфигурация проверяется при установке:
`docker run --rm -v /opt/matrix/mas/config.yaml:/config.yaml:ro \
ghcr.io/matrix-org/matrix-authentication-service config check --config=/config.yaml`.

**Не работает SSO.** Проверьте, что realm импортирован и issuer совпадает:

```bash
curl -s https://sso.example.com/realms/matrix/.well-known/openid-configuration | jq .issuer
# должно быть: https://sso.example.com/realms/matrix
curl -s https://matrix.example.com/_matrix/client/v3/login | jq
# в списке flows должен быть m.login.sso с idp_id "oidc-keycloak"
```

Если realm уже существовал и не обновился — пересоздайте:

```bash
cd /opt/matrix && docker compose down keycloak && \
rm -rf keycloak/data/* && docker compose up -d --force-recreate keycloak
```

**Не работают звонки.** Проверьте TURN:

```bash
docker compose logs coturn | tail -20
# порт 3478/udp и 5349/tcp должны быть открыты в firewall
curl -s https://matrix.example.com/_synapse/client/v3/turnServer
```

**Ошибка ACME при установке.** Проверьте DNS и доступность порта 80 извне.
Альтернатива — выпустить сертификат вручную и положить в
`/opt/matrix/certbot/conf/live/<имя>/`, затем `bash install.sh --skip-certs`.

**Занята подсеть Docker.** Установщик выбирает свободную подсеть 172.28–172.31,
но при конфликте задайте свою в `/opt/matrix/.env`:
`DOCKER_SUBNET=172.29.0.0/16`.

**Проблема с правами на файлы, созданные контейнерами** (после ручного
удаления каталогов): `sudo chown -R 8008:8008 /opt/matrix/synapse`.

---

## 11. Безопасность

* Секреты генерируются автоматически (`openssl rand`), хранятся в `/opt/matrix/.env` (600).
* TLS для всех доменов, HSTS и stapling включены.
* Локальные пароли Synapse отключены — аутентификация только через MAS/Keycloak.
* Публичная регистрация по умолчанию выключена.
* Файрвол настраивается автоматически (ufw/firewalld).
* Панель админа и Grafana закрыты TLS-сертификатом; при необходимости добавьте
  basic-auth в `/opt/matrix/nginx/conf.d/50-admin.conf`.
* Рекомендуется закрыть SSH по ключу и отключить парольный вход.

## 12. Разработка и проверка

В репозитории есть автономный тест рендеринга — он генерирует стек во
временном каталоге и проверяет результат (без Docker и без сети):

```bash
bash tests/render-test.sh default   # обычный режим (OIDC)
bash tests/render-test.sh mas       # legacy-режим MAS
```

Проверки стиля:

```bash
shellcheck -S warning -e SC1091 install.sh uninstall.sh lib/*.sh ops/*.sh tests/*.sh
for f in install.sh uninstall.sh lib/*.sh ops/*.sh tests/*.sh; do bash -n "$f"; done
```

CI (.github/workflows/ci.yml) запускает shellcheck, проверку синтаксиса,
валидацию шаблонов YAML/JSON и оба варианта рендеринга.

---

## 13. Ограничения и особенности

* Установщик рассчитан на «чистый» сервер: Docker ставится из официального
  репозитория, открываются стандартные порты.
* `latest` в версиях образов по умолчанию — для продакшена зафиксируйте версии.
* **MAS задеприкейтирован** (см. раздел 4.2). Основной режим — нативный OIDC.
* Конфигурация мостов генерируется по актуальным схемам mautrix; при смене
  формата проверьте лог конкретного моста и поправьте
  `/opt/matrix/bridges/<мост>/config.yaml`.
* Postgres инициализируется с локалью `C` — этого требует Synapse
  (`allow_unsafe_locale` включать не нужно).
* Точки входа Synapse, обслуживаемые MAS в legacy-режиме
  (`/_matrix/client/*/login|logout|refresh`), проксируются через nginx в MAS.
* Проверено на актуальных образах: Synapse (`latest`), Keycloak 26,
  MAS 0.11.0, nginx, PostgreSQL 16, Element Web, coturn, Prometheus, Grafana.
