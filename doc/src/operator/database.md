# Database Backends

kipuka uses a database to store issued certificates, audit logs, OTP tokens, and certificate authority state. Three backend options are supported: SQLite, PostgreSQL, and MariaDB. The database backend is configured via the `[db]` section in `kipuka.toml`.

## SQLite

SQLite is the default backend and requires zero configuration. It is ideal for single-node deployments, development environments, and small to medium workloads.

### URL Format

```toml
[db]
url = "sqlite:///var/lib/kipuka/kipuka.db"
auto_migrate = true
```

For in-memory testing:

```toml
[db]
url = "sqlite://:memory:"
```

### Features and Characteristics

- **Write-Ahead Logging (WAL)**: kipuka enables WAL mode by default, allowing concurrent reads while a write transaction is in progress.
- **File Permissions**: The database file should be owned by the kipuka service user with mode 0600 to prevent unauthorized access.
- **Single-Writer**: SQLite supports only one concurrent writer. This is not a limitation for single-node deployments but makes it unsuitable for high-availability configurations with shared state.
- **No Network Access**: The database must be on the local filesystem. Network-mounted filesystems (NFS, SMB) are not recommended due to locking and performance issues.

### Backup

SQLite databases can be backed up using:

- **File copy**: While the WAL is checkpointed (kipuka handles this automatically), the database file can be copied. Use a consistent snapshot method to avoid corruption.
- **sqlite3 .backup**: The SQLite command-line tool provides a `.backup` command for online backups:

  ```bash
  sqlite3 /var/lib/kipuka/kipuka.db ".backup /backup/kipuka-$(date +%Y%m%d).db"
  ```

### Best For

- Single-node deployments
- Development and testing
- Small to medium workloads (< 1000 requests/minute)
- Scenarios where operational simplicity is prioritized

### Limitations

- Single writer (not suitable for multi-node HA with shared state)
- No network access (cannot be shared across nodes)
- Limited to local filesystem performance

## PostgreSQL

PostgreSQL is the recommended backend for production multi-node deployments. It provides robust support for concurrent writes, network access, replication, and point-in-time recovery.

### URL Format

```toml
[db]
url = "postgres://kipuka:secret@db.example.com:5432/kipuka?sslmode=require"
max_connections = 20
connect_timeout = "5s"
auto_migrate = true
```

### Features and Characteristics

- **Concurrent Writes**: Multiple kipuka nodes can write to the database simultaneously.
- **Network Access**: The database can be accessed over the network, enabling multi-node deployments.
- **Replication**: PostgreSQL supports streaming replication for read replicas and high availability.
- **Point-in-Time Recovery (PITR)**: WAL archiving enables recovery to any point in time.
- **Connection Pooling**: kipuka maintains a connection pool sized by `max_connections`.

### Connection Pool Tuning

The `max_connections` setting controls the size of kipuka's connection pool to PostgreSQL:

- **Default**: 5 (suitable for low-load scenarios)
- **Formula**: Start with `workers * 2` and adjust based on monitoring.
- **Too Low**: Connection pool exhaustion under load, causing requests to queue.
- **Too High**: Unnecessary resource consumption; may exceed PostgreSQL's `max_connections` limit (default 100).

Monitor pool utilization via the Admin API endpoint `/admin/health`, which reports connection pool statistics.

### PostgreSQL Configuration

Ensure `max_connections` in `postgresql.conf` is set higher than the sum of all kipuka nodes' `max_connections`. Leave headroom for other applications and administrative connections.

```
# postgresql.conf
max_connections = 100
```

### SSL Connections

Append `?sslmode=require` to the URL to enforce SSL/TLS connections:

```toml
url = "postgres://kipuka:${DB_PASSWORD}@db.example.com:5432/kipuka?sslmode=require"
```

### Best For

- Production environments
- High-availability deployments (with replication)
- High-throughput scenarios (> 1000 requests/minute)
- Multi-node clusters with shared state

## MariaDB

MariaDB is an alternative to PostgreSQL and supports Galera Cluster for synchronous multi-master replication. It is well-suited for organizations already standardized on MariaDB or requiring Galera-based high availability.

### URL Format

```toml
[db]
url = "mysql://kipuka:secret@galera1.example.com:3306/kipuka"
max_connections = 20
connect_timeout = "5s"
auto_migrate = true
```

### Features and Characteristics

- **Galera Cluster**: Provides synchronous multi-master replication, allowing writes to any node in the cluster.
- **Concurrent Writes**: Multiple kipuka nodes can write to the database simultaneously.
- **Network Access**: The database can be accessed over the network.

### Galera Considerations

- **Replication Format**: Use ROW-based replication (`binlog_format=ROW`) for deterministic replication.
- **Synchronous Reads**: Set `wsrep_sync_wait=1` to ensure reads reflect writes from all nodes (reads-after-writes consistency).

```
# MariaDB Galera configuration
wsrep_sync_wait=1
binlog_format=ROW
```

### Best For

- Organizations standardized on MariaDB
- Galera Cluster-based high availability
- Multi-master replication requirements

## Connection URL Formats Summary

| Backend     | URL Format                           | Default Port |
|-------------|--------------------------------------|--------------|
| SQLite      | `sqlite://path/to/db`                | N/A          |
| PostgreSQL  | `postgres://user:pass@host:port/db`  | 5432         |
| MariaDB     | `mysql://user:pass@host:port/db`     | 3306         |

## Migrations

kipuka uses versioned, idempotent migrations to manage database schema changes. Migrations can be applied automatically on startup or run manually as a separate step.

### Automatic Migrations

Set `auto_migrate = true` (the default) to apply pending migrations on startup:

```toml
[db]
auto_migrate = true
```

This is convenient for development and single-node deployments, but may not be suitable for production environments where migrations should be reviewed and tested before deployment.

### Manual Migrations

Set `auto_migrate = false` to disable automatic migrations:

```toml
[db]
auto_migrate = false
```

Then run migrations manually using the `kipuka migrate` command:

```bash
# Show pending migrations
kipuka migrate status

# Apply pending migrations
kipuka migrate run
```

### Best Practices

- **Production**: Run migrations as a separate step before starting the server. This allows you to review migrations, test them in a staging environment, and coordinate downtime if necessary.
- **Development**: Use `auto_migrate = true` for convenience.
- **Idempotency**: Migrations are idempotent and can be re-run safely. If a migration is interrupted, re-running it will complete the operation.

## max_connections Tuning

The `max_connections` setting controls the size of kipuka's database connection pool. Tuning this parameter is critical for balancing resource utilization and performance.

### Default

The default is `5`, which is suitable for SQLite and small deployments with low concurrency.

### Tuning Formula

Start with the formula:

```
max_connections = workers * 2
```

Adjust based on monitoring and observed load. For example, if kipuka is configured with 4 workers, start with `max_connections = 8`.

### Symptoms of Incorrect Settings

- **Too Low**: Connection pool exhaustion under load. Requests will queue waiting for an available connection, increasing latency.
- **Too High**: Unnecessary resource consumption (memory, file descriptors). May exceed the database's `max_connections` limit, causing connection failures.

### Monitoring

Use the Admin API endpoint `/admin/health` to monitor connection pool utilization:

```bash
curl http://localhost:8080/admin/health
```

The response includes metrics such as active connections, idle connections, and pool size.

### PostgreSQL Configuration

Ensure PostgreSQL's `max_connections` setting is higher than the sum of all kipuka nodes' `max_connections`. For example:

- 3 kipuka nodes, each with `max_connections = 20` → 60 total
- PostgreSQL `max_connections = 100` → 40 connections available for other applications and administrative tasks

## Credential Security

Database connection URLs often contain sensitive credentials (usernames and passwords). Follow these best practices to protect credentials:

### Environment Variable Substitution

kipuka supports environment variable substitution in the `url` field using the `${ENV_VAR}` syntax:

```toml
[db]
url = "postgres://kipuka:${DB_PASSWORD}@db.example.com:5432/kipuka"
```

Set the environment variable before starting kipuka:

```bash
export DB_PASSWORD="your-secure-password"
kipuka run
```

Or use a systemd service file with `EnvironmentFile`:

```ini
[Service]
EnvironmentFile=/etc/kipuka/db.env
ExecStart=/usr/bin/kipuka run
```

### Never Commit Passwords

Never commit plaintext passwords to version control. Use:

- Environment variables (as shown above)
- Secret management systems (e.g., HashiCorp Vault, AWS Secrets Manager)
- Encrypted configuration files with restricted file permissions

### Example: Secrets Manager Integration

For production deployments, consider integrating with a secrets manager:

```bash
# Fetch password from secrets manager
export DB_PASSWORD=$(vault kv get -field=password secret/kipuka/db)

# Start kipuka
kipuka run
```

This ensures credentials are never written to disk in plaintext and can be rotated without modifying configuration files.
