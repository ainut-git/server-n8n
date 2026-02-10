#!/usr/bin/env bash
set -euo pipefail

# Check root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[0;31m[ERROR]\033[0m Этот скрипт требует root-привилегий. Запустите: sudo $0"
    exit 1
fi

# =============================================================================
# Server n8n — install.sh
# Interactive installer for production infrastructure
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# =============================================================================
# Check for existing installation
# =============================================================================
if [ -f "$ENV_FILE" ]; then
    error ".env файл уже существует. Установка уже выполнена."
    echo "Если хотите переустановить, удалите .env файл и запустите скрипт заново."
    exit 1
fi

echo ""
echo "==========================================="
echo "   Server n8n — Установка инфраструктуры"
echo "==========================================="
echo ""

# =============================================================================
# Install Docker & Docker Compose if missing
# =============================================================================
install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        success "Docker и Docker Compose уже установлены"
        return
    fi

    info "Устанавливаю Docker..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    success "Docker установлен"
}

# =============================================================================
# Configure Docker log rotation (runs even if Docker was pre-installed)
# =============================================================================
configure_docker_logging() {
    local DESIRED_CONFIG='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}'
    mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
        CURRENT=$(cat /etc/docker/daemon.json)
        if [ "$CURRENT" = "$DESIRED_CONFIG" ]; then
            success "Docker log rotation уже настроен"
            return
        fi
    fi
    echo "$DESIRED_CONFIG" > /etc/docker/daemon.json
    systemctl restart docker 2>/dev/null || true
    success "Docker log rotation настроен"
}

# =============================================================================
# Configure UFW firewall
# =============================================================================
configure_firewall() {
    if command -v ufw &>/dev/null; then
        info "Настраиваю firewall (ufw)..."
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw allow 22/tcp >/dev/null 2>&1
        ufw allow 80/tcp >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        ufw allow 443/udp >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1
        success "Firewall настроен (SSH, HTTP, HTTPS)"
    else
        warn "ufw не найден, пропускаю настройку firewall"
    fi
}

# =============================================================================
# Generate random strings and JWT tokens
# =============================================================================
gen_password() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c "$1"
}

gen_jwt_secret() {
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64
}

gen_jwt_token() {
    local secret="$1"
    local role="$2"
    local iss="supabase"
    local iat
    iat=$(date +%s)
    local exp=$((iat + 157680000))  # ~5 years

    local header
    header=$(echo -n '{"alg":"HS256","typ":"JWT"}' | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    local payload
    payload=$(echo -n "{\"role\":\"${role}\",\"iss\":\"${iss}\",\"iat\":${iat},\"exp\":${exp}}" | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    local signature
    signature=$(echo -n "${header}.${payload}" | openssl dgst -sha256 -hmac "${secret}" -binary | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')

    echo "${header}.${payload}.${signature}"
}

# =============================================================================
# Interactive prompts
# =============================================================================
echo ""
read -rp "Введите основной домен (например, example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    error "Домен не может быть пустым"
    exit 1
fi

echo ""
info "Будут созданы следующие поддомены:"
echo "  n8n.$DOMAIN       — n8n (автоматизации)"
echo "  supabase.$DOMAIN  — Supabase API"
echo "  studio.$DOMAIN    — Supabase Studio"
echo "  logs.$DOMAIN      — Grafana (логи)"
echo "  status.$DOMAIN    — Uptime Kuma (мониторинг)"
echo ""
read -rp "Подтвердите поддомены (Enter — да, или введите 'n' для отмены): " CONFIRM
if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
    error "Установка отменена"
    exit 1
fi

echo ""
read -rp "Часовой пояс [Europe/Moscow]: " TZ_INPUT
TZ="${TZ_INPUT:-Europe/Moscow}"

# =============================================================================
# Install Docker
# =============================================================================
install_docker

# =============================================================================
# Configure Docker log rotation
# =============================================================================
configure_docker_logging

# =============================================================================
# Configure Firewall
# =============================================================================
configure_firewall

# =============================================================================
# Generate secrets
# =============================================================================
info "Генерирую пароли и ключи..."

POSTGRES_PASSWORD=$(gen_password 32)
JWT_SECRET=$(gen_jwt_secret)
ANON_KEY=$(gen_jwt_token "$JWT_SECRET" "anon")
SERVICE_ROLE_KEY=$(gen_jwt_token "$JWT_SECRET" "service_role")
N8N_ENCRYPTION_KEY=$(gen_password 32)
N8N_DB_PASSWORD=$(gen_password 32)
REALTIME_ENC_KEY=$(gen_password 32)
STUDIO_BASIC_AUTH_PASSWORD=$(gen_password 24)
GRAFANA_ADMIN_PASSWORD=$(gen_password 24)

# Generate Caddy bcrypt hash for Studio Basic Auth
STUDIO_BASIC_AUTH_PASSWORD_HASH=$(docker run --rm caddy:2.9 caddy hash-password --plaintext "$STUDIO_BASIC_AUTH_PASSWORD" 2>/dev/null || echo "")
if [ -z "$STUDIO_BASIC_AUTH_PASSWORD_HASH" ]; then
    docker pull caddy:2.9 >/dev/null 2>&1
    STUDIO_BASIC_AUTH_PASSWORD_HASH=$(docker run --rm caddy:2.9 caddy hash-password --plaintext "$STUDIO_BASIC_AUTH_PASSWORD")
fi

# Escape $ → $$ for Docker Compose compatibility
STUDIO_BASIC_AUTH_PASSWORD_HASH=$(echo "$STUDIO_BASIC_AUTH_PASSWORD_HASH" | sed 's/\$/\$\$/g')

success "Пароли и ключи сгенерированы"

# =============================================================================
# Write .env
# =============================================================================
info "Создаю .env файл..."

cat > "$ENV_FILE" <<ENVEOF
# =============================================================================
# Server n8n — Environment Configuration
# Generated: $(date -Iseconds)
# =============================================================================

# Домен
DOMAIN=${DOMAIN}

# Часовой пояс
TZ=${TZ}

# ACME Email (Let's Encrypt)
ACME_EMAIL=admin@${DOMAIN}

# Поддомены
N8N_SUBDOMAIN=n8n
SUPABASE_SUBDOMAIN=supabase
STUDIO_SUBDOMAIN=studio
LOGS_SUBDOMAIN=logs
STATUS_SUBDOMAIN=status

# Basic Auth (только Studio)
STUDIO_BASIC_AUTH_USER=admin
STUDIO_BASIC_AUTH_PASSWORD=${STUDIO_BASIC_AUTH_PASSWORD}
STUDIO_BASIC_AUTH_PASSWORD_HASH=${STUDIO_BASIC_AUTH_PASSWORD_HASH}

# Grafana (нативная авторизация)
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}

# Supabase — Database
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_HOST=supabase-db
POSTGRES_PORT=5432
POSTGRES_DB=postgres

# Supabase — Auth / JWT
JWT_SECRET=${JWT_SECRET}
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}

GOTRUE_SITE_URL=https://supabase.${DOMAIN}
GOTRUE_URI_ALLOW_LIST=
GOTRUE_DISABLE_SIGNUP=false
GOTRUE_EXTERNAL_EMAIL_ENABLED=true
GOTRUE_MAILER_AUTOCONFIRM=true
GOTRUE_SMS_AUTOCONFIRM=true

# Supabase — Storage
STORAGE_BACKEND=file
GLOBAL_S3_BUCKET=
GLOBAL_S3_ENDPOINT=
GLOBAL_S3_FORCE_PATH_STYLE=true
GLOBAL_S3_PROTOCOL=https
IMGPROXY_ENABLE_WEBP_DETECTION=true

# Supabase — API
PGRST_DB_SCHEMAS=public,storage,graphql_public
ADDITIONAL_REDIRECT_URLS=

# n8n
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_DB_PASSWORD=${N8N_DB_PASSWORD}

# Supabase Realtime encryption key
REALTIME_ENC_KEY=${REALTIME_ENC_KEY}

# Docker Compose project name
COMPOSE_PROJECT_NAME=server-n8n

# Backup settings
BACKUP_DIR=/opt/backups
BACKUP_MAX_COUNT=30
BACKUP_ENABLED=true
ENVEOF

chmod 600 "$ENV_FILE"
success ".env создан"

# =============================================================================
# Add .env to .gitignore
# =============================================================================
if [ -f "$SCRIPT_DIR/.gitignore" ]; then
    if ! grep -q "^\.env$" "$SCRIPT_DIR/.gitignore"; then
        echo ".env" >> "$SCRIPT_DIR/.gitignore"
    fi
fi

# =============================================================================
# Build and start services
# =============================================================================
info "Собираю образы..."
cd "$SCRIPT_DIR"
docker compose build --quiet

# =============================================================================
# Start Postgres first, set up roles and schemas
# =============================================================================
info "Запускаю Postgres..."
docker compose up -d supabase-db

info "Ожидаю запуск Postgres..."
for i in $(seq 1 30); do
    if docker exec supabase-db pg_isready -U postgres -d postgres &>/dev/null; then
        break
    fi
    sleep 2
done

info "Настраиваю роли Postgres..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" supabase-db \
    psql -U supabase_admin -d postgres -c \
    "ALTER ROLE supabase_auth_admin WITH PASSWORD '${POSTGRES_PASSWORD}';" 2>/dev/null && \
    success "  supabase_auth_admin — OK" || warn "  supabase_auth_admin — пропущено"

docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" supabase-db \
    psql -U supabase_admin -d postgres -c \
    "ALTER ROLE authenticator WITH PASSWORD '${POSTGRES_PASSWORD}';" 2>/dev/null && \
    success "  authenticator — OK" || warn "  authenticator — пропущено"

docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" supabase-db \
    psql -U supabase_admin -d postgres -c \
    "ALTER ROLE supabase_storage_admin WITH PASSWORD '${POSTGRES_PASSWORD}';" 2>/dev/null && \
    success "  supabase_storage_admin — OK" || warn "  supabase_storage_admin — пропущено"

docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" supabase-db \
    psql -U supabase_admin -d postgres -c \
    "CREATE SCHEMA IF NOT EXISTS _realtime; GRANT ALL ON SCHEMA _realtime TO supabase_admin;" 2>/dev/null && \
    success "  _realtime schema — OK" || warn "  _realtime schema — пропущено"

# Create isolated n8n database role
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" supabase-db \
    psql -U supabase_admin -d postgres -c "
    CREATE ROLE n8n_user LOGIN PASSWORD '${N8N_DB_PASSWORD}';
    GRANT CONNECT ON DATABASE postgres TO n8n_user;
    GRANT TEMP, CREATE ON DATABASE postgres TO n8n_user;
    CREATE SCHEMA IF NOT EXISTS n8n AUTHORIZATION n8n_user;
    GRANT ALL ON SCHEMA n8n TO n8n_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA n8n GRANT ALL ON TABLES TO n8n_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA n8n GRANT ALL ON SEQUENCES TO n8n_user;
    " 2>/dev/null && \
    success "  n8n_user — OK" || warn "  n8n_user — пропущено"

# Start all remaining services (DB roles are now ready)
info "Запускаю все сервисы..."
docker compose up -d
sleep 15

echo ""
echo "==========================================="
success "Установка завершена!"
echo "==========================================="
echo ""
echo "Ваши сервисы:"
echo "  n8n:             https://n8n.${DOMAIN}"
echo "  Supabase API:    https://supabase.${DOMAIN}"
echo "  Supabase Studio: https://studio.${DOMAIN}"
echo "  Grafana:         https://logs.${DOMAIN}"
echo "  Uptime Kuma:     https://status.${DOMAIN}"
echo ""
echo "Учётные данные:"
echo "  Studio Basic Auth:  admin / ${STUDIO_BASIC_AUTH_PASSWORD}"
echo "  Grafana:            admin / ${GRAFANA_ADMIN_PASSWORD}"
echo "  Supabase Anon Key:  ${ANON_KEY}"
echo ""
echo "Все пароли сохранены в .env"
echo ""
echo "Следующие шаги:"
echo "  1. Откройте n8n и создайте аккаунт"
echo "  2. Откройте Uptime Kuma и создайте аккаунт"
echo "  3. Настройте мониторы в Uptime Kuma (см. README)"
echo "  4. Запустите ./test.sh для проверки сервисов"
echo ""
