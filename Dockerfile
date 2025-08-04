# Dockerfile - Optimized for production
FROM node:18-alpine AS builder

# Set working directory
WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies (including dev dependencies for build)
RUN npm ci --include=dev

# Copy source code
COPY . .

# Remove dev dependencies and clean npm cache
RUN npm prune --production && npm cache clean --force

# Production stage
FROM node:18-alpine AS production

# Install dumb-init for proper signal handling
RUN apk add --no-cache dumb-init

# Create app user for security
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodeuser -u 1001

# Set working directory
WORKDIR /app

# Copy built application from builder stage
COPY --from=builder --chown=nodeuser:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nodeuser:nodejs /app/package*.json ./
COPY --chown=nodeuser:nodejs server.js setup-database.js ./
COPY --chown=nodeuser:nodejs public ./public

# Create data directory with proper permissions
RUN mkdir -p /app/data /app/logs && \
    chown -R nodeuser:nodejs /app/data /app/logs

# Switch to non-root user
USER nodeuser

# Expose port
EXPOSE 3000

# Add labels for better management
LABEL maintainer="your-team@company.com"
LABEL version="1.0"
LABEL description="Patient Data Collection API"

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/health', (res) => { process.exit(res.statusCode === 200 ? 0 : 1) })"

# Use dumb-init to handle signals properly
ENTRYPOINT ["dumb-init", "--"]

# Start the application
CMD ["node", "server.js"]

