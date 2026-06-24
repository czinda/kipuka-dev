# Database Migrations

kipuka manages its database schema through sequential migration files.  Every
schema change is expressed as a migration that runs exactly once on each
database, tracked by a migration history table.

## Migration file layout

Migrations live under `migrations/` with one subdirectory per supported
database backend:

```
migrations/
  sqlite/
    0001_initial_schema.sql
    0002_add_audit_log.sql
    0003_add_cert_inventory.sql
  postgres/
    0001_initial_schema.sql
    0002_add_audit_log.sql
    0003_add_cert_inventory.sql
  mariadb/
    0001_initial_schema.sql
    0002_add_audit_log.sql
    0003_add_cert_inventory.sql
```

### Naming convention

Migration files follow the pattern `NNNN_description.sql` where:

- `NNNN` is a zero-padded sequential number starting at `0001`
- `description` is a lowercase, underscore-separated summary of the change
- The `.sql` extension is required

Examples:

```
0004_add_otp_lockout_columns.sql
0005_create_ha_state_table.sql
0006_add_label_to_certs.sql
```

The numeric prefix determines execution order.  kipuka runs migrations in
ascending order and skips any that have already been applied (tracked in the
`_sqlx_migrations` table).

## Running migrations

### Automatic migration on startup

When `auto_migrate = true` in the `[db]` configuration section, kipuka applies
pending migrations automatically when the server starts:

```toml
[db]
url = "sqlite:///var/lib/kipuka/kipuka.db?mode=rwc"
auto_migrate = true
```

This is convenient for development but may not be appropriate for production
environments where schema changes require review and approval.

### Explicit migration command

Run migrations manually using the `migrate` subcommand:

```bash
kipuka migrate --config kipuka.toml
```

Output:

```
Applied 0001_initial_schema (23ms)
Applied 0002_add_audit_log (11ms)
Applied 0003_add_cert_inventory (15ms)
3 migrations applied successfully
```

If all migrations have already been applied:

```
No pending migrations
```

### Checking migration status

View which migrations have been applied:

```bash
kipuka migrate --config kipuka.toml --status
```

Output:

```
Migration                        Applied At
0001_initial_schema              2026-06-20T10:00:00Z
0002_add_audit_log               2026-06-20T10:00:00Z
0003_add_cert_inventory          2026-06-20T10:00:01Z
0004_add_otp_lockout_columns     (pending)
```

## The three-backend rule

**Every migration must have counterparts for all three database backends.**
A migration that adds a column to a table in SQLite must also add that column
in PostgreSQL and MariaDB.  This ensures that kipuka can be deployed against
any supported backend without schema drift.

The migration runner selects the correct subdirectory based on the database URL
scheme:

| URL scheme | Migration directory |
| ---------- | ------------------- |
| `sqlite://` | `migrations/sqlite/` |
| `postgres://` or `postgresql://` | `migrations/postgres/` |
| `mysql://` or `mariadb://` | `migrations/mariadb/` |

## Creating a new migration

### Step 1: Choose a descriptive name

Pick a name that describes the change, not the ticket number:

```
Good:  0007_add_gssapi_principal_mapping.sql
Bad:   0007_issue_42.sql
```

### Step 2: Write the SQL for each backend

Create three files with the same sequence number and description:

```bash
touch migrations/sqlite/0007_add_gssapi_principal_mapping.sql
touch migrations/postgres/0007_add_gssapi_principal_mapping.sql
touch migrations/mariadb/0007_add_gssapi_principal_mapping.sql
```

Each file contains the DDL for that specific backend.

#### SQLite example

```sql
-- migrations/sqlite/0007_add_gssapi_principal_mapping.sql

CREATE TABLE IF NOT EXISTS gssapi_mappings (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    principal   TEXT NOT NULL UNIQUE,
    subject_dn  TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX idx_gssapi_mappings_principal ON gssapi_mappings(principal);
```

#### PostgreSQL example

```sql
-- migrations/postgres/0007_add_gssapi_principal_mapping.sql

CREATE TABLE IF NOT EXISTS gssapi_mappings (
    id          SERIAL PRIMARY KEY,
    principal   TEXT NOT NULL UNIQUE,
    subject_dn  TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_gssapi_mappings_principal ON gssapi_mappings(principal);
```

#### MariaDB example

```sql
-- migrations/mariadb/0007_add_gssapi_principal_mapping.sql

CREATE TABLE IF NOT EXISTS gssapi_mappings (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    principal   VARCHAR(512) NOT NULL UNIQUE,
    subject_dn  VARCHAR(1024) NOT NULL,
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE INDEX idx_gssapi_mappings_principal ON gssapi_mappings(principal);
```

### Step 3: Update sqlx query metadata

After adding migrations, regenerate the sqlx offline query data so that
compile-time query checking works without a live database:

```bash
cargo sqlx prepare --workspace
```

This updates the `.sqlx/` directory with query metadata for all three
backends.

## Schema differences between backends

While the logical schema is identical across backends, SQL syntax differences
require backend-specific migration files.

### Type mapping

| Logical type | SQLite | PostgreSQL | MariaDB |
| ------------ | ------ | ---------- | ------- |
| Auto-increment PK | `INTEGER PRIMARY KEY AUTOINCREMENT` | `SERIAL PRIMARY KEY` | `INT AUTO_INCREMENT PRIMARY KEY` |
| Timestamp | `TEXT` (ISO 8601 strings) | `TIMESTAMPTZ` | `TIMESTAMP` |
| Variable text | `TEXT` | `TEXT` | `VARCHAR(n)` or `TEXT` |
| Boolean | `INTEGER` (0/1) | `BOOLEAN` | `TINYINT(1)` |
| Binary data | `BLOB` | `BYTEA` | `BLOB` |

### Default value expressions

| Backend | Current timestamp | UUID generation |
| ------- | ----------------- | --------------- |
| SQLite | `strftime('%Y-%m-%dT%H:%M:%SZ', 'now')` | Application-generated |
| PostgreSQL | `NOW()` | `gen_random_uuid()` |
| MariaDB | `CURRENT_TIMESTAMP` | `UUID()` |

### Feature availability

- **PostgreSQL** supports `ON CONFLICT DO UPDATE` (upsert) natively.
- **SQLite** supports `INSERT OR REPLACE` and `ON CONFLICT` (3.24+).
- **MariaDB** uses `INSERT ... ON DUPLICATE KEY UPDATE`.

When writing migrations that use upsert-like behavior, use the
backend-appropriate syntax.

## Rules for migration safety

### Never modify a released migration

Once a migration has been applied to any environment (including other
developers' local databases), it is immutable.  To change an existing table:

1. Create a **new** migration with the next sequence number
2. Use `ALTER TABLE` to modify the schema
3. Provide the new migration for all three backends

### Additive changes only

Prefer adding columns, tables, and indexes.  Avoid dropping columns or tables
unless absolutely necessary.  If a column is no longer used:

1. Stop writing to it in the application code
2. After a release cycle, add a migration to drop the column

### Handle NULL for new columns

When adding a column to an existing table, either provide a `DEFAULT` value or
allow `NULL`.  Existing rows cannot retroactively satisfy a `NOT NULL`
constraint without a default:

```sql
-- Correct: new column with a default
ALTER TABLE otps ADD COLUMN locked_until TEXT DEFAULT NULL;

-- Incorrect: will fail if the table has existing rows
ALTER TABLE otps ADD COLUMN locked_until TEXT NOT NULL;
```

### Test data migration

If a migration transforms existing data (not just schema), include the data
transformation in the same migration file:

```sql
-- Add new column
ALTER TABLE audit_log ADD COLUMN auth_method TEXT DEFAULT 'unknown';

-- Backfill existing rows
UPDATE audit_log SET auth_method = 'mtls' WHERE auth_method = 'unknown';
```

## Testing migrations against all backends

Before committing a new migration, verify it applies cleanly against all three
database backends:

```bash
# SQLite (in-memory)
cargo run -- migrate --config test-sqlite.toml

# PostgreSQL
docker compose --profile postgres up -d
cargo run -- migrate --config test-postgres.toml

# MariaDB
docker compose --profile mariadb up -d
cargo run -- migrate --config test-mariadb.toml
```

The CI pipeline runs migrations against SQLite automatically.  PostgreSQL and
MariaDB migration tests require the corresponding Compose profiles and are
part of the extended test suite.

## Rollback strategy

kipuka migrations are forward-only.  There is no built-in `migrate down`
command.  This is a deliberate design choice: automated rollback of DDL changes
is unreliable in production (data loss, constraint violations, transaction
semantics vary by backend).

### Manual rollback procedure

If a migration must be undone:

1. Write a new forward migration that reverses the change:

   ```sql
   -- 0008_revert_gssapi_mappings.sql
   DROP TABLE IF EXISTS gssapi_mappings;
   ```

2. Apply it normally:

   ```bash
   kipuka migrate --config kipuka.toml
   ```

### Emergency rollback

In an emergency where the server cannot start due to a bad migration:

1. Restore the database from backup
2. Remove the problematic migration files from `migrations/`
3. Restart kipuka

For PostgreSQL and MariaDB, point-in-time recovery (PITR) can restore the
database to the moment before the migration ran.  For SQLite, restore from a
filesystem-level backup.

### Backup before migrating

Always back up the database before applying migrations in production:

```bash
# SQLite
cp /var/lib/kipuka/kipuka.db /var/lib/kipuka/kipuka.db.bak

# PostgreSQL
pg_dump -U kipuka kipuka > kipuka-backup.sql

# MariaDB
mysqldump -u kipuka -p kipuka > kipuka-backup.sql
```
