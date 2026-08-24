#!/bin/sh
# =============================================================================
# check_monitoring.sh — поднимает стек наблюдаемости и проверяет его работу.
# Совместим с POSIX sh (проверять: sh -n monitoring/check_monitoring.sh).
# Запускать можно из любого каталога; предполагается, что приложение уже
# развёрнуто через setup.sh (есть .env и склонированный umami-src).
#
# Использование:
#   sh monitoring/check_monitoring.sh            # up -d + проверки
#   sh monitoring/check_monitoring.sh --check    # только проверки (без up)
#   sh monitoring/check_monitoring.sh --down      # остановить стек мониторинга
# =============================================================================
set -u

# --- Перейти в корень репозитория (скрипт лежит в monitoring/) ---------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

MON_FILE="monitoring/docker-compose.monitoring.yml"

# --- Вывод -------------------------------------------------------------------
info() { printf '\033[0;34m[INFO]\033[0m %s\n' "$1"; }
ok()   { printf '\033[0;32m[ OK ]\033[0m %s\n' "$1"; }
warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$1"; }
err()  { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1" >&2; }

FAILED=0
pass() { ok "$1"; }
fail() { err "$1"; FAILED=$((FAILED + 1)); }

# --- Выбор команды compose ---------------------------------------------------
DC=""
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  err "Не найден docker compose. Установите Docker Compose."
  exit 1
fi

# Обёртка: compose с обоими файлами (общая сеть с приложением)
dcm() { $DC -f docker-compose.yml -f "$MON_FILE" "$@"; }

# --- Предусловия -------------------------------------------------------------
preflight() {
  if ! docker info >/dev/null 2>&1; then
    err "Docker-демон недоступен. Запустите docker и повторите."
    exit 1
  fi
  if [ ! -f .env ]; then
    err "Нет .env — сначала разверните приложение: sh setup.sh"
    exit 1
  fi
  if [ ! -d umami-src ]; then
    err "Нет каталога umami-src — сначала выполните: sh setup.sh"
    exit 1
  fi
}

# --- HTTP-хелперы ------------------------------------------------------------
http_code() { curl -s -o /dev/null -w "%{http_code}" "$1" 2>/dev/null || echo "000"; }

# wait_http URL EXPECTED_CODE TIMEOUT_SEC NAME
wait_http() {
  _url="$1"; _exp="$2"; _timeout="$3"; _name="$4"
  _i=0
  while [ "$_i" -lt "$_timeout" ]; do
    _code=$(http_code "$_url")
    if [ "$_code" = "$_exp" ]; then return 0; fi
    _i=$((_i + 2)); sleep 2
  done
  return 1
}

# Извлечь скалярное значение из ответа Prometheus /query
prom_scalar() {
  curl -s "http://localhost:9090/api/v1/query" --data-urlencode "query=$1" 2>/dev/null \
    | grep -o '"value":\[[0-9.]*,"[^"]*"\]' | head -1 \
    | sed 's/.*,"//; s/"\]//'
}

# --- Поднятие стека ----------------------------------------------------------
up_stack() {
  info "Поднимаю стек наблюдаемости (это может занять до минуты)..."
  if ! dcm up -d; then
    err "Не удалось выполнить 'compose up -d'. Логи:"
    dcm ps
    exit 1
  fi
  ok "Контейнеры запущены. Жду готовности сервисов и первых скрейпов..."
}

# --- Проверки ----------------------------------------------------------------
check_prometheus() {
  if wait_http "http://localhost:9090/-/healthy" "200" 60 "prometheus"; then
    pass "Prometheus доступен (:9090)"
  else
    fail "Prometheus не поднялся (:9090)"; return
  fi
  # Все таргеты up?
  _i=0
  while [ "$_i" -lt 60 ]; do
    _body=$(curl -s "http://localhost:9090/api/v1/targets" 2>/dev/null || echo "")
    _total=$(printf '%s' "$_body" | grep -o '"health":"[a-z]*"' | wc -l | tr -d ' ')
    _up=$(printf '%s' "$_body" | grep -o '"health":"up"' | wc -l | tr -d ' ')
    if [ "${_total:-0}" -gt 0 ] && [ "$_up" = "$_total" ]; then
      pass "Prometheus targets: все $_up/$_total UP"
      return
    fi
    _i=$((_i + 3)); sleep 3
  done
  fail "Prometheus targets: UP $_up из $_total (см. http://localhost:9090/targets)"
}

check_grafana() {
  if wait_http "http://localhost:3001/api/health" "200" 60 "grafana"; then
    pass "Grafana доступна (:3001, admin/admin)"
  else
    fail "Grafana не поднялась (:3001)"
  fi
  # Дашборды провижинятся автоматически — проверим, что папка/файлы на месте
  for d in health business logs; do
    if [ -f "monitoring/grafana/dashboards/${d}.json" ]; then
      pass "Дашборд ${d}.json присутствует (автопровижининг)"
    else
      fail "Нет дашборда ${d}.json"
    fi
  done
}

check_loki() {
  _i=0
  while [ "$_i" -lt 60 ]; do
    if curl -s "http://localhost:3100/ready" 2>/dev/null | grep -qi "ready"; then
      pass "Loki готов (:3100)"; break
    fi
    _i=$((_i + 3)); sleep 3
  done
  if [ "$_i" -ge 60 ]; then fail "Loki не готов (:3100)"; fi

  # Promtail должен доставить логи контейнеров — ждём появления меток container
  _i=0
  while [ "$_i" -lt 90 ]; do
    _vals=$(curl -s "http://localhost:3100/loki/api/v1/label/container/values" 2>/dev/null || echo "")
    if printf '%s' "$_vals" | grep -q "umami-app"; then
      pass "Loki получает логи контейнеров (найден umami-app)"
      return
    fi
    _i=$((_i + 3)); sleep 3
  done
  fail "Loki не видит логи umami-app (проверьте promtail и доступ к docker.sock)"
}

check_node_exporter() {
  if curl -s "http://localhost:9100/metrics" 2>/dev/null | grep -q "node_cpu_seconds_total"; then
    pass "Node Exporter отдаёт метрики хоста (:9100)"
  else
    fail "Node Exporter не отдаёт метрики (:9100)"
  fi
}

check_cadvisor() {
  if curl -s "http://localhost:8080/metrics" 2>/dev/null | grep -q "container_memory_usage_bytes"; then
    pass "cAdvisor отдаёт метрики контейнеров (:8080)"
  else
    fail "cAdvisor не отдаёт метрики (:8080)"
  fi
}

check_postgres_exporter() {
  _m=$(curl -s "http://localhost:9187/metrics" 2>/dev/null || echo "")
  if printf '%s' "$_m" | grep -q "^pg_up 1"; then
    pass "postgres-exporter подключён к БД (pg_up=1)"
  else
    fail "postgres-exporter не подключён к БД (pg_up!=1)"
  fi
  if printf '%s' "$_m" | grep -q "^umami_"; then
    pass "Бизнес-метрики umami_* экспортируются"
  else
    fail "Бизнес-метрики umami_* отсутствуют (проверьте pg-queries.yaml/схему)"
  fi
}

check_blackbox() {
  # Даём Prometheus время сделать первый probe
  _i=0
  while [ "$_i" -lt 45 ]; do
    _min=$(prom_scalar "min(probe_success)")
    if [ "$_min" = "1" ]; then
      pass "blackbox: все эндпоинты доступны (probe_success=1)"
      return
    fi
    _i=$((_i + 3)); sleep 3
  done
  fail "blackbox: не все эндпоинты доступны (min(probe_success)=${_min:-нет данных})"
}

show_summary_metrics() {
  info "Снимок текущих значений:"
  printf '  umami_websites_total      = %s\n' "$(prom_scalar 'umami_websites_total')"
  printf '  umami_sessions_total      = %s\n' "$(prom_scalar 'umami_sessions_total')"
  printf '  umami_events_pageviews    = %s\n' "$(prom_scalar 'umami_events_pageviews')"
  printf '  host CPU used %%            = %s\n' "$(prom_scalar '100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))*100)')"
  printf '  host RAM used %%            = %s\n' "$(prom_scalar '(1-(node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes))*100')"
}

# --- main --------------------------------------------------------------------
MODE="up"
if [ "${1:-}" = "--check" ]; then MODE="check"; fi
if [ "${1:-}" = "--down" ]; then MODE="down"; fi

preflight

if [ "$MODE" = "down" ]; then
  info "Останавливаю стек мониторинга..."
  dcm stop prometheus grafana node-exporter cadvisor postgres-exporter blackbox-exporter loki promtail
  ok "Стек мониторинга остановлен (приложение не тронуто)."
  exit 0
fi

if [ "$MODE" = "up" ]; then
  up_stack
fi

printf '\n============================================================\n'
info "Проверка компонентов стека наблюдаемости"
printf '============================================================\n'

check_prometheus
check_grafana
check_loki
check_node_exporter
check_cadvisor
check_postgres_exporter
check_blackbox

printf '\n'
show_summary_metrics

printf '\n============================================================\n'
if [ "$FAILED" -eq 0 ]; then
  ok "Все проверки пройдены. Стек наблюдаемости работает."
  info "Grafana: http://localhost:3001 (admin/admin) — дашборды Health, Business, Logs"
  exit 0
else
  err "Проваленных проверок: $FAILED"
  info "Диагностика: docker compose -f docker-compose.yml -f $MON_FILE logs <service>"
  exit 1
fi
