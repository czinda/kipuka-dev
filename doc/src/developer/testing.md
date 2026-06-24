# Testing

kipuka's test suite covers unit tests, integration tests, EST protocol
conformance, HSM operations, and full-stack enrollment flows.

## Unit tests

Unit tests run against in-memory state and do not require any external
services.  They execute quickly and are suitable for rapid iteration:

```bash
cargo test
```

### Per-crate testing

Run tests for a specific crate to reduce compilation time during focused
development:

```bash
cargo test -p kipuka-est
cargo test -p kipuka-hsm
cargo test -p kipuka-otp
cargo test -p kipuka-util
cargo test -p kipuka-dogtag
cargo test -p kipuka-coap
```

### Filtering tests

Run a single test or a subset by name:

```bash
# Run all tests with "otp" in the name
cargo test otp

# Run a specific test function
cargo test -p kipuka-otp -- test_argon2_hash_roundtrip

# Show test output (including println! in passing tests)
cargo test -- --nocapture
```

## Integration tests

Integration tests exercise the full HTTP stack: TLS handshake, request
routing, authentication, CSR validation, certificate issuance, and database
persistence.  They are gated behind a feature flag because they start a real
axum server on a random port:

```bash
cargo test --features integration
```

Integration tests create a temporary SQLite database for each test run and
clean it up on completion.  No external database is required.

### What integration tests cover

- Full `/simpleenroll` flow with OTP authentication
- Full `/simplereenroll` flow with mTLS client certificate
- `/cacerts` response format and PKCS#7 encoding
- `/csrattrs` response with configured OID sets
- `/serverkeygen` key pair generation and certificate issuance
- EST label routing to different CAs
- CSR policy rejection (wrong key type, missing SAN, bad subject DN)
- OTP rate limiting and lockout behavior
- Concurrent enrollment under load
- HA failover (with mock CA health checks)
- Audit log correctness

## EST protocol testing with curl and openssl

These commands verify kipuka's EST implementation at the protocol level.
They assume a running server at `localhost:9443` with the test PKI from
`contrib/local-dev/setup-ca.sh`.

### Fetch CA certificates

The `/cacerts` endpoint requires no authentication:

```bash
curl -sk https://localhost:9443/.well-known/est/cacerts \
  | base64 -d \
  | openssl pkcs7 -inform DER -print_certs
```

Expected output: the PEM-encoded CA certificate chain.

### Enroll with OTP

Generate an OTP via the admin API, then enroll:

```bash
# Generate OTP
OTP=$(curl -sk -X POST https://localhost:9443/admin/otp \
  -H "Authorization: Bearer $KIPUKA_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"entity_id": "test-device"}' \
  | jq -r '.otp')

# Generate CSR
openssl req -new \
  -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout test.key -out test.csr -nodes \
  -subj "/CN=test-device"

# Enroll
curl -sk \
  --cacert contrib/local-dev/pki/ca.pem \
  -u "test-device:${OTP}" \
  --data-binary @test.csr \
  -H "Content-Type: application/pkcs10" \
  -o test.p7 \
  -w "%{http_code}\n" \
  https://localhost:9443/.well-known/est/simpleenroll

# Extract certificate
openssl pkcs7 -inform DER -in test.p7 -print_certs -out test.pem

# Verify
openssl verify -CAfile contrib/local-dev/pki/ca.pem test.pem
```

### Re-enroll with client certificate

Use the certificate from the previous step for mTLS authentication:

```bash
# Generate new CSR (with fresh key pair)
openssl req -new \
  -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout test-new.key -out test-new.csr -nodes \
  -subj "/CN=test-device"

# Re-enroll with mTLS
curl -sk \
  --cacert contrib/local-dev/pki/ca.pem \
  --cert test.pem --key test.key \
  --data-binary @test-new.csr \
  -H "Content-Type: application/pkcs10" \
  -o test-new.p7 \
  -w "%{http_code}\n" \
  https://localhost:9443/.well-known/est/simplereenroll

# Extract renewed certificate
openssl pkcs7 -inform DER -in test-new.p7 -print_certs -out test-new.pem
```

### Label routing

Test enrollment against a specific EST label:

```bash
# Enroll against the "iot" label (if configured)
curl -sk \
  --cacert contrib/local-dev/pki/ca.pem \
  -u "sensor-01:${OTP}" \
  --data-binary @sensor.csr \
  -H "Content-Type: application/pkcs10" \
  -o sensor.p7 \
  https://localhost:9443/.well-known/est/iot/simpleenroll

# Verify the issuer matches the CA bound to the "iot" label
openssl pkcs7 -inform DER -in sensor.p7 -print_certs \
  | openssl x509 -noout -issuer
```

### Server key generation

Test the `/serverkeygen` endpoint (if enabled in config):

```bash
# Request server-generated key pair
curl -sk \
  --cacert contrib/local-dev/pki/ca.pem \
  --cert test.pem --key test.key \
  --data-binary @test.csr \
  -H "Content-Type: application/pkcs10" \
  -o serverkeygen.p7 \
  https://localhost:9443/.well-known/est/serverkeygen
```

The response is a multipart MIME message containing both the certificate
(PKCS#7) and the server-generated private key (PKCS#8).

## TLS handshake inspection

Use `openssl s_client` to inspect the TLS configuration:

```bash
# Connect and show server certificate
openssl s_client -connect localhost:9443 \
  -CAfile contrib/local-dev/pki/ca.pem \
  -servername localhost \
  2>/dev/null | openssl x509 -noout -text

# Test mTLS with client certificate
openssl s_client -connect localhost:9443 \
  -CAfile contrib/local-dev/pki/ca.pem \
  -cert contrib/local-dev/pki/client.pem \
  -key contrib/local-dev/pki/client-key.pem \
  -servername localhost

# Show negotiated cipher and protocol
openssl s_client -connect localhost:9443 \
  -CAfile contrib/local-dev/pki/ca.pem \
  2>/dev/null | grep -E "Protocol|Cipher"

# Test TLS 1.3 only
openssl s_client -connect localhost:9443 \
  -CAfile contrib/local-dev/pki/ca.pem \
  -tls1_3 2>/dev/null | grep "Protocol"
```

## HSM testing with Kryoptic

Test the PKCS#11 code path using the Kryoptic SoftHSM container from
`compose.yaml`:

```bash
# Start Kryoptic
docker compose --profile hsm up -d kryoptic

# Initialize token and generate test key (see Development Setup for details)
pkcs11-tool --module /usr/lib/libkryoptic.so \
  --init-token --slot 0 --label "test-hsm" --so-pin 12345678
pkcs11-tool --module /usr/lib/libkryoptic.so \
  --init-pin --slot 0 --login --so-pin 12345678 --new-pin 1234
pkcs11-tool --module /usr/lib/libkryoptic.so \
  --login --pin 1234 \
  --keypairgen --key-type EC:prime256v1 \
  --id 01 --label "test-ca-key"

# Run HSM-specific tests
cargo test -p kipuka-hsm --features integration
```

HSM tests verify:

- PKCS#11 session lifecycle (open, login, operate, close)
- Key lookup by label and ID
- ECDSA and RSA signing operations
- Error handling for unavailable slots, wrong PINs, missing keys
- Concurrent signing from multiple threads (session pooling)

## CI pipeline

### What runs in CI

Every push and merge request triggers the following:

| Step | Command | Purpose |
| ---- | ------- | ------- |
| Format check | `cargo fmt --check` | Enforce consistent formatting |
| Lint | `cargo clippy -- -D warnings` | Catch common mistakes and style issues |
| Unit tests | `cargo test` | All per-crate unit tests |
| Integration tests | `cargo test --features integration` | Full-stack EST protocol tests |
| Build (release) | `cargo build --release` | Verify release compilation succeeds |
| Documentation | `cargo doc --no-deps` | Verify rustdoc builds without warnings |

### What requires manual or environment-specific testing

These tests cannot run in a standard CI runner and must be performed during
development or in dedicated test environments:

| Test | Reason | How to run |
| ---- | ------ | ---------- |
| Hardware HSM signing | Requires physical HSM hardware | Connect a YubiHSM 2 or Luna, run `cargo test -p kipuka-hsm --features hsm-hardware` |
| PostgreSQL integration | Requires a running PostgreSQL instance | `docker compose --profile postgres up -d && cargo test --features integration-postgres` |
| MariaDB integration | Requires a running MariaDB instance | `docker compose --profile mariadb up -d && cargo test --features integration-mariadb` |
| Dogtag PKI back-end | Requires a running Dogtag instance | Deploy Dogtag in a container, configure connection in test config |
| GSSAPI authentication | Requires a KDC (FreeIPA or AD) | Set up FreeIPA in a container, create service principal, run GSSAPI tests |
| NIAP compliance audit | Manual review against Protection Profile | Follow the checklist in `docs/compliance/niap.md` |

## Integration testing with idm-ci / Beaker

For full end-to-end testing of kipuka integrated with FreeIPA (IPA-to-kipuka
certificate enrollment flows), use the idm-ci framework or Beaker test
infrastructure.

### idm-ci

idm-ci provisions multi-host test environments with FreeIPA servers, kipuka
instances, and client machines.  Tests exercise the complete enrollment
lifecycle:

1. FreeIPA issues a Kerberos ticket to the client
2. Client authenticates to kipuka using GSSAPI
3. kipuka maps the Kerberos principal to a certificate subject
4. kipuka issues a certificate
5. Client installs the certificate and uses it for mTLS re-enrollment

These tests are defined outside the kipuka repository and are triggered by
the IdM CI infrastructure.

### Local smoke test with FreeIPA container

For a lightweight local approximation:

```bash
# Start FreeIPA in a container
podman run -d --name freeipa \
  -h ipa.example.test \
  -p 389:389 -p 443:443 -p 88:88 -p 464:464 \
  quay.io/freeipa/freeipa-server:latest \
  ipa-server-install --unattended \
    --realm EXAMPLE.TEST \
    --domain example.test \
    --ds-password Secret123 \
    --admin-password Secret123

# Wait for installation to complete (5-10 minutes)
podman logs -f freeipa

# Create a service principal for kipuka
podman exec freeipa kinit admin <<< "Secret123"
podman exec freeipa ipa service-add HTTP/kipuka.example.test
podman exec freeipa ipa-getkeytab \
  -s ipa.example.test \
  -p HTTP/kipuka.example.test \
  -k /tmp/kipuka.keytab

# Copy the keytab out
podman cp freeipa:/tmp/kipuka.keytab ./kipuka.keytab
```

Then configure kipuka's `[gssapi]` section to point to the extracted keytab
and run enrollment tests using `curl --negotiate`.

## Test data cleanup

Test runs that create database state (OTP tokens, certificates, audit
entries) use temporary SQLite databases by default.  To clean up after manual
testing against a persistent database:

```bash
# Delete the development SQLite database
rm -f kipuka-dev.db

# For PostgreSQL, drop and recreate the database
psql -U kipuka -h localhost -c "DROP DATABASE kipuka; CREATE DATABASE kipuka;"
```

Re-run migrations after cleanup:

```bash
cargo run -- migrate --config kipuka.toml
```
