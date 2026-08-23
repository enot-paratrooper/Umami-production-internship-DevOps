# Umami — DevOps-инфраструктура (учебный проект)

Воспроизводимое развёртывание [Umami](https://github.com/umami-software/umami)
(приватная веб-аналитика, альтернатива Google Analytics) — контейнеризация,
автоматизация, CI/CD и наблюдаемость.

- **Приложение:** Umami, Next.js / TypeScript
- **СУБД:** PostgreSQL 16
- **Зафиксированная версия upstream:** `v3.2.0` (клонируется `setup.sh`)

## Быстрый старт

Требуется чистая машина с `docker`, `git`, `curl`, `openssl`:

```sh
git clone <этот-репозиторий> app && cd app
sh setup.sh
```

Скрипт сам: проверит зависимости, сгенерирует `.env` со случайными паролями,
склонирует umami на теге `v3.2.0`, соберёт образ, поднимет стек, дождётся БД
и приложения, загрузит тестовые данные и выполнит быструю проверку.

После завершения:
- Приложение: <http://localhost:3000>
- Вход: <http://localhost:3000/login> — `admin` / `umami`
- Heartbeat: <http://localhost:3000/api/heartbeat>

## Smoke-тесты

```sh
sh smoke_test.sh              # проверяет /api/heartbeat, /login, /script.js, /api/auth/login
BASE_URL=http://localhost:3000 sh smoke_test.sh
```

## CI/CD

`.github/workflows/ci.yml` при каждом push в `main` разворачивает стек «с нуля»
(`sh setup.sh`) и прогоняет `sh smoke_test.sh` в чистом окружении раннера.

Проверка падения CI: временно указать неверный пароль БД (например, сломать
`DATABASE_URL` в compose или подменить `POSTGRES_PASSWORD`) — пайплайн станет
красным на шаге ожидания приложения. Скриншот приложить в отчёт.

## Мониторинг и логи

Запуск вместе с основным стеком:

```sh
docker compose -f docker-compose.yml -f monitoring/docker-compose.monitoring.yml up -d
```

- Grafana: <http://localhost:3001> (`admin` / `admin`) — дашборды Health, Business
  и Logs провижинятся автоматически.
- Prometheus: <http://localhost:9090>
- Метрики: node-exporter (хост), cAdvisor (контейнеры), postgres-exporter
  (БД + бизнес-метрики umami), blackbox-exporter (доступность/латентность HTTP).
- Логи: Loki + Promtail. Готовый лог-вьювер — дашборд **Umami — Logs**
  (папка Umami): панель с реальными записями контейнеров + фильтр по контейнеру.
  Ad-hoc — через Grafana → Explore → Loki, запрос `{container="umami-app"}`.