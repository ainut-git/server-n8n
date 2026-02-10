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

Скрипт установит Docker, настроит firewall, сгенерирует все пароли, настроит роли БД и запустит сервисы.

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

### 5. Настройка мониторов в Uptime Kuma

После создания аккаунта добавьте мониторы вручную через веб-интерфейс:

1. Нажмите **«Add New Monitor»**
2. Создайте 4 монитора:

| Имя | Тип | URL | Interval | Retries |
|-----|-----|-----|----------|---------|
| n8n | HTTP(s) | `https://n8n.<domain>/healthz` | 300 сек | 3 |
| Supabase API | HTTP(s) | `https://supabase.<domain>/health` | 300 сек | 3 |
| Supabase Studio | HTTP(s) | `https://studio.<domain>/` | 300 сек | 3 |
| Grafana | HTTP(s) | `https://logs.<domain>/api/health` | 300 сек | 3 |

**Для монитора Supabase Studio** дополнительно настройте авторизацию:

1. В разделе **«Аутентификация»** выберите метод **«HTTP Авторизация»**
2. Логин: `admin`
3. Пароль: значение `STUDIO_BASIC_AUTH_PASSWORD` из `.env`:
   ```bash
   grep "^STUDIO_BASIC_AUTH_PASSWORD=" .env | cut -d= -f2
   ```

### 6. Настройка Telegram-уведомлений (опционально)

Если вы хотите получать уведомления о падении сервисов в Telegram, настройте их вручную через Uptime Kuma:

**Шаг 1. Создайте бота в Telegram**

1. Откройте Telegram, найдите `@BotFather`
2. Отправьте `/newbot`
3. Введите имя бота (например, «Server Monitor»)
4. Введите username бота (например, `my_server_monitor_bot`)
5. Скопируйте **Bot Token** (формат: `123456789:ABCdefGhIjKlMnOpQrStUvWxYz`)

**Шаг 2. Получите Chat ID**

1. Отправьте любое сообщение вашему новому боту
2. Откройте в браузере:
   ```
   https://api.telegram.org/bot<ВАШ_BOT_TOKEN>/getUpdates
   ```
3. В ответе найдите `"chat":{"id":123456789}` — это ваш **Chat ID**

Для группового чата: добавьте бота в группу, отправьте сообщение в группу, затем откройте ту же ссылку. Chat ID группы будет отрицательным (например, `-1001234567890`).

**Шаг 3. Настройте в Uptime Kuma**

1. Откройте `https://status.<domain>`
2. Перейдите в **Settings → Notifications** (значок шестерёнки в верхнем правом углу)
3. Нажмите **«Setup Notification»**
4. Выберите тип: **Telegram**
5. Заполните:
   - **Friendly Name**: `Telegram`
   - **Bot Token**: вставьте токен бота
   - **Chat ID**: вставьте Chat ID
6. Нажмите **«Test»** — должно прийти тестовое сообщение
7. Включите **«Default enabled»** — все новые мониторы будут использовать этот канал
8. Нажмите **«Save»**

**Шаг 4. Привяжите уведомление к существующим мониторам**

Если мониторы уже созданы, для каждого монитора:

1. Нажмите на монитор → **Edit**
2. Прокрутите до раздела **«Notifications»**
3. Включите переключатель рядом с «Telegram»
4. Нажмите **«Save»**

Готово! Теперь при падении любого сервиса (3 неудачных проверки подряд) вы получите сообщение в Telegram.

### 7. Проверка

```bash
chmod +x test.sh && ./test.sh
```

---

## Обслуживание

### Обновление сервисов

#### Шаг 1. Проверьте текущие версии

```bash
docker compose images
```

#### Шаг 2. Найдите новые версии

Ссылки на Docker Hub для каждого сервиса:

| Сервис | Docker Hub |
|--------|-----------|
| Supabase Postgres | https://hub.docker.com/r/supabase/postgres/tags |
| Supabase Auth | https://hub.docker.com/r/supabase/gotrue/tags |
| PostgREST | https://hub.docker.com/r/postgrest/postgrest/tags |
| Supabase Realtime | https://hub.docker.com/r/supabase/realtime/tags |
| Supabase Storage | https://hub.docker.com/r/supabase/storage-api/tags |
| ImgProxy | https://hub.docker.com/r/darthsim/imgproxy/tags |
| Postgres Meta | https://hub.docker.com/r/supabase/postgres-meta/tags |
| Kong | https://hub.docker.com/_/kong/tags |
| Supabase Studio | https://hub.docker.com/r/supabase/studio/tags |
| n8n | https://hub.docker.com/r/n8nio/n8n/tags |
| Loki | https://hub.docker.com/r/grafana/loki/tags |
| Promtail | https://hub.docker.com/r/grafana/promtail/tags |
| Grafana | https://hub.docker.com/r/grafana/grafana/tags |
| Uptime Kuma | https://hub.docker.com/r/louislam/uptime-kuma/tags |
| Caddy | https://hub.docker.com/_/caddy/tags |

Для Supabase удобнее смотреть всё разом: https://github.com/supabase/supabase/releases — ищите тег `[BREAKING]`.

**Важно:** обновляйте только minor/patch версии. Мажорные обновления (1.x → 2.x) требуют ручной миграции.

#### Шаг 3. Обновите версии в docker-compose.yml

Замените теги образов с помощью `sed`. Пример:

```bash
cd /root/server-n8n

# Пример: обновить n8n с 1.123.16 на 1.123.18
sed -i 's|n8nio/n8n:1.123.16|n8nio/n8n:1.123.18|' docker-compose.yml

# Пример: обновить gotrue (Auth)
sed -i 's|supabase/gotrue:v2.172.0|supabase/gotrue:v2.186.0|' docker-compose.yml

# Проверьте результат
grep 'image:' docker-compose.yml
```

#### Шаг 4. Запустите обновление

```bash
chmod +x update.sh
./update.sh
```

Скрипт автоматически:
- создаст бэкап всех данных и конфигураций
- скачает новые образы
- запустит сервисы в правильном порядке (Postgres → Auth → остальные)
- восстановит пароли ролей Postgres (они могут сбрасываться после рестарта)
- проверит что все контейнеры запущены

#### Если обновление не удалось

```bash
chmod +x rollback.sh
./rollback.sh
```

#### Примечание о паролях Postgres

Supabase использует несколько служебных ролей в Postgres (`supabase_auth_admin`, `authenticator`, `supabase_storage_admin`). При перезапуске контейнера Postgres их пароли могут сбрасываться. Скрипт `update.sh` автоматически восстанавливает пароли после запуска Postgres. Если вы перезапускаете Postgres вручную (`docker compose restart supabase-db`), выполните после этого:

```bash
PGPASS=$(grep "^POSTGRES_PASSWORD=" .env | cut -d= -f2)
docker exec -e PGPASSWORD="${PGPASS}" supabase-db psql -U supabase_admin -d postgres -c "ALTER ROLE supabase_auth_admin WITH PASSWORD '${PGPASS}';"
docker exec -e PGPASSWORD="${PGPASS}" supabase-db psql -U supabase_admin -d postgres -c "ALTER ROLE authenticator WITH PASSWORD '${PGPASS}';"
docker exec -e PGPASSWORD="${PGPASS}" supabase-db psql -U supabase_admin -d postgres -c "ALTER ROLE supabase_storage_admin WITH PASSWORD '${PGPASS}';"
docker compose restart supabase-auth supabase-rest supabase-storage supabase-realtime
```

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
└── README.md
```
