# ═══════════════════════════════════════════════════════
# STAGE 1 — dependencies
# We use a separate stage just to install npm packages
# This way if only source code changes, Docker reuses
# the cached node_modules layer and builds much faster
# ═══════════════════════════════════════════════════════
FROM node:20-alpine AS deps

# alpine = very small Linux image (~5MB vs ~900MB for full Ubuntu)
# This keeps our final image size small

WORKDIR /app

# Copy package files FIRST — before copying source code
# Docker caches each layer. If package.json didn't change,
# Docker skips npm install on the next build (much faster)
COPY package*.json ./

# Install only production dependencies
# --omit=dev skips devDependencies (test libraries, linters, etc.)
RUN npm install --omit=dev

# ═══════════════════════════════════════════════════════
# STAGE 2 — final image
# Copy only what we need from the deps stage
# The final image has no npm cache, no build tools
# ═══════════════════════════════════════════════════════
FROM node:20-alpine AS final

# Add a non-root user for security
# Running as root inside a container is a security risk
# If the app is compromised, the attacker gets root on the container
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy node_modules from the deps stage
COPY --from=deps /app/node_modules ./node_modules

# Copy the application source code
COPY index.js ./

# Copy package.json (needed so Node.js knows the app name and version)
COPY package.json ./

# Give ownership of the /app folder to our non-root user
RUN chown -R appuser:appgroup /app

# Switch to non-root user
USER appuser

# Tell Docker which port this container listens on
# This is documentation — it does not actually open the port
# The port mapping happens in docker-compose.yml
EXPOSE 3001

# Health check: Docker will run this command every 30s
# If it fails 3 times in a row, Docker marks the container as "unhealthy"
# and docker-compose can restart it automatically
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3001/ || exit 1

# Command to start the app when the container launches
CMD ["node", "index.js"]
