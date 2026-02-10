#!/usr/bin/env bash
set -euo pipefail

# Check root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[0;31m[ERROR]\033[0m Этот скрипт требует root-привилегий. Запустите: sudo $0"
    exit 1
fi

# =============================================================================
# Server n8n — test.sh
# Проверка корректности работы всех сервисов
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

check() {
    local name="$1"
    local result="$2"
    local hint="${3:-}"

    if [ "$result" -eq 0 ]; then
        echo -e "  ✅ ${name}"
        PASS=$((PASS + 1))
    else
        echo -e "  ❌ ${name}"
        if [ -n "$hint" ]; then
            echo -e "     ${YELLOW}→ ${hint}${NC}"
        fi
        FAIL=$((FAIL + 1))
    fi
}

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}[ERROR]${NC} .env файл не найден. Сначала запустите install.sh"
    exit 1
fi

# Read specific variables (avoid source — $$ in hashed passwords breaks bash)
get_env() { grep "^${1}=" "$ENV_FILE" | cut -d= -f2-; }

DOMAIN="$(get_env DOMAIN)"
N8N_SUBDOMAIN="$(get_env N8N_SUBDOMAIN)"
N8N_SUBDOMAIN="${N8N_SUBDOMAIN:-n8n}"
SUPABASE_SUBDOMAIN="$(get_env SUPABASE_SUBDOMAIN)"
SUPABASE_SUBDOMAIN="${SUPABASE_SUBDOMAIN:-supabase}"
STUDIO_SUBDOMAIN="$(get_env STUDIO_SUBDOMAIN)"
STUDIO_SUBDOMAIN="${STUDIO_SUBDOMAIN:-studio}"
LOGS_SUBDOMAIN="$(get_env LOGS_SUBDOMAIN)"
LOGS_SUBDOMAIN="${LOGS_SUBDOMAIN:-logs}"
STATUS_SUBDOMAIN="$(get_env STATUS_SUBDOMAIN)"
STATUS_SUBDOMAIN="${STATUS_SUBDOMAIN:-status}"
STUDIO_BASIC_AUTH_USER="$(get_env STUDIO_BASIC_AUTH_USER)"
STUDIO_BASIC_AUTH_PASSWORD="$(get_env STUDIO_BASIC_AUTH_PASSWORD)"

echo ""
echo "==========================================="
echo "   Server n8n — Тестирование сервисов"
echo "==========================================="
echo ""

# =============================================================================
# Docker containers
# =============================================================================
echo "Docker контейнеры:"

CONTAINERS="supabase-db supabase-auth supabase-rest supabase-realtime supabase-storage supabase-imgproxy supabase-meta kong supabase-studio n8n instrument loki promtail grafana uptime-kuma caddy"
for c in $CONTAINERS; do
    if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
        check "$c" 0
    else
        check "$c" 1 "docker compose logs $c"
    fi
done

echo ""

# =============================================================================
# HTTP endpoints
# =============================================================================
echo "HTTP-эндпоинты:"

# n8n
HTTP_CODE=$(curl -sko /dev/null -w "%{http_code}" "https://${N8N_SUBDOMAIN}.${DOMAIN}/healthz" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    check "n8n (https://${N8N_SUBDOMAIN}.${DOMAIN}/healthz)" 0
else
    check "n8n (https://${N8N_SUBDOMAIN}.${DOMAIN}/healthz) — HTTP $HTTP_CODE" 1 "Проверьте DNS и сертификаты"
fi

# Supabase API (Kong)
HTTP_CODE=$(curl -sko /dev/null -w "%{http_code}" "https://${SUPABASE_SUBDOMAIN}.${DOMAIN}/health" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    check "Supabase API (https://${SUPABASE_SUBDOMAIN}.${DOMAIN}/health)" 0
else
    check "Supabase API — HTTP $HTTP_CODE" 1 "docker compose logs kong"
fi

# Supabase Studio
HTTP_CODE=$(curl -sko /dev/null -w "%{http_code}" -u "${STUDIO_BASIC_AUTH_USER}:${STUDIO_BASIC_AUTH_PASSWORD}" "https://${STUDIO_SUBDOMAIN}.${DOMAIN}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "307" ]; then
    check "Supabase Studio (https://${STUDIO_SUBDOMAIN}.${DOMAIN})" 0
else
    check "Supabase Studio — HTTP $HTTP_CODE" 1 "Проверьте Basic Auth и docker compose logs supabase-studio"
fi

# Grafana
HTTP_CODE=$(curl -sko /dev/null -w "%{http_code}" "https://${LOGS_SUBDOMAIN}.${DOMAIN}/api/health" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    check "Grafana (https://${LOGS_SUBDOMAIN}.${DOMAIN}/api/health)" 0
else
    check "Grafana — HTTP $HTTP_CODE" 1 "docker compose logs grafana"
fi

# Uptime Kuma
HTTP_CODE=$(curl -sko /dev/null -w "%{http_code}" "https://${STATUS_SUBDOMAIN}.${DOMAIN}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
    check "Uptime Kuma (https://${STATUS_SUBDOMAIN}.${DOMAIN})" 0
else
    check "Uptime Kuma — HTTP $HTTP_CODE" 1 "docker compose logs uptime-kuma"
fi

# Instrument service (internal only)
INSTRUMENT_HEALTH=$(docker exec instrument curl -sf http://localhost:8000/health 2>/dev/null || echo "")
if echo "$INSTRUMENT_HEALTH" | grep -q "ok"; then
    check "Instrument service (/health)" 0
else
    check "Instrument service" 1 "docker compose logs instrument"
fi

echo ""

# =============================================================================
# SSL certificates
# =============================================================================
echo "SSL-сертификаты:"

for sub in "$N8N_SUBDOMAIN" "$SUPABASE_SUBDOMAIN" "$STUDIO_SUBDOMAIN" "$LOGS_SUBDOMAIN" "$STATUS_SUBDOMAIN"; do
    FQDN="${sub}.${DOMAIN}"
    if echo | openssl s_client -connect "${FQDN}:443" -servername "${FQDN}" 2>/dev/null | openssl x509 -noout 2>/dev/null; then
        check "$FQDN" 0
    else
        check "$FQDN" 1 "Проверьте DNS-записи и подождите — Caddy получит сертификат автоматически"
    fi
done

echo ""

# =============================================================================
# Loki logs collection
# =============================================================================
echo "Сбор логов (Loki):"

LOKI_READY=$(docker exec loki wget -q -O- http://localhost:3100/ready 2>/dev/null || echo "")
if echo "$LOKI_READY" | grep -qi "ready"; then
    check "Loki ready" 0
else
    check "Loki ready" 1 "docker compose logs loki"
fi

# Promtail — no wget/curl available, check process
if docker ps --format '{{.Names}}' | grep -q "^promtail$"; then
    check "Promtail running" 0
else
    check "Promtail running" 1 "docker compose logs promtail"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "==========================================="
echo -e "  Результат: ${GREEN}✅ ${PASS} пройдено${NC}  ${RED}❌ ${FAIL} ошибок${NC}"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Рекомендации:"
    echo "  1. Проверьте DNS-записи для всех поддоменов"
    echo "  2. Посмотрите логи проблемных сервисов: docker compose logs <service>"
    echo "  3. Перезапустите сервисы: docker compose restart"
    echo "  4. Посмотрите все логи в Grafana: https://${LOGS_SUBDOMAIN}.${DOMAIN}"
    exit 1
fi
