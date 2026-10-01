#!/usr/bin/env bash
set -euo pipefail

# Load .env into the shell (for variable substitution used below)
set -a; . ./.env; set +a

: "${POSTGRESQL_USER:?Set POSTGRESQL_USER in .env}"
: "${POSTGRESQL_PASSWORD:?Set POSTGRESQL_PASSWORD in .env}"
: "${POSTGRESQL_ADMIN_PASSWORD:?Set POSTGRESQL_ADMIN_PASSWORD in .env}"
POSTGRESQL_DATABASE="${POSTGRESQL_DATABASE:-aap_migration}"
AAP_BRIDGE_LOG_LEVEL="${AAP_BRIDGE_LOG_LEVEL:-INFO}"

# ---------- Build images (skip if already built) ----------
#podman build -t localhost/aap-bridge-api:latest -f Containerfile --target api .
#podman build -t localhost/aap-bridge-ui:latest  -f Containerfile.ui .
# only needed for the optional "bridge" container:
# podman build -t localhost/aap-bridge-dev:latest -f Containerfile.dev .

# ---------- Network, volume, host dirs ----------
podman network exists aap-bridge || podman network create aap-bridge
podman volume exists pgdata      || podman volume create pgdata
mkdir -p exports xformed reports logs schemas tests/integration/generated

# ---------- db-init (one-shot) ----------
podman run --rm --user 0 \
  -v pgdata:/var/lib/pgsql/data \
  registry.redhat.io/ubi9/ubi-minimal:latest \
  /bin/sh -ec 'mkdir -p /var/lib/pgsql/data && chown -R 26:26 /var/lib/pgsql/data'

# ---------- db ----------
podman run -d --name db --network aap-bridge \
  -p 15432:5432 \
  -e POSTGRESQL_USER \
  -e POSTGRESQL_PASSWORD \
  -e POSTGRESQL_DATABASE \
  -e POSTGRESQL_ADMIN_PASSWORD \
  -v pgdata:/var/lib/pgsql/data \
  --health-cmd "pg_isready -U ${POSTGRESQL_USER} -d ${POSTGRESQL_DATABASE}" \
  --health-interval 5s --health-timeout 5s --health-retries 10 \
  registry.redhat.io/rhel9/postgresql-15

# equivalent of depends_on: service_healthy
podman wait --condition=healthy db

# ---------- engine ----------
podman run -d --name engine --network host \
  --userns=keep-id:uid=998,gid=998 \
  --security-opt label=disable \
  --env-file .env \
  -e MIGRATION_STATE_DB_PATH="postgresql://${POSTGRESQL_USER}:${POSTGRESQL_PASSWORD}@localhost:15432/${POSTGRESQL_DATABASE}" \
  -e AAP_BRIDGE_CONFIG=/app/config/config.yaml \
  -e AAP_BRIDGE_LOG_LEVEL="${AAP_BRIDGE_LOG_LEVEL}" \
  -v "$PWD/config:/app/config:ro" \
  -v "$PWD/exports:/app/exports" \
  -v "$PWD/xformed:/app/xformed" \
  -v "$PWD/reports:/app/reports" \
  -v "$PWD/schemas:/app/schemas" \
  quay.io/rh-ee-aamarull/aap-bridge-api:v1

# ---------- ui ----------
podman run -d --name ui --network host \
  quay.io/rh-ee-aamarull/aap-bridge-ui:v1
