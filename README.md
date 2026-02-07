# Server n8n

Production-ready self-hosted инфраструктура: **n8n** + **Supabase** + **Loki/Grafana** + **Uptime Kuma** на одном сервере.

---

## Быстрый старт (5 минут)

### Требования

| Ресурс | Минимум | Рекомендуется |
|--------|---------|---------------|
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |
| Диск | 40 GB SSD | 80 GB SSD |
| ОС | Ubuntu 24.04 | Ubuntu 24.04 |

DNS: создайте A-записи для `n8n`, `supabase`, `studio`, `logs`, `status` → IP вашего сервера.

### Установка

```bash
ssh root@your-server

git clone https://github.com/ainut-git/server-n8n.git
cd server-n8n

chmod +x install.sh && ./install.sh
```

Скрипт установит Docker, настроит firewall, сгенерирует все пароли и запустит сервисы.

---

## Карта поддоменов

| Поддомен | Сервис | Аутентификация | Логин / пароль |
|----------|--------|----------------|----------------|
| `n8n.<domain>` | n8n | Нативная | Создаётся при первом входе |
| `supabase.<domain>` | Supabase API (Kong) | API-ключи | `ANON_KEY` / `SERVICE_ROLE_KEY` из `.env` |
| `studio.<domain>` | Supabase Studio | Basic Auth (Caddy) | `STUDIO_BASIC_AUTH_USER` / `STUDIO_BASIC_AUTH_PASSWORD` из `.env` |
| `logs.<domain>` | Grafana | Нативная | `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` из `.env` |
| `status.<domain>` | Uptime Kuma | Нативная | Создаётся при первом входе |

---

## Первая настройка

### 1. n8n

Откройте `https://n8n.<domain>` и создайте аккаунт администратора (email + пароль).

### 2. Supabase Studio

Откройте `https://studio.<domain>`. Введите Basic Auth логин и пароль из `.env`:

```bash
grep STUDIO_BASIC_AUTH .env
```

### 3. Grafana

Откройте `https://logs.<domain>`. Логин и пароль:

```bash
grep GRAFANA .env
```

Дашборд «Docker Logs» уже настроен — выберите контейнер в выпадающем списке.

### 4. Uptime Kuma

Откройте `https://status.<domain>` и создайте аккаунт администратора.

### 5. Настройка мониторов

После создания аккаунта в Uptime Kuma:

```bash
chmod +x kuma_config.sh && ./kuma_config.sh
```

Скрипт создаст мониторы для всех сервисов и (опционально) настроит Telegram-уведомления.

### 6. Проверка

```bash
chmod +x test.sh && ./test.sh
```

---

## Обслуживание

### Обновление сервисов

1. Прочитайте [Supabase Releases](https://github.com/supabase/supabase/releases) — ищите тег `[BREAKING]`
2. Запустите обновление:

```bash
./update.sh
```

Скрипт автоматически создаст бэкап перед обновлением.

### Просмотр логов

Откройте Grafana (`https://logs.<domain>`), перейдите в дашборд «Docker Logs». Выберите контейнер в выпадающем списке, используйте поле поиска для фильтрации.

Или через CLI:

```bash
docker compose logs n8n --tail=100 -f
docker compose logs supabase-db --tail=100 -f
```

### Когда беспокоиться

- Uptime Kuma отправил алерт в Telegram — сервис недоступен 3 проверки подряд (15 минут)
- `test.sh` показывает ❌ — проверьте логи указанного сервиса
- Диск заполнен более чем на 85% — очистите старые бэкапы или увеличьте диск

### Параметры бэкапов

Настраиваются в `.env`:

| Параметр | По умолчанию | Описание |
|----------|-------------|----------|
| `BACKUP_DIR` | `/opt/backups` | Директория для бэкапов |
| `BACKUP_MAX_COUNT` | `30` | Максимум хранимых бэкапов |
| `BACKUP_ENABLED` | `true` | Включить/отключить бэкапы |

### Мажорные обновления Postgres

Мажорные обновления (например, 15.x → 16.x) **не покрываются** скриптом `update.sh`. Это ручной процесс:

```bash
# 1. Создайте бэкап
docker exec supabase-db pg_dumpall -U supabase_admin > /opt/backups/pg_dump_before_upgrade.sql

# 2. Остановите сервисы
docker compose down

# 3. Обновите версию образа в docker-compose.yml

# 4. Удалите старый volume (данные будут восстановлены из дампа)
docker volume rm $(docker volume ls -q | grep supabase-db-data)

# 5. Запустите Postgres
docker compose up -d supabase-db

# 6. Дождитесь запуска и восстановите данные
docker exec -i supabase-db psql -U supabase_admin < /opt/backups/pg_dump_before_upgrade.sql

# 7. Запустите остальные сервисы
docker compose up -d
```

---

## Если что-то пошло не так

### Диагностика

```bash
./test.sh
```

Каждая проверка показывает ✅ или ❌ с рекомендацией по исправлению.

### Откат

```bash
./rollback.sh
```

Скрипт найдёт последний бэкап, восстановит volumes и конфигурации, запустит сервисы.

### Где искать ошибки

```bash
# Логи конкретного сервиса
docker compose logs <service> --tail=200

# Статус контейнеров
docker compose ps

# Все логи
docker compose logs --tail=50

# Перезапуск проблемного сервиса
docker compose restart <service>
```

Имена сервисов: `supabase-db`, `supabase-auth`, `supabase-rest`, `supabase-realtime`, `supabase-storage`, `kong`, `supabase-studio`, `n8n`, `instrument`, `loki`, `promtail`, `grafana`, `uptime-kuma`, `caddy`.

---

## Безопасность

### Где хранятся пароли

Все пароли и ключи хранятся в файле `.env` в корне проекта. Файл имеет права `600` и добавлен в `.gitignore`.

```bash
cat .env
```

### Как сменить пароли

**Grafana:**
```bash
# Отредактируйте .env
nano .env
# Перезапустите Grafana
docker compose restart grafana
```

**Studio Basic Auth:**
```bash
# Сгенерируйте новый хеш пароля
docker run --rm caddy:2.9 caddy hash-password --plaintext 'новый-пароль'
# Обновите STUDIO_BASIC_AUTH_PASSWORD и STUDIO_BASIC_AUTH_PASSWORD_HASH в .env
nano .env
# Перезапустите Caddy
docker compose restart caddy
```

**Postgres:**
Смена пароля Postgres требует обновления пароля в самой БД и во всех сервисах. Рекомендуется делать это только при крайней необходимости.

### Рекомендации

- Ограничьте SSH-доступ по ключам (отключите пароль)
- Регулярно обновляйте систему: `apt update && apt upgrade`
- Следите за алертами Uptime Kuma в Telegram
- Не открывайте дополнительные порты в firewall
- Не публикуйте `.env` файл

---

## Архитектура

```
Internet → Caddy (80/443) → внутренние сервисы (Docker network)
```

Все сервисы работают в единой Docker-сети. Только Caddy публикует порты наружу. Instrument service доступен только внутри Docker-сети.

### Instrument service

Сервис для выполнения shell-команд из n8n (ffmpeg, yt-dlp и др.):

```
POST http://instrument:8000/run
Content-Type: application/json

{
  "command": "yt-dlp -o '/data/video.mp4' 'https://...'",
  "timeout": 300
}
```

Volume `/data` — общий с n8n, файлы доступны обоим сервисам.

---

## Структура проекта

```
├── docker/
│   ├── caddy/Caddyfile
│   ├── n8n/
│   ├── supabase/kong.yml
│   ├── instrument/Dockerfile + app.py
│   ├── loki/loki-config.yml
│   ├── promtail/promtail-config.yml
│   └── grafana/provisioning/
├── docker-compose.yml
├── .env.example
├── install.sh
├── update.sh
├── rollback.sh
├── test.sh
├── kuma_config.sh
└── README.md
```
