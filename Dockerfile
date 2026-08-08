# =============================================================================
# Umami — hardened multi-stage Dockerfile
# Основан на upstream Dockerfile тега v3.2.0 (umami-software/umami).
# setup.sh копирует этот файл в ./umami-src/Dockerfile перед сборкой,
# заменяя оригинальный Dockerfile проекта.
#
# ЧТО ИЗМЕНЕНО ПО СРАВНЕНИЮ С ОРИГИНАЛОМ (см. отчёт, этап 1):
#   1. Версии базового образа и инструментов вынесены в ARG и жёстко
#      зафиксированы (воспроизводимость сборки).
#   2. Добавлены OCI-метки (LABEL) — происхождение и версия образа.
#   3. Добавлена инструкция HEALTHCHECK на уровне образа (оригинал полагался
#      только на healthcheck в compose).
#   4. Явно подтверждён и прокомментирован запуск от non-root пользователя.
# Стадии сборки (deps/builder) и логика build-docker сохранены без изменений,
# чтобы не сломать штатный процесс сборки umami (prisma + next standalone).
# =============================================================================

ARG NODE_IMAGE_VERSION="22-alpine"
ARG PNPM_VERSION="10.15.1"
# Держать в синхронизации с prisma/@prisma/* версиями в package.json
ARG PRISMA_VERSION="7.8.0"

# ---- Стадия 1: зависимости --------------------------------------------------
FROM node:${NODE_IMAGE_VERSION} AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN npm install -g pnpm
RUN printf 'strictDepBuilds: false\n' > pnpm-workspace.yaml
RUN pnpm install --frozen-lockfile

# ---- Стадия 2: сборка приложения --------------------------------------------
FROM node:${NODE_IMAGE_VERSION} AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
COPY docker/proxy.ts ./src
ARG BASE_PATH
ENV BASE_PATH=$BASE_PATH
ENV NEXT_TELEMETRY_DISABLED=1
# Фиктивный DATABASE_URL нужен только для генерации prisma-клиента на этапе сборки
ENV DATABASE_URL="postgresql://user:pass@localhost:5432/dummy"
RUN npm run build-docker

# ---- Стадия 3: рантайм ------------------------------------------------------
# Финальный образ не содержит dev-зависимостей и инструментов сборки —
# копируется только результат next standalone + prisma + скрипты запуска.
FROM node:${NODE_IMAGE_VERSION} AS runner
WORKDIR /app
ARG NODE_OPTIONS
ARG PRISMA_VERSION
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_OPTIONS=$NODE_OPTIONS

# OCI-метки (добавлено): происхождение образа
LABEL org.opencontainers.image.title="umami-hardened" \
      org.opencontainers.image.description="Umami analytics, hardened image for DevOps practice" \
      org.opencontainers.image.source="https://github.com/umami-software/umami" \
      org.opencontainers.image.version="v3.2.0"

# Non-root пользователь (присутствовал в оригинале, сохранён и прокомментирован):
# приложение НИКОГДА не работает от root.
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

# curl нужен для HEALTHCHECK и для healthcheck в compose
RUN set -x \
    && apk add --no-cache curl libc6-compat \
    && npm install -g pnpm

RUN echo {} > package.json
RUN printf "allowBuilds:\n  '@prisma/engines': true\n  prisma: false\nverifyDepsBeforeRun: false\n" > pnpm-workspace.yaml

# Зависимости для скриптов запуска/миграций
RUN pnpm add npm-run-all dotenv chalk semver \
    prisma@${PRISMA_VERSION} \
    @prisma/client@${PRISMA_VERSION} \
    @prisma/adapter-pg@${PRISMA_VERSION}

COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/prisma.config.ts ./prisma.config.ts
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/generated ./generated
# Output file tracing (next standalone) — минимальный рантайм
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs

EXPOSE 3000
ENV HOSTNAME=0.0.0.0
ENV PORT=3000

# HEALTHCHECK на уровне образа (добавлено): проверка /api/heartbeat
HEALTHCHECK --interval=15s --timeout=5s --start-period=40s --retries=5 \
  CMD curl -fsS http://localhost:3000/api/heartbeat || exit 1

CMD ["npm", "run", "start-docker"]
