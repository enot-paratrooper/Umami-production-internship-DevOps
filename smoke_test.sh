#!/bin/sh
# =============================================================================
# smoke_test.sh — функциональные проверки Umami.
# Совместим с POSIX sh. Завершается с кодом 1, если хотя бы одна проверка
# провалилась. Формат вывода: [OK] GET /path  или  [FAIL] GET /path (got NNN).
# =============================================================================
set -u

BASE="${BASE_URL:-http://localhost:3000}"
FAILED=0

# check METHOD PATH EXPECTED [DATA]
check() {
  METHOD="$1"
  PATH_="$2"
  EXPECTED="$3"
  DATA="${4:-}"

  if [ "$METHOD" = "POST" ]; then
    CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -A "smoke-test" \
      -X POST "${BASE}${PATH_}" \
      -H 'Content-Type: application/json' \
      -d "$DATA" 2>/dev/null || echo "000")
  else
    CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -A "smoke-test" \
      "${BASE}${PATH_}" 2>/dev/null || echo "000")
  fi

  # EXPECTED — список допустимых кодов через пробел (например "200 201 204")
  MATCH=0
  for e in $EXPECTED; do
    if [ "$CODE" = "$e" ]; then MATCH=1; fi
  done

  if [ "$MATCH" = "1" ]; then
    printf '[OK] %s %s\n' "$METHOD" "$PATH_"
  else
    printf '[FAIL] %s %s (got %s)\n' "$METHOD" "$PATH_" "$CODE"
    FAILED=1
  fi
}

printf 'Smoke-тесты Umami по адресу %s\n' "$BASE"
printf -- '------------------------------------------------------------\n'

# 1. Health-эндпоинт
check GET /api/heartbeat "200"

# 2. Страница логина (SSR)
check GET /login "200"

# 3. Трекер-скрипт (публичная статика)
check GET /script.js "200"

# 4. Аутентификация (возвращает токен) — основной API-эндпоинт
check POST /api/auth/login "200" '{"username":"admin","password":"umami"}'

printf -- '------------------------------------------------------------\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'Все проверки пройдены.\n'
  exit 0
else
  printf 'Есть проваленные проверки.\n'
  exit 1
fi
