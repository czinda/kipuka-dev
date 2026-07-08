# Installation

This page covers every way to get kipuka running: pulling a pre-built container
image, building from source, and installing as a systemd service.

## Prerequisites

| Requirement | Minimum version | Notes |
| ----------- | --------------- | ----- |
| Rust toolchain | **1.88+** | Only needed when building from source |
| OpenSSL dev headers | 1.1.1+ or 3.x | Needed for the build; not linked at runtime (kipuka uses rustls) |
| SQLite **or** PostgreSQL | SQLite 3.35+ / PG 14+ | Database for OTP state and audit records |

## Container (fastest)

Pre-built images are published to [quay.io](https://quay.io/kipuka/kipuka) for
both `x86_64` and `aarch64`:

```bash
# x86_64 (default)
podman pull quay.io/kipuka/kipuka:latest

# Apple Silicon / ARM servers
podman pull quay.io/kipuka/kipuka:latest-arm64
```

Run the container with a bind-mounted configuration directory:

```bash
podman run -d \
  --name kipuka \
  -p 9443:9443 \
  -v /etc/kipuka:/etc/kipuka:ro \
  -v /var/lib/kipuka:/var/lib/kipuka:rw \
  quay.io/kipuka/kipuka:latest \
  kipuka --config /etc/kipuka/kipuka.toml
```

The container image ships a minimal filesystem.  All state lives in
`/var/lib/kipuka` (database, OTP records) and all configuration is read from
`/etc/kipuka`.  TLS certificates and CA key material are expected under
`/etc/kipuka/tls/` and `/etc/kipuka/ca/` respectively.

> **Tip:** For Kubernetes or OpenShift deployments, mount the configuration as a
> `ConfigMap` and secrets (TLS keys, CA keys) as `Secret` volumes.

## Building from source

Clone the repository and build in release mode:

```bash
git clone https://codeberg.org/czinda/kipuka.git
cd kipuka
cargo build --release
```

The workspace contains six crates:

| Crate | Purpose |
| ----- | ------- |
| `kipuka-est` | Core EST server, HTTP handlers, TLS, database |
| `kipuka-hsm` | PKCS #11 / HSM integration via `cryptoki` |
| `kipuka-otp` | One-time password generation and validation |
| `kipuka-util` | Shared utilities (ASN.1 helpers, configuration parsing) |
| `kipuka-dogtag` | Dogtag PKI back-end connector |
| `kipuka-coap` | CoAP (RFC 7252) transport layer |

The final binary is at `target/release/kipuka`.

### OS-specific build dependencies

#### Fedora / RHEL / CentOS Stream

```bash
sudo dnf install openssl-devel clang cmake pkg-config
```

#### Debian / Ubuntu

```bash
sudo apt install libssl-dev clang cmake pkg-config
```

#### macOS

```bash
brew install openssl cmake
export OPENSSL_DIR=$(brew --prefix openssl)
```

## Installing the binary

Copy the release binary to a location on `$PATH`:

```bash
sudo cp target/release/kipuka /usr/local/bin/
sudo chmod 755 /usr/local/bin/kipuka
```

Verify the installation:

```bash
kipuka --version
```

## systemd service

Create a dedicated service account:

```bash
sudo useradd -r -s /sbin/nologin -d /var/lib/kipuka kipuka
sudo mkdir -p /var/lib/kipuka /var/log/kipuka /etc/kipuka
sudo chown kipuka:kipuka /var/lib/kipuka /var/log/kipuka
```

Install the unit file at `/etc/systemd/system/kipuka.service`:

```ini
[Unit]
Description=kipuka EST enrollment server
Documentation=https://codeberg.org/czinda/kipuka
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=kipuka
Group=kipuka
ExecStart=/usr/local/bin/kipuka --config /etc/kipuka/kipuka.toml
Restart=on-failure
RestartSec=5s

# Security hardening
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=/var/lib/kipuka /var/log/kipuka
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=kipuka

[Install]
WantedBy=multi-user.target
```

Enable and start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now kipuka
sudo systemctl status kipuka
```

> **Note:** The `CAP_NET_BIND_SERVICE` capability allows kipuka to bind to
> port 443 without running as root.  If you run on a high port (e.g., 9443)
> you can remove both `CapabilityBoundingSet` and `AmbientCapabilities` lines.

## Running tests

The full test suite runs against an in-memory SQLite database and does not
require any external services:

```bash
cargo test
```

To run tests for a specific crate:

```bash
cargo test -p kipuka-est
cargo test -p kipuka-hsm
```

Integration tests that require a running EST server are gated behind a feature
flag:

```bash
cargo test --features integration
```

Next: [First Run](./first-run.md) walks you through creating a minimal
configuration and starting the server.
