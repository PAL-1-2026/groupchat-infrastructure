#!/bin/bash
# deploy.sh - place this file at ~/deploy.sh on EC2.
#
# Usage:
#   bash ~/deploy.sh build-42-a3f9c1b backend
#   bash ~/deploy.sh build-42-a3f9c1b frontend
#   bash ~/deploy.sh postgres

set -e

AWS_REGION="us-east-1"
ECR_REGISTRY="801534266905.dkr.ecr.${AWS_REGION}.amazonaws.com"
COMPOSE_FILE="$HOME/docker-compose.prod.yml"

if [ "$1" = "postgres" ]; then
    IMAGE_TAG=""
    SERVICE="postgres"
else
    IMAGE_TAG=${1:?IMAGE_TAG is required}
    SERVICE=${2:?SERVICE is required: backend, frontend, or postgres}
fi

if [ "${SERVICE}" != "backend" ] && [ "${SERVICE}" != "frontend" ] && [ "${SERVICE}" != "postgres" ]; then
    echo "Invalid service: ${SERVICE}. Use backend, frontend, or postgres."
    exit 1
fi

cd "$(dirname "${COMPOSE_FILE}")"

wait_for_postgres() {
    echo "Waiting for postgres healthcheck..."

    for i in $(seq 1 12); do
        STATUS=$(docker inspect --format='{{.State.Health.Status}}' \
            "$(docker compose -f "${COMPOSE_FILE}" ps -q postgres)" 2>/dev/null || echo "unknown")

        if [ "${STATUS}" = "healthy" ]; then
            echo "Postgres is healthy after $((i * 5)) seconds."
            return 0
        fi

        sleep 5
    done

    echo "Postgres did not become healthy after 60 seconds."
    docker compose -f "${COMPOSE_FILE}" logs --tail=100 postgres || true
    return 1
}

if [ "${SERVICE}" = "postgres" ]; then
    echo "===== Deploy postgres ====="
    docker compose -f "${COMPOSE_FILE}" up -d postgres
    wait_for_postgres
    exit 0
fi

echo "===== Deploy ${SERVICE} - tag: ${IMAGE_TAG} ====="

if [ "${SERVICE}" = "backend" ]; then
    docker compose -f "${COMPOSE_FILE}" up -d postgres
    wait_for_postgres
fi

# 1. Login to ECR.
aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# 2. Save previous image for rollback.
PREV_IMAGE=$(docker inspect --format='{{index .RepoDigests 0}}' \
    "${ECR_REGISTRY}/kabw-groupchat/${SERVICE}:latest" 2>/dev/null || echo "")

# 3. Pull new image.
docker pull "${ECR_REGISTRY}/kabw-groupchat/${SERVICE}:${IMAGE_TAG}"

# 4. Tag as latest.
docker tag "${ECR_REGISTRY}/kabw-groupchat/${SERVICE}:${IMAGE_TAG}" \
           "${ECR_REGISTRY}/kabw-groupchat/${SERVICE}:latest"

# 5. Restart selected service only. Dependencies are handled explicitly above.
docker compose -f "${COMPOSE_FILE}" up -d --no-deps "${SERVICE}"

# 6. Simple service health check.
echo "Waiting for container ${SERVICE} to run..."
for i in $(seq 1 12); do
    STATUS=$(docker inspect --format='{{.State.Status}}' \
        "$(docker compose -f "${COMPOSE_FILE}" ps -q "${SERVICE}")" 2>/dev/null || echo "unknown")

    if [ "${STATUS}" = "running" ]; then
        echo "Container ${SERVICE} is running after $((i * 5)) seconds."
        exit 0
    fi

    sleep 5
done

# 7. Rollback if selected service failed.
echo "Container ${SERVICE} failed to run. Rolling back..."
if [ -n "${PREV_IMAGE}" ]; then
    docker pull "${PREV_IMAGE}"
    docker tag "${PREV_IMAGE}" "${ECR_REGISTRY}/kabw-groupchat/${SERVICE}:latest"
    docker compose -f "${COMPOSE_FILE}" up -d --no-deps "${SERVICE}"
    echo "Rollback completed."
else
    echo "No previous image available for rollback."
fi

exit 1
