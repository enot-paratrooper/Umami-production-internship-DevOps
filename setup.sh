set -eu

# --- Конфигурация ------------------------------------------------------------
UMAMI_REPO="https://github.com/umami-software/umami.git"
UMAMI_TAG="v3.2.0"            # ФИКСАЦИЯ версии upstream (Р7). Не main/master!
SRC_DIR="umami-src"
ENV_FILE=".env"
APP_PORT_DEFAULT="3000"

# --- Утилиты вывода ----------------------------------------------------------
info()  { printf '\033[0;34m[INFO]\033[0m %s\n' "$1"; }
ok()    { printf '\033[0;32m[ OK ]\033[0m %s\n' "$1"; }
warn()  { printf '\033[0;33m[WARN]\033[0m %s\n' "$1"; }
err()   { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1" >&2; }

# --- Выбор команды compose (v2 предпочтительно) ------------------------------
DC=""
detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
  else
    err "Не найден docker compose (v2) или docker-compose (v1)."
    exit 1
  fi
}

# --- Шаг 1: проверка зависимостей --------------------------------------------
check_deps() {
  info "Проверка наличия docker и git..."
  if ! command -v docker >/dev/null 2>&1; then
    err "docker не установлен. Установите Docker: https://docs.docker.com/engine/install/"
    exit 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    err "git не установлен. Установите git и повторите."
    exit 1
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    err "openssl не установлен (нужен для генерации паролей)."
    exit 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    err "curl не установлен (нужен для проверок)."
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    err "Docker-демон недоступен. Запустите Docker и повторите."
    exit 1
  fi
  detect_compose
  ok "Все зависимости на месте (compose: $DC)."
}

# --- Шаг 2: генерация .env (идемпотентно) ------------------------------------
generate_env() {
  if [ -f "$ENV_FILE" ]; then
    warn ".env уже существует — секреты сохранены (идемпотентность)."
    return 0
  fi
  info "Генерация .env со случайными паролями..."
  DB_PASS=$(openssl rand -hex 16)
  APP_SECRET=$(openssl rand -hex 32)
  cat > "$ENV_FILE" <<EOF
POSTGRES_DB=umami
POSTGRES_USER=umami
POSTGRES_PASSWORD=${DB_PASS}
APP_SECRET=${APP_SECRET}
APP_PORT=${APP_PORT_DEFAULT}
EOF
  chmod 600 "$ENV_FILE"
  ok ".env создан (пароли сгенерированы, файл не коммитится)."
}

# --- Шаг 3: клонирование upstream на зафиксированном теге (идемпотентно) ------
fetch_source() {
  if [ -d "$SRC_DIR/.git" ]; then
    warn "Каталог $SRC_DIR уже существует — переиспользуется."
  else
    info "Клонирование umami ($UMAMI_TAG) в $SRC_DIR..."
    git clone --depth 1 --branch "$UMAMI_TAG" "$UMAMI_REPO" "$SRC_DIR"
  fi
  # Гарантируем нужный тег в любом случае
  ( cd "$SRC_DIR" && git fetch --depth 1 origin tag "$UMAMI_TAG" 2>/dev/null || true
    git checkout -q "tags/$UMAMI_TAG" 2>/dev/null || git checkout -q "$UMAMI_TAG" 2>/dev/null || true )
  info "Установка hardened Dockerfile в $SRC_DIR..."
  cp Dockerfile "$SRC_DIR/Dockerfile"
  ok "Исходники готовы (тег $UMAMI_TAG, Dockerfile заменён)."
}

# --- Шаг 4: сборка образов ---------------------------------------------------
build_images() {
  info "Сборка образов ($DC build)..."
  $DC build
  ok "Образы собраны."
}

# --- Шаг 5: запуск контейнеров ----------------------------------------------
start_stack() {
  info "Запуск контейнеров ($DC up -d)..."
  $DC up -d
  ok "Контейнеры запущены."
}

# --- Шаг 6: ожидание готовности СУБД -----------------------------------------
wait_for_db() {
  info "Ожидание готовности PostgreSQL..."
  i=0
  while [ "$i" -lt 60 ]; do
    if $DC exec -T db pg_isready -U umami -d umami >/dev/null 2>&1; then
      ok "PostgreSQL готов."
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  err "PostgreSQL не поднялся за отведённое время."
  $DC ps
  exit 1
}

# --- Шаг 7: ожидание приложения (миграции выполняются автоматически) ---------
# Umami при старте (start-docker) сам применяет prisma-миграции и создаёт
# пользователя admin/umami. Ждём, пока /api/heartbeat вернёт 200.
wait_for_app() {
  PORT=$(get_port)
  info "Ожидание приложения на http://localhost:${PORT} (миграции применяются автоматически)..."
  i=0
  while [ "$i" -lt 90 ]; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/api/heartbeat" 2>/dev/null || echo "000")
    if [ "$CODE" = "200" ]; then
      ok "Приложение отвечает (heartbeat 200)."
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  err "Приложение не ответило за отведённое время (последний код: ${CODE})."
  $DC logs --tail 40 umami || true
  exit 1
}

# --- Вспомогательное: прочитать порт из .env ---------------------------------
get_port() {
  P=$(grep '^APP_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2)
  [ -n "$P" ] || P="$APP_PORT_DEFAULT"
  printf '%s' "$P"
}

# --- Шаг 8: загрузка тестовых данных (best-effort, идемпотентно) -------------
# Генерируем данные сами: логин -> создание сайта "Demo" -> отправка событий.
seed_data() {
  PORT=$(get_port)
  BASE="http://localhost:${PORT}"
  info "Загрузка тестовых данных..."

  LOGIN=$(curl -s -X POST "${BASE}/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"umami"}' 2>/dev/null || true)
  TOKEN=$(printf '%s' "$LOGIN" | grep -o '"token":"[^"]*"' | head -n1 | sed 's/"token":"//; s/"$//')
  if [ -z "$TOKEN" ]; then
    warn "Не удалось получить токен — пропускаю сидинг (деплой не затронут)."
    return 0
  fi

  # Идемпотентность: если сайт Demo уже есть — не создаём повторно
  EXISTING=$(curl -s "${BASE}/api/websites" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true)
  WID=$(printf '%s' "$EXISTING" | grep -o '"name":"Demo"[^}]*"id":"[0-9a-f-]*"' | grep -o '"id":"[0-9a-f-]*"' | head -n1 | sed 's/"id":"//; s/"$//')

  if [ -z "$WID" ]; then
    CREATE=$(curl -s -X POST "${BASE}/api/websites" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H 'Content-Type: application/json' \
      -d '{"name":"Demo","domain":"demo.local"}' 2>/dev/null || true)
    WID=$(printf '%s' "$CREATE" | grep -o '"id":"[0-9a-f-]*"' | head -n1 | sed 's/"id":"//; s/"$//')
  fi

  if [ -z "$WID" ]; then
    warn "Не удалось определить website id — пропускаю отправку событий."
    return 0
  fi

  info "Отправка тестовых событий для website ${WID}..."
  n=0
  for path in / /about /pricing /blog /contact /docs /login; do
    curl -s -o /dev/null -A "Mozilla/5.0 (setup-seed)" \
      -X POST "${BASE}/api/send" \
      -H 'Content-Type: application/json' \
      -d "{\"type\":\"event\",\"payload\":{\"website\":\"${WID}\",\"hostname\":\"demo.local\",\"url\":\"${path}\",\"referrer\":\"\",\"title\":\"Demo\"}}" \
      2>/dev/null || true
    n=$((n + 1))
  done
  ok "Тестовые данные загружены (сайт Demo, ${n} событий)."
}

# --- Шаг 9: итоговый статус и быстрая проверка -------------------------------
final_status() {
  PORT=$(get_port)
  BASE="http://localhost:${PORT}"
  printf '\n============================================================\n'
  ok "Развёртывание завершено."
  printf '  Приложение:   %s\n' "$BASE"
  printf '  Логин:        %s/login  (admin / umami)\n' "$BASE"
  printf '  Heartbeat:    %s/api/heartbeat\n' "$BASE"
  printf '============================================================\n'
  info "Статус контейнеров:"
  $DC ps
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/api/heartbeat" 2>/dev/null || echo "000")
  printf '\n'
  if [ "$CODE" = "200" ]; then
    ok "Быстрая проверка: GET /api/heartbeat -> ${CODE}"
  else
    err "Быстрая проверка: GET /api/heartbeat -> ${CODE}"
    exit 1
  fi
}

# --- main --------------------------------------------------------------------
main() {
  check_deps
  generate_env
  fetch_source
  build_images
  start_stack
  wait_for_db
  wait_for_app
  seed_data
  final_status
}

main "$@"
