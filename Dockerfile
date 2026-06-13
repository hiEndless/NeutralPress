FROM node:22-bookworm-slim AS base

WORKDIR /app

ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
ENV NEXT_TELEMETRY_DISABLED=1

RUN corepack enable
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

FROM base AS builder

COPY . .

RUN pnpm install --frozen-lockfile

# 通用镜像：构建阶段不依赖业务数据库/Redis
RUN pnpm --filter @repo/shared-types run build
RUN pnpm --filter web run gen-prisma
RUN pnpm --filter web run build:portable:standalone

# 运行期保留 Prisma CLI 与 @prisma/client，用于 migrate deploy 以及必要时重新生成 Client
RUN set -eu; \
  prisma_version="$(node -e "const pkg=require('/app/apps/web/package.json'); const raw=(pkg.devDependencies?.prisma ?? pkg.dependencies?.prisma ?? 'latest').trim(); process.stdout.write(raw.replace(/^[~^]/, ''));")"; \
  prisma_client_version="$(node -e "const pkg=require('/app/apps/web/package.json'); const raw=(pkg.dependencies?.['@prisma/client'] ?? pkg.devDependencies?.['@prisma/client'] ?? 'latest').trim(); process.stdout.write(raw.replace(/^[~^]/, ''));")"; \
  mkdir -p /tmp/prisma-runtime-install; \
  cd /tmp/prisma-runtime-install; \
  npm init -y >/dev/null 2>&1; \
  npm install --omit=dev --no-audit --no-fund "prisma@$prisma_version" "@prisma/client@$prisma_client_version"

FROM base AS runner

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000
ENV NEXT_TELEMETRY_DISABLED=1
ENV PRISMA_CLI_PATH=/app/prisma-runtime/node_modules/prisma/build/index.js

RUN groupadd --system --gid 1001 nodejs && useradd --system --uid 1001 nextjs

# standalone 主体
COPY --from=builder --chown=nextjs:nodejs /app/apps/web/.next/standalone ./
# Prisma schema/migrations（运行期 migrate deploy 需要）
COPY --from=builder --chown=nextjs:nodejs /app/apps/web/prisma ./apps/web/prisma
# Prisma CLI 与 @prisma/client 完整依赖树（用于 migrate deploy，避免动态依赖缺失）
COPY --from=builder --chown=nextjs:nodejs /tmp/prisma-runtime-install/node_modules ./prisma-runtime/node_modules
# 补齐 standalone tracing 可能裁剪掉的 @prisma/client 模板文件，供 prisma generate 使用
COPY --from=builder --chown=nextjs:nodejs /tmp/prisma-runtime-install/node_modules/@prisma/client ./apps/web/node_modules/@prisma/client

# Next.js 运行期会写入 .next（例如 ISR/prerender 缓存）
RUN mkdir -p /app/apps/web/.next/cache \
  && chown -R nextjs:nodejs /app/apps/web/.next /app/apps/web/node_modules

USER nextjs

EXPOSE 3000

CMD ["node", "apps/web/server.js"]
