# ---------------------
# Build stage
# ---------------------
FROM node:22-alpine AS build

# Enable corepack and install a specific pnpm version securely
RUN corepack enable && corepack prepare pnpm@10.3.0 --activate


# Set working directory
WORKDIR /app

# Build-time environment for Next.js. Public variables are embedded during
# `next build`, so they must be available in the Docker build stage.
ARG NEXT_PUBLIC_MODE=DEV
ARG NEXT_PUBLIC_BASE_URL=http://localhost:5000
ARG NEXT_PUBLIC_ECOSYSTEM_FRONT_END_URL=http://localhost:3000
ARG CRYPTO_PRIVATE_KEY=change-me
ARG NEXT_PUBLIC_PLATFORM_NAME=CREDEBL
ARG NEXTAUTH_URL=http://localhost:3000
ARG NEXTAUTH_SECRET=change-me
ARG NEXTAUTH_COOKIE_DOMAIN=
ARG NEXTAUTH_PROTOCOL=http
ARG PUBLIC_ALLOW_DOMAIN=
ARG NEXT_PUBLIC_ENABLE_APP_LAUNCHER=false
ARG NEXT_PUBLIC_APP_NAME=CREDEBL
ARG NEXT_PUBLIC_ENABLE_SOCIAL_LOGIN=false
ARG NEXT_PUBLIC_ENABLE_BILLING_OPTION=false
ARG NEXT_PUBLIC_ACTIVE_THEME=credebl
ARG NEXT_PUBLIC_APP_TITLE=CREDEBL Studio
ARG NEXT_PUBLIC_FOOTER_TEXT=CDPI PoC
ARG NEXT_PUBLIC_LOGO_BASE_URL=
ARG NEXT_PUBLIC_ADMIN_PORTAL_CLIENT_ID=adminClient
ARG NEXT_PUBLIC_LANDINGPAGE_URL=
ARG OPENSSL_HEADER=53616c7465645f5f
ARG PUBLIC_ECOSYSTEM_BASE_URL=
ARG MODE=DEV
ARG NEXT_PUBLIC_CURRENT_RELEASE=CDPI-PoC

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    NEXT_PUBLIC_MODE=${NEXT_PUBLIC_MODE} \
    NEXT_PUBLIC_BASE_URL=${NEXT_PUBLIC_BASE_URL} \
    NEXT_PUBLIC_ECOSYSTEM_FRONT_END_URL=${NEXT_PUBLIC_ECOSYSTEM_FRONT_END_URL} \
    CRYPTO_PRIVATE_KEY=${CRYPTO_PRIVATE_KEY} \
    NEXT_PUBLIC_PLATFORM_NAME=${NEXT_PUBLIC_PLATFORM_NAME} \
    NEXTAUTH_URL=${NEXTAUTH_URL} \
    NEXTAUTH_SECRET=${NEXTAUTH_SECRET} \
    NEXTAUTH_COOKIE_DOMAIN=${NEXTAUTH_COOKIE_DOMAIN} \
    NEXTAUTH_PROTOCOL=${NEXTAUTH_PROTOCOL} \
    PUBLIC_ALLOW_DOMAIN=${PUBLIC_ALLOW_DOMAIN} \
    NEXT_PUBLIC_ENABLE_APP_LAUNCHER=${NEXT_PUBLIC_ENABLE_APP_LAUNCHER} \
    NEXT_PUBLIC_APP_NAME=${NEXT_PUBLIC_APP_NAME} \
    NEXT_PUBLIC_ENABLE_SOCIAL_LOGIN=${NEXT_PUBLIC_ENABLE_SOCIAL_LOGIN} \
    NEXT_PUBLIC_ENABLE_BILLING_OPTION=${NEXT_PUBLIC_ENABLE_BILLING_OPTION} \
    NEXT_PUBLIC_ACTIVE_THEME=${NEXT_PUBLIC_ACTIVE_THEME} \
    NEXT_PUBLIC_APP_TITLE=${NEXT_PUBLIC_APP_TITLE} \
    NEXT_PUBLIC_FOOTER_TEXT=${NEXT_PUBLIC_FOOTER_TEXT} \
    NEXT_PUBLIC_LOGO_BASE_URL=${NEXT_PUBLIC_LOGO_BASE_URL} \
    NEXT_PUBLIC_ADMIN_PORTAL_CLIENT_ID=${NEXT_PUBLIC_ADMIN_PORTAL_CLIENT_ID} \
    NEXT_PUBLIC_LANDINGPAGE_URL=${NEXT_PUBLIC_LANDINGPAGE_URL} \
    OPENSSL_HEADER=${OPENSSL_HEADER} \
    PUBLIC_ECOSYSTEM_BASE_URL=${PUBLIC_ECOSYSTEM_BASE_URL} \
    MODE=${MODE} \
    NEXT_PUBLIC_CURRENT_RELEASE=${NEXT_PUBLIC_CURRENT_RELEASE}

# Copy only necessary files
COPY package.json pnpm-lock.yaml ./

# Install dependencies
# sonarcloud: disable=ShellScriptExecutionRisk
RUN pnpm install

# Copy the rest of the source code
COPY . .
# COPY .next ./.next
# COPY public ./public
# COPY node_modules ./node_modules


# Build the Next.js application
RUN pnpm run build

# ---------------------
# Production stage
# ---------------------
FROM node:22-alpine AS production

# Create a non-root user
# RUN groupadd -r appgroup && useradd -r -g appgroup appuser
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
# Set working directory
WORKDIR /app

# Copy necessary build artifacts from build stage
COPY --from=build /app/package.json ./
COPY --from=build /app/.next ./.next
COPY --from=build /app/public ./public
COPY --from=build /app/node_modules ./node_modules

# Change ownership to non-root user
RUN chown -R appuser:appgroup /app

# Switch to non-root user
USER appuser

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

# Expose port
EXPOSE 3000

# Start the Next.js application
CMD ["npm", "start", "--", "-H", "0.0.0.0", "-p", "3000"]
