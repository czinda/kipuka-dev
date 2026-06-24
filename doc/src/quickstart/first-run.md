# First Run

This guide takes you from a freshly installed kipuka binary to a running EST
server responding to `/cacerts` requests.  By the end you will have a working
server with a self-signed CA suitable for development and testing.

## Step 1: Create directories and service account

```bash
sudo mkdir -p /etc/kipuka/{tls,ca}
sudo mkdir -p /var/lib/kipuka
sudo mkdir -p /var/log/kipuka
sudo useradd -r -s /sbin/nologin -d /var/lib/kipuka kipuka
sudo chown kipuka:kipuka /var/lib/kipuka /var/log/kipuka
```

| Path | Purpose |
| ---- | ------- |
| `/etc/kipuka/tls/` | Server TLS certificate and private key |
| `/etc/kipuka/ca/` | CA certificate and signing key |
| `/var/lib/kipuka/` | Database files, OTP state |
| `/var/log/kipuka/` | Audit logs (when file-based logging is enabled) |

## Step 2: Generate test certificates

The repository includes a helper script that creates a complete test PKI:

```bash
./contrib/local-dev/setup-ca.sh
```

This generates a root CA, a server TLS certificate, and a client certificate
under `contrib/local-dev/pki/`.  Copy the relevant files:

```bash
sudo cp contrib/local-dev/pki/ca.pem /etc/kipuka/ca/ca.pem
sudo cp contrib/local-dev/pki/ca-key.pem /etc/kipuka/ca/ca-key.pem
sudo cp contrib/local-dev/pki/server.pem /etc/kipuka/tls/server.pem
sudo cp contrib/local-dev/pki/server-key.pem /etc/kipuka/tls/server-key.pem
```

### Manual certificate generation

If you prefer to create certificates by hand:

```bash
# Root CA
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout /etc/kipuka/ca/ca-key.pem \
  -out /etc/kipuka/ca/ca.pem \
  -days 3650 -nodes \
  -subj "/CN=kipuka Test CA"

# Server TLS certificate
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout /etc/kipuka/tls/server-key.pem \
  -out /tmp/server.csr -nodes \
  -subj "/CN=localhost"

openssl x509 -req -in /tmp/server.csr \
  -CA /etc/kipuka/ca/ca.pem \
  -CAkey /etc/kipuka/ca/ca-key.pem \
  -CAcreateserial \
  -out /etc/kipuka/tls/server.pem \
  -days 365 \
  -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1")

rm /tmp/server.csr
```

Set restrictive permissions on key material:

```bash
sudo chmod 600 /etc/kipuka/ca/ca-key.pem /etc/kipuka/tls/server-key.pem
sudo chown kipuka:kipuka /etc/kipuka/ca/* /etc/kipuka/tls/*
```

## Step 3: Write a minimal configuration

Create `/etc/kipuka/kipuka.toml`:

```toml
[server]
listen = "0.0.0.0:9443"

[tls]
cert = "/etc/kipuka/tls/server.pem"
key = "/etc/kipuka/tls/server-key.pem"

[tls.client_auth]
# Trust anchor for EST client certificate authentication.
# Clients presenting a certificate signed by this CA are
# permitted to re-enroll without an OTP.
trust_anchors = ["/etc/kipuka/ca/ca.pem"]

[db]
# SQLite for development.  Use a PostgreSQL URL for production.
url = "sqlite:///var/lib/kipuka/kipuka.db?mode=rwc"

[[ca]]
id = "default"
cert = "/etc/kipuka/ca/ca.pem"
key = "/etc/kipuka/ca/ca-key.pem"

# Optional: restrict which subject names this CA will sign.
# allowed_subjects = ["CN=*"]

# Optional: set a default certificate validity period.
# validity_days = 365
```

> **Production note:** For production deployments, replace the `[db]` URL with a
> PostgreSQL connection string and store CA keys in an HSM.  See the
> [Configuration Reference](../operator/configuration.md) for the full set of
> options.

## Step 4: Run database migrations

kipuka manages its own schema.  Run the migration command before the first
start:

```bash
sudo -u kipuka kipuka migrate --config /etc/kipuka/kipuka.toml
```

Expected output:

```
Applied 3 migrations to sqlite:///var/lib/kipuka/kipuka.db
```

## Step 5: Start the server

Start kipuka in the foreground to verify everything works:

```bash
sudo -u kipuka kipuka --config /etc/kipuka/kipuka.toml
```

You should see log output similar to:

```
2026-06-24T12:00:00.000Z  INFO kipuka::server: kipuka v0.1.0 starting
2026-06-24T12:00:00.001Z  INFO kipuka::tls: TLS configured, client auth enabled
2026-06-24T12:00:00.002Z  INFO kipuka::ca: Loaded CA "default" (CN=kipuka Test CA)
2026-06-24T12:00:00.003Z  INFO kipuka::db: Database connected (sqlite)
2026-06-24T12:00:00.004Z  INFO kipuka::server: Listening on 0.0.0.0:9443
```

Press `Ctrl+C` to stop.  For long-running deployments, use the
[systemd service](./install.md#systemd-service) instead.

## Step 6: Verify the EST endpoint

The `/cacerts` endpoint returns the CA certificate(s) without requiring client
authentication.  Use it to confirm the server is responding:

```bash
curl -sk https://localhost:9443/.well-known/est/cacerts \
  | base64 -d \
  | openssl pkcs7 -inform DER -print_certs
```

You should see the PEM-encoded CA certificate:

```
subject=CN = kipuka Test CA
issuer=CN = kipuka Test CA
-----BEGIN CERTIFICATE-----
MIIBkTCB+...
-----END CERTIFICATE-----
```

If this works, your server is ready to issue certificates.

## Logging

kipuka uses Rust's `tracing` framework.  Control verbosity with the `RUST_LOG`
environment variable:

| Level | What you see |
| ----- | ------------ |
| `RUST_LOG=error` | Only errors |
| `RUST_LOG=warn` | Errors and warnings |
| `RUST_LOG=info` | Startup, shutdown, enrollment events (default) |
| `RUST_LOG=debug` | Request/response details, TLS handshake info |
| `RUST_LOG=trace` | Full ASN.1 dumps, raw bytes, internal state |

To set the log level when running directly:

```bash
RUST_LOG=debug kipuka --config /etc/kipuka/kipuka.toml
```

For the systemd service, add an environment override:

```bash
sudo systemctl edit kipuka
```

```ini
[Service]
Environment="RUST_LOG=debug"
```

Next: [Your First Certificate](./first-certificate.md) walks through the
complete enrollment flow — generating an OTP, submitting a CSR, and extracting
the signed certificate.
