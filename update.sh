#!/usr/bin/env bash
set -euo pipefail

# Check root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[0;31m[ERROR]\033[0m Этот скрипт требует root-привилегий. Запустите: sudo $0"
    exit 1
fi

# =============================================================================
# Server n8n — update.sh
# Обновление всех сервисов с бэкапом
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

if [ ! -f "$ENV_FILE" ]; then
    error ".env файл не найден. Сначала запустите install.sh"
    exit 1
fi

# Read specific variables (avoid source — $$ in hashed passwords breaks bash)
get_env() { grep "^${1}=" "$ENV_FILE" | cut -d= -f2-; }

BACKUP_DIR="$(get_env BACKUP_DIR)"
BACKUP_DIR="${BACKUP_DIR:-/opt/backups}"
BACKUP_MAX_COUNT="$(get_env BACKUP_MAX_COUNT)"
BACKUP_MAX_COUNT="${BACKUP_MAX_COUNT:-30}"
BACKUP_ENABLED="$(get_env BACKUP_ENABLED)"
BACKUP_ENABLED="${BACKUP_ENABLED:-true}"
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/backup_${TIMESTAMP}.tar.gz"

echo ""
echo "==========================================="
echo "   Server n8n — Обновление сервисов"
echo "==========================================="
echo ""

# =============================================================================
# Step 1: Stop all services
# =============================================================================
info "Останавливаю все сервисы..."
cd "$SCRIPT_DIR"
docker compose down
success "Сервисы остановлены"

# =============================================================================
# Step 2: Create backup
# =============================================================================
if [ "$BACKUP_ENABLED" = "true" ]; then
    info "Создаю бэкап..."
    mkdir -p "$BACKUP_DIR"

    # Get volume data paths
    COMPOSE_PROJECT=$(grep "^COMPOSE_PROJECT_NAME=" "$ENV_FILE" | cut -d= -f2)
    COMPOSE_PROJECT="${COMPOSE_PROJECT:-$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]')}"

    # Create temp directory for backup content
    BACKUP_TMP=$(mktemp -d)
    trap 'rm -rf "$BACKUP_TMP"' EXIT

    # Backup .env and configs
    cp "$ENV_FILE" "$BACKUP_TMP/.env"
    cp -r "$SCRIPT_DIR/docker" "$BACKUP_TMP/docker"
    cp "$SCRIPT_DIR/docker-compose.yml" "$BACKUP_TMP/docker-compose.yml"

    # Backup all Docker volumes
    info "Сохраняю Docker volumes..."
    for vol in $(docker volume ls -q | grep -E "^${COMPOSE_PROJECT}_" || true); do
        vol_name=$(echo "$vol" | sed "s/^${COMPOSE_PROJECT}_//")
        info "  Сохраняю volume: $vol_name"
        docker run --rm \
            -v "$vol":/data:ro \
            -v "$BACKUP_TMP":/backup \
            alpine tar czf "/backup/vol_${vol_name}.tar.gz" -C /data . 2>/dev/null || \
            warn "  Не удалось сохранить $vol_name"
    done

    # Pack everything
    tar czf "$BACKUP_FILE" -C "$BACKUP_TMP" .
    success "Бэкап создан: $BACKUP_FILE"

    # Rotate old backups
    BACKUP_COUNT=$(find "$BACKUP_DIR" -name "backup_*.tar.gz" -type f | wc -l)
    if [ "$BACKUP_COUNT" -gt "$BACKUP_MAX_COUNT" ]; then
        EXCESS=$((BACKUP_COUNT - BACKUP_MAX_COUNT))
        info "Удаляю $EXCESS старых бэкапов..."
        find "$BACKUP_DIR" -name "backup_*.tar.gz" -type f | sort | head -n "$EXCESS" | xargs rm -f
        success "Ротация бэкапов выполнена"
    fi
else
    warn "Бэкап отключён (BACKUP_ENABLED=false)"
fi

# =============================================================================
# Step 3: Pull new images
# =============================================================================
info "Скачиваю обновлённые образы..."
docker compose pull
success "Образы обновлены"

# =============================================================================
# Step 4: Rebuild custom images
# =============================================================================
info "Пересобираю кастомные образы..."
docker compose build --quiet
success "Кастомные образы пересобраны"

# =============================================================================
# Step 5: Start Postgres first
# =============================================================================
info "Запускаю Postgres..."
docker compose up -d supabase-db
info "Ожидаю 30 секунд..."
sleep 30

# Check Postgres health
if docker compose ps supabase-db | grep -q "healthy\|running"; then
    success "Postgres запущен"
else
    error "Postgres не запустился! Обновление остановлено."
    error "Запустите ./rollback.sh для отката"
    exit 1
fi

# =============================================================================
# Step 5b: Fix Postgres role passwords
# =============================================================================
info "Восстанавливаю пароли ролей Postgres..."
PGPASS="$(get_env POSTGRES_PASSWORD)"
docker exec -e PGPASSWORD="${PGPASS}" supabase-db \
    psql -U supabase_admin -d postgres -c \
    "ALTER ROLE supabase_auth_admin WITH PASSWORD '${PGPASS}';" 2>/dev/null && \
    success "  supabase_auth_admin — OK" || warn "  supabase_auth_admin — пропущено"
docker exec -e PGPASSWORD="${PGPASS}" supabase-db \
    psql -U supabase_admin -d postgres -c \
    "ALTER ROLE authenticator WITH PASSWORD '${PGPASS}';" 2>/dev/null && \
    success "  authenticator — OK" || warn "  authenticator — пропущено"
docker exec -e PGPASSWORD="${PGPASS}" supabase-db \
    psql -U supabase_admin -d postgres -c \
    "ALTER ROLE supabase_storage_admin WITH PASSWORD '${PGPASS}';" 2>/dev/null && \
    success "  supabase_storage_admin — OK" || warn "  supabase_storage_admin — пропущено"
docker exec -e PGPASSWORD="${PGPASS}" supabase-db \
    psql -U supabase_admin -d postgres -c \
    "CREATE SCHEMA IF NOT EXISTS _realtime; GRANT ALL ON SCHEMA _realtime TO supabase_admin;" 2>/dev/null && \
    success "  _realtime schema — OK" || warn "  _realtime schema — пропущено"

# =============================================================================
# Step 6: Start Auth
# =============================================================================
info "Запускаю Supabase Auth..."
docker compose up -d supabase-auth
info "Ожидаю 30 секунд..."
sleep 30

if docker compose ps supabase-auth | grep -q "running"; then
    success "Supabase Auth запущен"
else
    error "Supabase Auth не запустился! Обновление остановлено."
    error "Запустите ./rollback.sh для отката"
    exit 1
fi

# =============================================================================
# Step 7: Start remaining services
# =============================================================================
info "Запускаю остальные сервисы..."
docker compose up -d
success "Все сервисы запущены"

# =============================================================================
# Step 8: Health check
# =============================================================================
info "Проверяю состояние контейнеров..."
sleep 15

FAILED=0
for container in supabase-db supabase-auth supabase-rest supabase-realtime supabase-storage supabase-imgproxy supabase-meta kong supabase-studio n8n instrument loki promtail grafana uptime-kuma caddy; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        success "  $container — запущен"
    else
        error "  $container — НЕ запущен"
        FAILED=1
    fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "==========================================="
    success "Обновление завершено успешно!"
    echo "==========================================="
else
    echo "==========================================="
    error "Некоторые сервисы не запустились"
    echo "  Проверьте логи: docker compose logs <service>"
    echo "  Для отката: ./rollback.sh"
    echo "==========================================="
    exit 1
fi
