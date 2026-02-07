#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Server n8n — kuma_config.sh
# Настройка мониторов Uptime Kuma через API
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
    error ".env файл не найден"
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

DOMAIN="${DOMAIN}"
N8N_SUBDOMAIN="${N8N_SUBDOMAIN:-n8n}"
SUPABASE_SUBDOMAIN="${SUPABASE_SUBDOMAIN:-supabase}"
STUDIO_SUBDOMAIN="${STUDIO_SUBDOMAIN:-studio}"
LOGS_SUBDOMAIN="${LOGS_SUBDOMAIN:-logs}"
STATUS_SUBDOMAIN="${STATUS_SUBDOMAIN:-status}"

KUMA_URL="http://localhost:3001"

echo ""
echo "==========================================="
echo "   Uptime Kuma — Настройка мониторов"
echo "==========================================="
echo ""
echo "Убедитесь, что вы уже создали аккаунт в Uptime Kuma"
echo "по адресу https://${STATUS_SUBDOMAIN}.${DOMAIN}"
echo ""

# =============================================================================
# Credentials
# =============================================================================
read -rp "Логин администратора Uptime Kuma: " KUMA_USER
read -rsp "Пароль администратора Uptime Kuma: " KUMA_PASS
echo ""

# =============================================================================
# Optional Telegram
# =============================================================================
echo ""
read -rp "Настроить Telegram-уведомления? (y/N): " SETUP_TELEGRAM
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

if [ "$SETUP_TELEGRAM" = "y" ] || [ "$SETUP_TELEGRAM" = "Y" ]; then
    read -rp "Telegram Bot Token: " TELEGRAM_TOKEN
    read -rp "Telegram Chat ID: " TELEGRAM_CHAT_ID
fi

# =============================================================================
# Login to Uptime Kuma API
# =============================================================================
info "Подключаюсь к Uptime Kuma..."

# Uptime Kuma uses socket.io, so we use the REST-like API through internal access
# First check if it's accessible
HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" "${KUMA_URL}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "000" ]; then
    # Try via docker network
    KUMA_URL="http://$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' uptime-kuma 2>/dev/null):3001"
    HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" "${KUMA_URL}/" 2>/dev/null || echo "000")
fi

if [ "$HTTP_CODE" = "000" ]; then
    error "Не удалось подключиться к Uptime Kuma"
    echo ""
    echo "Настройте мониторы вручную через веб-интерфейс:"
    echo "  https://${STATUS_SUBDOMAIN}.${DOMAIN}"
    echo ""
    echo "Мониторы для создания:"
    echo "  1. n8n          → https://${N8N_SUBDOMAIN}.${DOMAIN}/healthz"
    echo "  2. Supabase API → https://${SUPABASE_SUBDOMAIN}.${DOMAIN}/health"
    echo "  3. Studio       → https://${STUDIO_SUBDOMAIN}.${DOMAIN}"
    echo "  4. Grafana      → https://${LOGS_SUBDOMAIN}.${DOMAIN}/api/health"
    echo ""
    echo "Интервал: 300 секунд, Retries: 3"
    exit 1
fi

# Uptime Kuma doesn't have a simple REST API — it uses Socket.IO
# We'll use a Python helper for socket.io communication

info "Настраиваю мониторы через Socket.IO..."

# Check if python3 is available in container
if ! docker exec uptime-kuma which python3 &>/dev/null && ! command -v python3 &>/dev/null; then
    warn "Python3 не доступен для автоматической настройки"
    echo ""
    echo "Настройте мониторы вручную через веб-интерфейс:"
    echo "  https://${STATUS_SUBDOMAIN}.${DOMAIN}"
    echo ""
    echo "Мониторы для создания:"
    echo "  1. n8n          → https://${N8N_SUBDOMAIN}.${DOMAIN}/healthz       (HTTP, 300s, retries: 3)"
    echo "  2. Supabase API → https://${SUPABASE_SUBDOMAIN}.${DOMAIN}/health   (HTTP, 300s, retries: 3)"
    echo "  3. Studio       → https://${STUDIO_SUBDOMAIN}.${DOMAIN}            (HTTP, 300s, retries: 3)"
    echo "  4. Grafana      → https://${LOGS_SUBDOMAIN}.${DOMAIN}/api/health   (HTTP, 300s, retries: 3)"
    if [ -n "$TELEGRAM_TOKEN" ]; then
        echo ""
        echo "Telegram-уведомления:"
        echo "  Bot Token: $TELEGRAM_TOKEN"
        echo "  Chat ID:   $TELEGRAM_CHAT_ID"
    fi
    exit 0
fi

# Create Python script for Uptime Kuma API configuration
KUMA_SCRIPT=$(mktemp /tmp/kuma_setup_XXXX.py)
trap 'rm -f "$KUMA_SCRIPT"' EXIT

cat > "$KUMA_SCRIPT" << 'PYEOF'
import json
import sys
import urllib.request
import urllib.error
import http.cookiejar

kuma_url = sys.argv[1]
username = sys.argv[2]
password = sys.argv[3]
domain = sys.argv[4]
n8n_sub = sys.argv[5]
supa_sub = sys.argv[6]
studio_sub = sys.argv[7]
logs_sub = sys.argv[8]
tg_token = sys.argv[9] if len(sys.argv) > 9 else ""
tg_chat_id = sys.argv[10] if len(sys.argv) > 10 else ""

cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

def api_call(path, data=None, method="POST"):
    url = f"{kuma_url}{path}"
    headers = {"Content-Type": "application/json"}
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        resp = opener.open(req)
        return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        print(f"  HTTP Error {e.code}: {e.read().decode()}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"  Error: {e}", file=sys.stderr)
        return None

# Login
print("Авторизация...", flush=True)
login_result = api_call("/api/login", {"username": username, "password": password})
if not login_result or not login_result.get("ok"):
    print("FAIL: Не удалось авторизоваться", flush=True)
    sys.exit(1)
print("OK: Авторизация успешна", flush=True)

# Setup Telegram notification if provided
notification_id = None
if tg_token and tg_chat_id:
    print("Создаю Telegram-уведомление...", flush=True)
    notif_result = api_call("/api/notification", {
        "name": "Telegram",
        "type": "telegram",
        "isDefault": True,
        "telegramBotToken": tg_token,
        "telegramChatID": tg_chat_id,
    })
    if notif_result and notif_result.get("ok"):
        notification_id = notif_result.get("id")
        print(f"OK: Telegram-уведомление создано (id={notification_id})", flush=True)
    else:
        print("WARN: Не удалось создать Telegram-уведомление", flush=True)

# Create monitors
monitors = [
    {"name": "n8n", "url": f"https://{n8n_sub}.{domain}/healthz"},
    {"name": "Supabase API", "url": f"https://{supa_sub}.{domain}/health"},
    {"name": "Supabase Studio", "url": f"https://{studio_sub}.{domain}"},
    {"name": "Grafana", "url": f"https://{logs_sub}.{domain}/api/health"},
]

for m in monitors:
    print(f"Создаю монитор: {m['name']}...", flush=True)
    monitor_data = {
        "name": m["name"],
        "type": "http",
        "url": m["url"],
        "interval": 300,
        "retryInterval": 60,
        "maxretries": 3,
        "accepted_statuscodes": ["200-299", "301", "302"],
        "active": True,
    }
    if notification_id:
        monitor_data["notificationIDList"] = [notification_id]

    result = api_call("/api/monitor", monitor_data)
    if result and result.get("ok"):
        print(f"OK: {m['name']}", flush=True)
    else:
        print(f"FAIL: {m['name']}", flush=True)

print("Готово!", flush=True)
PYEOF

python3 "$KUMA_SCRIPT" \
    "$KUMA_URL" \
    "$KUMA_USER" \
    "$KUMA_PASS" \
    "$DOMAIN" \
    "$N8N_SUBDOMAIN" \
    "$SUPABASE_SUBDOMAIN" \
    "$STUDIO_SUBDOMAIN" \
    "$LOGS_SUBDOMAIN" \
    "$TELEGRAM_TOKEN" \
    "$TELEGRAM_CHAT_ID" \
    && RESULT=0 || RESULT=1

echo ""
if [ "$RESULT" -eq 0 ]; then
    success "Мониторы настроены!"
else
    warn "Автоматическая настройка завершилась с ошибками"
    echo ""
    echo "Настройте мониторы вручную через веб-интерфейс:"
    echo "  https://${STATUS_SUBDOMAIN}.${DOMAIN}"
    echo ""
    echo "Мониторы для создания:"
    echo "  1. n8n          → https://${N8N_SUBDOMAIN}.${DOMAIN}/healthz       (HTTP, 300s, retries: 3)"
    echo "  2. Supabase API → https://${SUPABASE_SUBDOMAIN}.${DOMAIN}/health   (HTTP, 300s, retries: 3)"
    echo "  3. Studio       → https://${STUDIO_SUBDOMAIN}.${DOMAIN}            (HTTP, 300s, retries: 3)"
    echo "  4. Grafana      → https://${LOGS_SUBDOMAIN}.${DOMAIN}/api/health   (HTTP, 300s, retries: 3)"
fi
