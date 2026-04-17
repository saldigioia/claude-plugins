#!/usr/bin/env bash
# Dump the schema of a SQLite database in a readable format
# Usage: db-schema.sh <database-path> [table-name]

set -euo pipefail

DB_PATH="${1:?Usage: db-schema.sh <database-path> [table-name]}"

if [ ! -f "$DB_PATH" ]; then
  echo "Error: Database not found: $DB_PATH"
  exit 1
fi

if ! command -v sqlite3 &> /dev/null; then
  echo "Error: sqlite3 is not installed"
  exit 1
fi

TABLE="${2:-}"

# Validate table name to prevent SQL injection
if [ -n "$TABLE" ]; then
  if ! echo "$TABLE" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
    echo "Error: Invalid table name: $TABLE"
    echo "Table names must contain only letters, digits, and underscores."
    exit 1
  fi
fi

echo "Database: $DB_PATH"
echo "Size: $(du -h "$DB_PATH" | cut -f1)"
echo "---"

if [ -n "$TABLE" ]; then
  # Single table schema + info
  echo ""
  echo "Table: $TABLE"
  echo ""
  sqlite3 "$DB_PATH" ".schema $TABLE"
  echo ""
  echo "Columns:"
  sqlite3 -header -column "$DB_PATH" "PRAGMA table_info($TABLE);"
  echo ""
  echo "Row count:"
  sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM $TABLE;"
  echo ""
  echo "Indexes:"
  sqlite3 "$DB_PATH" "PRAGMA index_list($TABLE);"
else
  # All tables
  echo ""
  echo "Tables:"
  sqlite3 "$DB_PATH" ".tables"
  echo ""

  # Schema for each table
  TABLES=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")

  while IFS= read -r T; do
    [ -z "$T" ] && continue
    echo "--- $T ---"
    sqlite3 "$DB_PATH" ".schema $T"
    ROW_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM \"$T\";")
    echo "  ($ROW_COUNT rows)"
    echo ""
  done <<< "$TABLES"

  # Indexes
  INDEX_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%';")
  if [ "$INDEX_COUNT" -gt 0 ]; then
    echo "--- Indexes ---"
    sqlite3 "$DB_PATH" "SELECT name, tbl_name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY tbl_name, name;"
    echo ""
  fi

  # Foreign keys status
  FK_STATUS=$(sqlite3 "$DB_PATH" "PRAGMA foreign_keys;")
  echo "Foreign keys enabled: $FK_STATUS"

  # Integrity check
  echo ""
  echo "Integrity: $(sqlite3 "$DB_PATH" "PRAGMA integrity_check;" | head -1)"
fi
