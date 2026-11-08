# Build the Vite frontend, then serve the static artifact with Nginx.
FROM node:22-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run typecheck && npm run build

FROM nginx:1.27-alpine
ARG APP_VERSION_SHA=unknown
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/dist /usr/share/nginx/html
RUN printf '{"version":"%s"}\n' "$APP_VERSION_SHA" > /usr/share/nginx/html/version.json
COPY docker-entrypoint-env.sh /docker-entrypoint.d/40-env.sh
RUN chmod +x /docker-entrypoint.d/40-env.sh
EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=5 CMD wget -qO- http://127.0.0.1/health || exit 1
