# syntax=docker/dockerfile:1
# Sim Bridge relay. State is memory-only, so the image needs no volumes.
FROM node:22-bookworm-slim AS build
WORKDIR /app
# better-sqlite3 compiles its native module from source.
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

FROM node:22-bookworm-slim
ENV NODE_ENV=production \
    PORT=8787 \
    SIM_BRIDGE_DISCOVERY=off
WORKDIR /app

COPY package.json package-lock.json ./
COPY --from=build /app/node_modules ./node_modules

# Copy only runtime sources: never local databases, logs or .env files.
COPY src ./src
COPY public ./public

USER node
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||8787)+'/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"]
# Run node directly so SIGTERM reaches the relay's graceful shutdown.
CMD ["node", "src/server.mjs"]
