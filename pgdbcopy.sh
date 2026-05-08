#!/usr/bin/env zsh

# =============================================================================
# dbcopy.sh — Bulk copy tables from a remote PostgreSQL DB to a local one
# =============================================================================

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
EXPORT_DIR="${SCRIPT_DIR}/exports"

LOCAL_HOST="localhost"
LOCAL_PORT="5432"

# -----------------------------------------------------------------------------
# Usage / argument parsing
# -----------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") --dsn <remote_dsn> --ruser <remote_user> --rpass <remote_pass> --luser <local_user> --lpass <local_pass> --schema <schema> --tables <table1> [table2 ...]

Arguments:
  --dsn       Remote PostgreSQL connection string (e.g. myhost.example.com:5432/mydb)
              Accepts host:port/db
  --ruser     Remote DB username
  --rpass     Remote DB password
  --luser     Local DB username
  --lpass     Local DB password
  --schema    Schema name (used on both remote and local DBs)
  --tables    One or more table names to copy (space-separated, must come last
              OR be repeated: --tables t1 --tables t2)

Example:
  $(basename "$0") --dsn db.example.com:5432/mydb \\
                   --ruser remoteuser --rpass remotepass \\
                   --luser mylocaladmin --lpass mylocalpass \\
                   --schema public --tables orders customers
EOF
  exit 1
}

# Parse arguments
REMOTE_DSN=""
REMOTE_USER=""
REMOTE_PASS=""
LOCAL_USER=""
LOCAL_PASS=""
SCHEMA=""
TABLES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dsn)    REMOTE_DSN="$2";  shift 2 ;;
    --ruser)  REMOTE_USER="$2"; shift 2 ;;
    --rpass)  REMOTE_PASS="$2"; shift 2 ;;
    --luser)  LOCAL_USER="$2";  shift 2 ;;
    --lpass)  LOCAL_PASS="$2";  shift 2 ;;
    --schema) SCHEMA="$2";      shift 2 ;;
    --tables)
      shift
      # Collect all remaining positional-looking values as table names
      while [[ $# -gt 0 && "$1" != --* ]]; do
        TABLES+=("$1")
        shift
      done
      ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "$REMOTE_DSN" || -z "$REMOTE_USER" || -z "$REMOTE_PASS" || -z "$LOCAL_USER" || -z "$LOCAL_PASS"|| -z "$SCHEMA" || ${#TABLES[@]} -eq 0 ]] && usage

# -----------------------------------------------------------------------------
# Build connection strings
# -----------------------------------------------------------------------------

# Treat as host:port/db
REMOTE_HOST="${REMOTE_DSN%%/*}"
REMOTE_DB="${REMOTE_DSN##*/}"
REMOTE_PORT_PART="${REMOTE_HOST##*:}"
REMOTE_HOST_ONLY="${REMOTE_HOST%%:*}"
if [[ "$REMOTE_HOST_ONLY" == "$REMOTE_PORT_PART" ]]; then
  # No port specified
  REMOTE_DSN="postgresql://${REMOTE_USER}:${REMOTE_PASS}@${REMOTE_HOST_ONLY}/${REMOTE_DB}?sslmode=require"
else
  REMOTE_DSN="postgresql://${REMOTE_USER}:${REMOTE_PASS}@${REMOTE_HOST_ONLY}:${REMOTE_PORT_PART}/${REMOTE_DB}?sslmode=require"
fi

LOCAL_DSN="postgresql://${LOCAL_USER}:${LOCAL_PASS}@${LOCAL_HOST}:${LOCAL_PORT}/${REMOTE_DB}"

# Convenience wrappers
# run_local() { psql --no-password -d "$LOCAL_DSN" "$@"; } 
# the above line is the syntax for no-password connection if we ever need that back on
run_local() { psql -d "$LOCAL_DSN" "$@"; }
run_remote() { psql -d "$REMOTE_DSN" "$@"; }

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------

info()  { print -P "%F{cyan}[INFO]%f  $*"; }
ok()    { print -P "%F{green}[OK]%f    $*"; }
warn()  { print -P "%F{yellow}[WARN]%f  $*"; }
error() { print -P "%F{red}[ERROR]%f $*" >&2; }
abort() { error "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Ensure export directory exists
# -----------------------------------------------------------------------------

mkdir -p "$EXPORT_DIR"

# =============================================================================
# STEP 1 — Local DB connectivity + schema check
# =============================================================================

info "Connecting to local DB at ${LOCAL_HOST}:${LOCAL_PORT} …"
if ! run_local -c '\q' &>/dev/null; then
  abort "Cannot connect to local PostgreSQL at ${LOCAL_HOST}:${LOCAL_PORT}. Is it running?"
fi
ok "Local DB connection successful."

info "Checking for schema '${SCHEMA}' in local DB …"
LOCAL_SCHEMA_EXISTS=$(run_local -tAc \
  "SELECT 1 FROM information_schema.schemata WHERE schema_name = '${SCHEMA}';")
if [[ "$LOCAL_SCHEMA_EXISTS" != "1" ]]; then
  abort "Schema '${SCHEMA}' does not exist in the local DB. Create it first."
fi
ok "Schema '${SCHEMA}' found in local DB."

# =============================================================================
# STEP 2 — Remote DB connectivity + schema check
# =============================================================================

info "Connecting to remote DB at ${REMOTE_USER}:********@${REMOTE_HOST_ONLY}:${REMOTE_PORT_PART}/${REMOTE_DB}?sslmode=require"
if ! run_remote -c '\q' &>/dev/null; then
  abort "Cannot connect to remote PostgreSQL. Check --dsn, --user, and --pass."
fi
ok "Remote DB connection successful."

info "Checking for schema '${SCHEMA}' in remote DB …"
REMOTE_SCHEMA_EXISTS=$(run_remote -tAc \
  "SELECT 1 FROM information_schema.schemata WHERE schema_name = '${SCHEMA}';")
if [[ "$REMOTE_SCHEMA_EXISTS" != "1" ]]; then
  abort "Schema '${SCHEMA}' does not exist in the remote DB."
fi
ok "Schema '${SCHEMA}' found in remote DB."

# =============================================================================
# STEP 3 — Per-table processing
# =============================================================================

for TABLE in "${TABLES[@]}"; do
  print ""
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Processing table: ${SCHEMA}.${TABLE}"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  SQL_FILE="${EXPORT_DIR}/${SCHEMA}.${TABLE}.sql"
  CSV_FILE="${EXPORT_DIR}/${SCHEMA}.${TABLE}.csv"

  # -------------------------------------------------------------------
  # 3a. Confirm table exists on remote
  # -------------------------------------------------------------------

  TABLE_EXISTS=$(run_remote -tAc \
    "SELECT 1 FROM information_schema.tables
     WHERE table_schema = '${SCHEMA}' AND table_name = '${TABLE}';")

  if [[ "$TABLE_EXISTS" != "1" ]]; then
    error "Table '${SCHEMA}.${TABLE}' not found on remote DB — skipping."
    continue
  fi
  ok "Table '${SCHEMA}.${TABLE}' confirmed on remote."

  # -------------------------------------------------------------------
  # 3b. Generate CREATE TABLE DDL (columns + indexes, no FKs)
  # -------------------------------------------------------------------

  info "Generating DDL for '${SCHEMA}.${TABLE}' …"

  # Build column definitions
  COLUMNS_DDL=$(run_remote -tAc "
SELECT string_agg(col_def, E',\n    ' ORDER BY ordinal_position)
FROM (
  SELECT
    ordinal_position,
    '\"' || column_name || '\" ' ||
    CASE
      WHEN data_type = 'character varying' THEN 'VARCHAR(' || character_maximum_length || ')'
      WHEN data_type = 'character'         THEN 'CHAR(' || character_maximum_length || ')'
      WHEN data_type = 'numeric'           THEN 'NUMERIC(' || numeric_precision || ',' || numeric_scale || ')'
      WHEN data_type = 'USER-DEFINED'      THEN udt_schema || '.' || udt_name
      ELSE data_type
    END ||
    CASE WHEN is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END ||
    CASE
      WHEN column_default IS NOT NULL
           AND column_default NOT LIKE 'nextval(%'  -- handled by SERIAL/IDENTITY
        THEN ' DEFAULT ' || column_default
      ELSE ''
    END AS col_def
  FROM information_schema.columns
  WHERE table_schema = '${SCHEMA}' AND table_name = '${TABLE}'
) sub;
")

  # Build PRIMARY KEY constraint (if any)
  PK_DDL=$(run_remote -tAc "
SELECT
  CASE WHEN count(*) > 0
    THEN E',\n    CONSTRAINT \"' || max(tc.constraint_name) || '\" PRIMARY KEY (' ||
         string_agg('\"' || kcu.column_name || '\"', ', ' ORDER BY kcu.ordinal_position) || ')'
    ELSE ''
  END
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name
 AND tc.table_schema    = kcu.table_schema
WHERE tc.constraint_type = 'PRIMARY KEY'
  AND tc.table_schema    = '${SCHEMA}'
  AND tc.table_name      = '${TABLE}';
")

  # Build index statements (non-PK)
  INDEXES_DDL=$(run_remote -tAc "
SELECT string_agg(indexdef || ';', E'\n')
FROM pg_indexes
WHERE schemaname = '${SCHEMA}'
  AND tablename  = '${TABLE}'
  AND indexname  NOT IN (
    SELECT constraint_name
    FROM information_schema.table_constraints
    WHERE constraint_type = 'PRIMARY KEY'
      AND table_schema    = '${SCHEMA}'
      AND table_name      = '${TABLE}'
  );
")

  # Write the SQL file
  {
    echo "-- Auto-generated by dbcopy.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "-- Remote table: ${SCHEMA}.${TABLE}"
    echo ""
    echo "CREATE TABLE IF NOT EXISTS \"${SCHEMA}\".\"${TABLE}\" ("
    echo "    ${COLUMNS_DDL}${PK_DDL}"
    echo ");"
    if [[ -n "$INDEXES_DDL" && "$INDEXES_DDL" != "" ]]; then
      echo ""
      echo "-- Indexes"
      echo "$INDEXES_DDL"
    fi
  } > "$SQL_FILE"

  ok "DDL written to: ${SQL_FILE}"

  # -------------------------------------------------------------------
  # 3c. Bulk export from remote into CSV
  # -------------------------------------------------------------------

  info "Exporting '${SCHEMA}.${TABLE}' from remote to CSV …"
  run_remote -c "\COPY \"${SCHEMA}\".\"${TABLE}\" TO '${CSV_FILE}' WITH (FORMAT CSV, HEADER true, NULL '');"
  ok "Data exported to: ${CSV_FILE}"

  # -------------------------------------------------------------------
  # 3d. Handle existing local table — backup then drop old backup
  # -------------------------------------------------------------------

  BACKUP_TABLE="${TABLE}_backup"

  # Drop stale backup if present
  BACKUP_EXISTS=$(run_local -tAc \
    "SELECT 1 FROM information_schema.tables
     WHERE table_schema = '${SCHEMA}' AND table_name = '${BACKUP_TABLE}';")
  if [[ "$BACKUP_EXISTS" == "1" ]]; then
    info "Dropping existing backup table '${SCHEMA}.${BACKUP_TABLE}' …"
    run_local -c "DROP TABLE \"${SCHEMA}\".\"${BACKUP_TABLE}\";"
    ok "Backup table dropped."
  fi

  # Drop indexes (including primary key) from current local table before rename
  LOCAL_TABLE_PRE=$(run_local -tAc \
    "SELECT 1 FROM information_schema.tables
     WHERE table_schema = '${SCHEMA}' AND table_name = '${TABLE}';")

  if [[ "$LOCAL_TABLE_PRE" == "1" ]]; then
    info "Dropping indexes from '${SCHEMA}.${TABLE}' before rename …"

    # Drop constraint-backed indexes (PRIMARY KEY, UNIQUE) via ALTER TABLE DROP CONSTRAINT
    CONSTRAINTS_TO_DROP=$(run_local -tAc "
SELECT constraint_name
FROM information_schema.table_constraints
WHERE table_schema   = '${SCHEMA}'
  AND table_name     = '${TABLE}'
  AND constraint_type IN ('PRIMARY KEY', 'UNIQUE');")

    while IFS= read -r con; do
      [[ -z "$con" ]] && continue
      run_local -c "ALTER TABLE \"${SCHEMA}\".\"${TABLE}\" DROP CONSTRAINT \"${con}\";"
      ok "Constraint '${con}' dropped."
    done <<< "$CONSTRAINTS_TO_DROP"

    # Drop remaining standalone (non-constraint) indexes
    INDEXES_TO_DROP=$(run_local -tAc "
SELECT indexname
FROM pg_indexes
WHERE schemaname = '${SCHEMA}'
  AND tablename  = '${TABLE}'
  AND indexname NOT IN (
      SELECT constraint_name
      FROM information_schema.table_constraints
      WHERE table_schema = '${SCHEMA}'
        AND table_name   = '${TABLE}'
  );")

    while IFS= read -r idx; do
      [[ -z "$idx" ]] && continue
      run_local -c "DROP INDEX \"${SCHEMA}\".\"${idx}\";"
      ok "Index '${idx}' dropped."
    done <<< "$INDEXES_TO_DROP"
  fi

  # Rename current local table to backup (if it exists)
  LOCAL_TABLE_EXISTS=$(run_local -tAc \
    "SELECT 1 FROM information_schema.tables
     WHERE table_schema = '${SCHEMA}' AND table_name = '${TABLE}';")
  if [[ "$LOCAL_TABLE_EXISTS" == "1" ]]; then
    info "Renaming local '${SCHEMA}.${TABLE}' → '${SCHEMA}.${BACKUP_TABLE}' …"
    run_local -c "ALTER TABLE \"${SCHEMA}\".\"${TABLE}\" RENAME TO \"${BACKUP_TABLE}\";"
    ok "Local table backed up."
  fi

  # -------------------------------------------------------------------
  # 3e. Create local table + bulk load from CSV
  # -------------------------------------------------------------------

  info "Creating table '${SCHEMA}.${TABLE}' on local DB …"
  run_local -f "$SQL_FILE"
  ok "Table created."

  info "Bulk loading data from CSV into local '${SCHEMA}.${TABLE}' …"
  run_local -c "\COPY \"${SCHEMA}\".\"${TABLE}\" FROM '${CSV_FILE}' WITH (FORMAT CSV, HEADER true, NULL '');"
  ok "Data loaded successfully into '${SCHEMA}.${TABLE}'."

  # Minor security improvement, make all the exported CSV files with possibly prod data only accessible by the owner
  chmod 700 ${EXPORT_DIR}
  chmod 600 ${EXPORT_DIR}/*
done

print ""
ok "All done. ✓"
