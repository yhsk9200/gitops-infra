#!/usr/bin/env bash
# platform-backup.sh — create a verified local backup set for the platform.
#
# Scope (post-ADR-0006, Harbor removed; post-ADR-0008, MLflow added): the
# only non-reconstructible stateful artifacts are keycloak_db and mlflow_db
# (ADR-0008). Everything else is recoverable from GitHub (GitOps manifests +
# SealedSecrets) plus the SealedSecret plaintext held in a password manager
# (the reseal recovery path). MLflow's own artifacts (model files, run
# outputs) live on MinIO@NAS — the same NAS this backup set is exported to
# (runbook "NAS 반출") — not on this cluster, so they are out of scope for
# this script; NAS-side retention is a separate concern. This script
# therefore backs up:
#   - PostgreSQL keycloak_db, mlflow_db   (pg_dump -Fc, one file each)
#   - the GitOps commit the cluster is running
#   - a manifest.yaml + SHA256 checksums over the whole set
# It is READ-ONLY against the cluster (pg_dump / get secret only) — safe to run
# at any time; it never mutates cluster state.
#
# It deliberately does NOT dump the sealed-secrets controller key: that is the
# single most dangerous artifact, and the default recovery path is reseal from
# the password-manager plaintext. Backing the key up (to skip reseal) is an
# OPTIONAL, deliberate, encrypted step — see the runbook section "컨트롤러 키".
#
# Usage:
#   ./platform-backup.sh [BACKUP_ROOT]
#     BACKUP_ROOT   base dir for backup sets (default: /opt/platform-backups)
#   Env overrides:  REPO_DIR (git checkout for the commit ref), RETAIN (keep N).
#
# Requires: kubectl (kubeconfig for the target cluster), sha256sum, and — for
# the commit ref — a git checkout of this repo.

set -euo pipefail

# --- config ---------------------------------------------------------------
NS_DB="platform-db"
PG_POD="platform-db-postgres-postgresql-0"
PG_CONTAINER="postgresql"
PG_SECRET="postgres-db-secret"
BACKUP_DBS=("keycloak_db" "mlflow_db")     # ADR-0008: mlflow_db joins keycloak_db
BACKUP_BASE="${1:-/opt/platform-backups}"
RETAIN="${RETAIN:-7}"                      # keep the newest N sets locally
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

log()  { printf '\033[36m[backup]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[backup:ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl   >/dev/null || die "kubectl not found"
command -v sha256sum >/dev/null || die "sha256sum not found"

# --- preflight ------------------------------------------------------------
kubectl get pod "$PG_POD" -n "$NS_DB" >/dev/null 2>&1 \
  || die "postgres pod $NS_DB/$PG_POD not found (is the cluster up?)"

STAMP="$(date +%Y%m%d-%H%M%S)"
SET_DIR="$BACKUP_BASE/$STAMP"
mkdir -p "$SET_DIR/postgres" "$SET_DIR/gitops"
log "backup set: $SET_DIR"

# --- gitops commit ref ----------------------------------------------------
if git -C "$REPO_DIR" rev-parse HEAD >/dev/null 2>&1; then
  git -C "$REPO_DIR" rev-parse HEAD > "$SET_DIR/gitops/commit.txt"
else
  echo "unknown (no git checkout at $REPO_DIR)" > "$SET_DIR/gitops/commit.txt"
fi
GIT_COMMIT="$(cat "$SET_DIR/gitops/commit.txt")"

# --- postgres db dumps ------------------------------------------------------
# Loop over BACKUP_DBS: dump each database and verify it's a readable
# archive. A DB that's missing/unreadable is a hard failure (die), not a
# skip — a backup run that silently drops a target looks green while
# quietly losing coverage, which is worse than a loud failure.
PGPW="$(kubectl get secret "$PG_SECRET" -n "$NS_DB" -o jsonpath='{.data.postgres-password}' | base64 -d)"
[ -n "$PGPW" ] || die "could not read postgres password from secret $PG_SECRET"

for db in "${BACKUP_DBS[@]}"; do
  log "dumping $db ..."
  DUMP="$SET_DIR/postgres/${db}.dump"
  if ! kubectl exec -n "$NS_DB" "$PG_POD" -c "$PG_CONTAINER" -- \
         env PGPASSWORD="$PGPW" pg_dump -U postgres -d "$db" -Fc > "$DUMP"; then
    unset PGPW
    die "pg_dump failed for $db"
  fi
  if [ ! -s "$DUMP" ]; then
    unset PGPW
    die "dump file is empty: $DUMP"
  fi

  # verify the dump is a readable custom-format archive (list its TOC)
  if ! kubectl exec -i -n "$NS_DB" "$PG_POD" -c "$PG_CONTAINER" -- \
         pg_restore --list < "$DUMP" > /dev/null 2>&1; then
    unset PGPW
    die "pg_restore --list failed for $db — dump is not a readable archive"
  fi
  log "dump ok: $db ($(du -h "$DUMP" | cut -f1))"
done
unset PGPW

# --- manifest -------------------------------------------------------------
{
  cat <<EOF
backup_id: "$STAMP"
created_at: "$(date -Iseconds)"
cluster: "platform-infra"
mode: "local-backup-set-with-manual-nas-export"
git_commit: "$GIT_COMMIT"
targets:
EOF
  for db in "${BACKUP_DBS[@]}"; do
    cat <<EOF
  ${db}:
    namespace: "$NS_DB"
    pod: "$PG_POD"
    file: "postgres/${db}.dump"
    method: "pg_dump -Fc"
EOF
  done
  cat <<EOF
notes:
  - "sealed-secrets controller key is NOT in this set (reseal-primary recovery)."
  - "SealedSecret plaintext custody = password manager (out of band)."
  - "product-pulse tenant is stateless — no backup target."
  - "MLflow artifacts (models/run outputs) live on MinIO@NAS, not this script's scope (ADR-0008)."
included:
EOF
  for db in "${BACKUP_DBS[@]}"; do
    echo "  - \"postgres/${db}.dump\""
  done
  echo '  - "gitops/commit.txt"'
} > "$SET_DIR/manifest.yaml"

# --- checksums ------------------------------------------------------------
( cd "$SET_DIR" && find . -type f ! -name checksums.sha256 -print0 \
    | sort -z | xargs -0 sha256sum > checksums.sha256 )
( cd "$SET_DIR" && sha256sum -c checksums.sha256 >/dev/null ) \
  || die "checksum verification failed"
log "checksums verified"

# --- local retention ------------------------------------------------------
if [ "$RETAIN" -gt 0 ]; then
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    log "retention: removing old set $old"
    rm -rf "$old"
  done < <(ls -1dt "$BACKUP_BASE"/*/ 2>/dev/null | tail -n +"$((RETAIN + 1))")
fi

# --- summary --------------------------------------------------------------
log "DONE  $SET_DIR"
cat <<EOF

  next steps (manual boundary — this script stops here on purpose):
    1. re-verify anytime:  sha256sum -c "$SET_DIR/checksums.sha256"
    2. export the set to the air-gapped NAS (runbook: "NAS 반출")
    3. OPTIONAL, only if you want key-restore recovery instead of reseal:
       back up the sealed-secrets controller key per the runbook and keep it
       encrypted — it is the most sensitive artifact in the whole platform.
EOF
