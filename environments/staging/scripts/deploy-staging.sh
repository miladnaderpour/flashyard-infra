#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/data/flashyard/staging"
LOG_DIR="/data/flashyard/logs"
LOG_FILE="${LOG_DIR}/deploy-staging.log"
ROLLBACK_ENV="${APP_DIR}/.env.rollback"
HEALTH_URL="http://localhost:8000/api/v1/version"
IMAGE_RETENTION="72h"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -Is)] $*"
}

save_last_known_good() {
    log "Saving last-known-good running images"
    
    BACKEND_IMAGE_ID="$(docker compose images -q backend || true)"
    FRONTEND_IMAGE_ID="$(docker compose images -q frontend || true)"
    
    if [[ -z "$BACKEND_IMAGE_ID" || -z "$FRONTEND_IMAGE_ID" ]]; then
        log "No existing backend/frontend image IDs found. Skipping rollback snapshot."
        return 0
    fi
    
  cat > "$ROLLBACK_ENV" <<EOF
BACKEND_IMAGE=${BACKEND_IMAGE_ID}
FRONTEND_IMAGE=${FRONTEND_IMAGE_ID}
EOF
    
    log "Saved rollback image IDs:"
    log "Backend: ${BACKEND_IMAGE_ID}"
    log "Frontend: ${FRONTEND_IMAGE_ID}"
}

rollback() {
    log "Deployment failed. Rolling back to last-known-good images..."
    
    cd "$APP_DIR"
    
    if [[ ! -f "$ROLLBACK_ENV" ]]; then
        log "Rollback file not found: $ROLLBACK_ENV"
        log "Cannot rollback automatically."
        docker compose ps || true
        exit 1
    fi
    
    docker compose --env-file .env --env-file "$ROLLBACK_ENV" up -d backend frontend
    
    log "Rollback completed. Container status:"
    docker compose ps || true
}

trap rollback ERR

{
    log "========================================"
    log "Staging deployment started"
    log "Host: $(hostname)"
    
    cd "$APP_DIR"
    
    log "Current container status before deploy"
    docker compose ps || true
    
    save_last_known_good
    
    log "Login to GHCR"
    echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
    
    log "Pull images"
    docker compose pull
    
    log "Start database"
    docker compose up -d db
    
    log "Waiting for database"
    until docker compose exec -T db pg_isready -U flashyard_user -d flashyard_staging; do
        log "Database not ready yet..."
        sleep 2
    done
    
    log "Run Alembic migrations"
    docker compose run --rm backend alembic upgrade head
    
    log "Start application services"
    docker compose up -d
    
    log "Basic health check"
    
    for i in {1..20}; do
        if curl -fsS "$HEALTH_URL" | grep -q '"ok":true'; then
            log "Health check passed"
            break
        fi
        
        if [[ "$i" -eq 20 ]]; then
            log "Health check failed after 20 attempts"
            exit 1
        fi
        
        log "Health check attempt ${i}/20 failed. Retrying..."
        sleep 3
    done
    
    log "Cleanup unused images older than ${IMAGE_RETENTION}"
    docker image prune -a -f --filter "until=${IMAGE_RETENTION}"
    
    log "Final container status"
    docker compose ps
    
    log "Staging deployment finished successfully"
    log "========================================"
    
} >> "$LOG_FILE" 2>&1
