#!/usr/bin/env bash
set -euo pipefail

# Check root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[0;31m[ERROR]\033[0m Этот скрипт требует root-привилегий. Запустите: sudo $0"
    exit 1
fi

# =============================================================================
# Server n8n — rollback.sh
# Откат к последнему бэкапу
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

# Load BACKUP_DIR from .env if available
BACKUP_DIR="/opt/backups"
if [ -f "$ENV_FILE" ]; then
    BACKUP_DIR=$(grep "^BACKUP_DIR=" "$ENV_FILE" | cut -d= -f2 || echo "/opt/backups")
    BACKUP_DIR="${BACKUP_DIR:-/opt/backups}"
fi

echo ""
echo "==========================================="
echo "   Server n8n — Откат из бэкапа"
echo "==========================================="
echo ""

# =============================================================================
# Find latest backup
# =============================================================================
LATEST_BACKUP=$(find "$BACKUP_DIR" -name "backup_*.tar.gz" -type f 2>/dev/null | sort -r | head -n 1)

if [ -z "$LATEST_BACKUP" ]; then
    error "Бэкапы не найдены в $BACKUP_DIR"
    exit 1
fi

info "Найден бэкап: $LATEST_BACKUP"
echo ""
read -rp "Восстановить из этого бэкапа? (y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Откат отменён"
    exit 0
fi

# =============================================================================
# Stop services
# =============================================================================
info "Останавливаю сервисы..."
cd "$SCRIPT_DIR"
docker compose down
success "Сервисы остановлены"

# =============================================================================
# Extract backup
# =============================================================================
RESTORE_TMP=$(mktemp -d)
trap 'rm -rf "$RESTORE_TMP"' EXIT

info "Распаковываю бэкап..."
tar xzf "$LATEST_BACKUP" -C "$RESTORE_TMP"
success "Бэкап распакован"

# =============================================================================
# Restore .env and configs
# =============================================================================
if [ -f "$RESTORE_TMP/.env" ]; then
    cp "$RESTORE_TMP/.env" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    success ".env восстановлен"
fi

if [ -d "$RESTORE_TMP/docker" ]; then
    cp -r "$RESTORE_TMP/docker" "$SCRIPT_DIR/"
    success "Конфигурации восстановлены"
fi

if [ -f "$RESTORE_TMP/docker-compose.yml" ]; then
    cp "$RESTORE_TMP/docker-compose.yml" "$SCRIPT_DIR/"
    success "docker-compose.yml восстановлен"
fi

# =============================================================================
# Restore volumes
# =============================================================================
COMPOSE_PROJECT=$(grep "^COMPOSE_PROJECT_NAME=" "$ENV_FILE" | cut -d= -f2)
COMPOSE_PROJECT="${COMPOSE_PROJECT:-$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]')}"

# First ensure volumes exist by doing a dry-run create
docker compose up --no-start 2>/dev/null || true

info "Восстанавливаю Docker volumes..."
for vol_archive in "$RESTORE_TMP"/vol_*.tar.gz; do
    [ -f "$vol_archive" ] || continue
    vol_name=$(basename "$vol_archive" | sed 's/^vol_//' | sed 's/\.tar\.gz$//')
    full_vol="${COMPOSE_PROJECT}_${vol_name}"

    if docker volume ls -q | grep -q "^${full_vol}$"; then
        info "  Восстанавливаю volume: $vol_name"
        docker run --rm \
            -v "$full_vol":/data \
            -v "$vol_archive":/backup.tar.gz:ro \
            alpine sh -c "rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; tar xzf /backup.tar.gz -C /data"
        success "  $vol_name восстановлен"
    else
        warn "  Volume $full_vol не найден, пропускаю"
    fi
done

# =============================================================================
# Start services
# =============================================================================
info "Запускаю сервисы..."
docker compose up -d
sleep 20

# =============================================================================
# Health check
# =============================================================================
info "Проверяю состояние контейнеров..."
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
    success "Откат завершён успешно!"
    echo "==========================================="
else
    echo "==========================================="
    error "Некоторые сервисы не запустились после отката"
    echo "  Проверьте логи: docker compose logs <service>"
    echo "==========================================="
    exit 1
fi
