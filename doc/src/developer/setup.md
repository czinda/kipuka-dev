# Development Setup

This guide covers everything needed to build kipuka from source and run it
locally with Docker Compose.

## Prerequisites

| Tool | Minimum version | Purpose |
| ---- | --------------- | ------- |
| Rust toolchain | **1.88+** | Compiler and cargo |
| Docker or Podman | 24+ / 4+ | Container runtime for Compose profiles |
| Docker Compose | 2.20+ | Orchestrates database and HSM dev containers |
| OpenSSL CLI | 1.1.1+ or 3.x | Generating test certificates |
| pkg-config | any | Locating system libraries during build |

## Clone and build

```bash
git clone https://github.com/czinda/kipuka.git
cd kipuka
cargo build
```

A release-optimized build (slower compilation, faster binary):

```bash
cargo build --release
```

The workspace produces a single binary at `target/debug/kipuka` (or
`target/release/kipuka`).

### OS-specific dependencies

#### Fedora / RHEL / CentOS Stream

```bash
sudo dnf install openssl-devel clang cmake pkg-config sqlite-devel
```

#### Debian / Ubuntu

```bash
sudo apt install libssl-dev clang cmake pkg-config libsqlite3-dev
```

#### macOS

```bash
brew install openssl cmake pkg-config
export OPENSSL_DIR=$(brew --prefix openssl)
```

## Docker Compose profiles

The repository includes a `compose.yaml` with profiles for different database
backends and an HSM development environment.  Each profile starts only the
services relevant to that backend.

### Available profiles

| Profile | Services started | Use case |
| ------- | ---------------- | -------- |
| `sqlite` (default) | kipuka only | Minimal local development; SQLite file on disk |
| `postgres` | kipuka + PostgreSQL 16 | Testing against PostgreSQL |
| `mariadb` | kipuka + MariaDB 11 | Testing against MariaDB |
| `hsm` | kipuka + Kryoptic SoftHSM | PKCS#11 development without hardware |

### Running with SQLite (default)

```bash
docker compose up
```

This starts kipuka with an in-process SQLite database.  No external database
container is required.

### Running with PostgreSQL

```bash
docker compose --profile postgres up
```

The PostgreSQL container is preconfigured with:

- Database: `kipuka`
- User: `kipuka`
- Password: `kipuka-dev`
- Port: `5432`

The kipuka service automatically uses the connection string
`postgres://kipuka:kipuka-dev@postgres:5432/kipuka`.

### Running with MariaDB

```bash
docker compose --profile mariadb up
```

The MariaDB container is preconfigured with:

- Database: `kipuka`
- User: `kipuka`
- Password: `kipuka-dev`
- Port: `3306`

### Running with Kryoptic HSM

```bash
docker compose --profile hsm up
```

This starts a Kryoptic SoftHSM container alongside kipuka.  Kryoptic is an
open-source PKCS#11 implementation written in Rust, suitable for development
and testing.  It provides the same PKCS#11 API as hardware HSMs without
requiring physical tokens.

See the [HSM development section](#hsm-development-with-kryoptic) below for
slot configuration and key management.

## Generate test certificates

The repository includes a helper script that creates a complete test PKI
hierarchy suitable for local development:

```bash
./contrib/local-dev/setup-ca.sh
```

This generates the following files under `contrib/local-dev/pki/`:

| File | Contents |
| ---- | -------- |
| `ca.pem` | Self-signed root CA certificate |
| `ca-key.pem` | Root CA private key |
| `server.pem` | Server TLS certificate (SAN: localhost, 127.0.0.1) |
| `server-key.pem` | Server TLS private key |
| `client.pem` | Client certificate for mTLS testing |
| `client-key.pem` | Client private key |

The script is idempotent -- running it again regenerates all certificates.

## Minimal kipuka.toml for local development

Create a `kipuka.toml` in the repository root:

```toml
[server]
listen = "0.0.0.0:9443"

[tls]
cert = "contrib/local-dev/pki/server.pem"
key = "contrib/local-dev/pki/server-key.pem"

[tls.client_auth]
trust_anchors = "contrib/local-dev/pki/ca.pem"
mode = "optional"

[db]
url = "sqlite://kipuka-dev.db?mode=rwc"
auto_migrate = true

[[ca]]
id = "dev-ca"
name = "Development CA"
cert = "contrib/local-dev/pki/ca.pem"
key = "contrib/local-dev/pki/ca-key.pem"
validity_days = 365

[est]
base_path = "/.well-known/est"

[[est.label]]
name = "default"
ca_id = "dev-ca"

[otp]
enabled = true
token_length = 16
default_ttl = "24h"
max_uses = 1
hash_algorithm = "argon2id"

[admin]
enabled = true
auth = "bearer"
bearer_token_env = "KIPUKA_ADMIN_TOKEN"
```

Run the server:

```bash
export KIPUKA_ADMIN_TOKEN="dev-token-do-not-use-in-production"
cargo run -- --config kipuka.toml
```

## Running against each database backend

### SQLite

No additional setup.  The database file is created automatically when
`auto_migrate = true`:

```toml
[db]
url = "sqlite://kipuka-dev.db?mode=rwc"
auto_migrate = true
```

### PostgreSQL

Start a local PostgreSQL instance or use the Compose profile:

```bash
docker compose --profile postgres up -d postgres
```

Update `kipuka.toml`:

```toml
[db]
url = "postgres://kipuka:kipuka-dev@localhost:5432/kipuka"
auto_migrate = true
```

Run migrations explicitly if `auto_migrate` is disabled:

```bash
cargo run -- migrate --config kipuka.toml
```

### MariaDB

Start MariaDB via the Compose profile:

```bash
docker compose --profile mariadb up -d mariadb
```

Update `kipuka.toml`:

```toml
[db]
url = "mysql://kipuka:kipuka-dev@localhost:3306/kipuka"
auto_migrate = true
```

## HSM development with Kryoptic

Kryoptic provides a PKCS#11 interface compatible with the `cryptoki` crate
used by kipuka-hsm.  It stores keys in software but exposes the same API as a
hardware token.

### Starting Kryoptic

```bash
docker compose --profile hsm up -d kryoptic
```

The container exposes the PKCS#11 shared library at a bind-mounted path.
Check the `compose.yaml` for the exact mount point (typically
`/usr/lib/libkryoptic.so` inside the container).

### Initializing a token

Use `pkcs11-tool` (from the OpenSC package) to initialize a slot and generate
a CA signing key:

```bash
# Initialize the token in slot 0
pkcs11-tool --module /usr/lib/libkryoptic.so \
  --init-token --slot 0 \
  --label "kipuka-dev" \
  --so-pin 12345678

# Set the user PIN
pkcs11-tool --module /usr/lib/libkryoptic.so \
  --init-pin --slot 0 \
  --login --so-pin 12345678 \
  --new-pin 1234

# Generate an ECDSA P-256 key pair for CA signing
pkcs11-tool --module /usr/lib/libkryoptic.so \
  --login --pin 1234 \
  --keypairgen --key-type EC:prime256v1 \
  --id 01 --label "dev-ca-key"
```

### Configuring kipuka for HSM

Update `kipuka.toml` to reference the PKCS#11 module:

```toml
[hsm]
library = "/usr/lib/libkryoptic.so"
slot = 0
token_label = "kipuka-dev"
pin = "1234"  # For dev only; use pin_env or pin_file in production

[[ca]]
id = "hsm-dev-ca"
name = "HSM Development CA"
cert = "contrib/local-dev/pki/ca.pem"
key = "pkcs11:object=dev-ca-key"
hsm_slot = 0
```

### Listing objects in the token

```bash
pkcs11-tool --module /usr/lib/libkryoptic.so \
  --login --pin 1234 \
  --list-objects
```

### Verifying HSM signing

```bash
# Sign a test payload to confirm the PKCS#11 path works
pkcs11-tool --module /usr/lib/libkryoptic.so \
  --login --pin 1234 \
  --sign --mechanism ECDSA \
  --id 01 \
  --input-file /dev/urandom --read-write
```

## IDE setup

### rust-analyzer

kipuka works out of the box with rust-analyzer.  The workspace `Cargo.toml`
at the repository root defines all crate members, so rust-analyzer
automatically discovers the full project.

### VS Code

Recommended extensions:

| Extension | Purpose |
| --------- | ------- |
| `rust-lang.rust-analyzer` | Rust language support, inline type hints, go-to-definition |
| `vadimcn.vscode-lldb` | Debugger for Rust binaries |
| `tamasfe.even-better-toml` | TOML syntax highlighting and validation |
| `serayuzgur.crates` | Crate version hints in `Cargo.toml` |
| `usernamehw.errorlens` | Inline compiler error display |

Recommended `.vscode/settings.json` for the workspace:

```json
{
  "rust-analyzer.check.command": "clippy",
  "rust-analyzer.check.extraArgs": ["--", "-D", "warnings"],
  "rust-analyzer.cargo.features": "all",
  "editor.formatOnSave": true,
  "[rust]": {
    "editor.defaultFormatter": "rust-lang.rust-analyzer"
  }
}
```

### Environment variables for development

| Variable | Purpose | Example |
| -------- | ------- | ------- |
| `RUST_LOG` | Log verbosity | `debug`, `kipuka_est=trace` |
| `KIPUKA_ADMIN_TOKEN` | Admin API bearer token | `dev-token-do-not-use-in-production` |
| `KIPUKA_HSM_PIN` | HSM PIN (production) | (set in env, not in config file) |

Set these in a `.env` file (excluded from version control via `.gitignore`)
or export them in your shell.

## Next steps

- [Testing](./testing.md) -- run the test suite and perform protocol-level
  verification
- [Database Migrations](./migrations.md) -- create and manage schema changes
- [Contributing](./contributing.md) -- code style, commit conventions, and
  security invariants
