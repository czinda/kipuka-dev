# HSM Compatibility Matrix

This page documents the Hardware Security Modules that kipuka has been
tested with, their supported mechanisms, configuration specifics, and known
limitations.  kipuka communicates with HSMs exclusively through the PKCS#11
(Cryptoki) interface via the `cryptoki` crate.

## Compatibility Overview

| Feature | Entrust nShield | Utimaco CryptoServer | Kryoptic | Thales Luna 7 |
|---------|----------------|---------------------|----------|---------------|
| **PKCS#11 version** | 2.40 | 2.40 | 2.40 | 2.40 |
| **RSA 2048** | Yes | Yes | Yes | Yes |
| **RSA 3072** | Yes | Yes | Yes | Yes |
| **RSA 4096** | Yes | Yes | Yes | Yes |
| **ECDSA P-256** | Yes | Yes | Yes | Yes |
| **ECDSA P-384** | Yes | Yes | Yes | Yes |
| **ECDSA P-521** | Yes | Yes | Yes | Yes |
| **RSA PKCS#1 v1.5 signing** | Yes | Yes | Yes | Yes |
| **RSA-PSS signing** | Yes | Yes | Yes | Yes |
| **ECDSA signing** | Yes | Yes | Yes | Yes |
| **ML-DSA (FIPS 204)** | No | Firmware-dependent | Yes (software) | No |
| **AES-WRAP key wrapping** | Yes | Yes | Yes | Yes |
| **RSA-OAEP key wrapping** | Yes | Yes | Yes | Yes |
| **Concurrent sessions** | Up to 256 | Up to 128 | Unlimited | Up to 64 |
| **FIPS 140-3 level** | Level 3 | Level 3 (CP5) | N/A (software) | Level 3 |
| **Key non-exportability** | CKA_EXTRACTABLE=false | CKA_EXTRACTABLE=false | Configurable | CKA_EXTRACTABLE=false |
| **Remote/network HSM** | Yes (nShield Connect) | Yes (LAN) | N/A | Yes (Luna Network HSM) |

## Signing Mechanisms

kipuka uses the following PKCS#11 mechanisms for certificate signing,
selected automatically based on the CA key type:

| Key Type | PKCS#11 Mechanism | kipuka Function |
|----------|-------------------|----------------|
| RSA (PKCS#1 v1.5) | `CKM_RSA_PKCS` | `sign_rsa_pkcs1` |
| RSA (PSS) | `CKM_RSA_PKCS_PSS` | `sign_rsa_pss` |
| ECDSA (any curve) | `CKM_ECDSA` | `sign_ecdsa` |
| ML-DSA | `CKM_IBM_DILITHIUM` (vendor-specific) | `sign_ml_dsa` |

The hash algorithm for RSA mechanisms is configurable per CA via the
`RsaHashAlgorithm` enum: SHA-256 (default), SHA-384, or SHA-512.

## Key Wrapping for `/serverkeygen`

When `/serverkeygen` generates a key pair on the server, the private key
must be encrypted for transport to the client.  kipuka supports the
following wrapping methods:

| Wrapping Method | PKCS#11 Mechanism | Client Key Type | Notes |
|----------------|-------------------|----------------|-------|
| AES-256-WRAP | `CKM_AES_KEY_WRAP` | Any (symmetric wrapping) | Content encryption key wrapped; CEK encrypts the private key via AES-CBC or AES-GCM |
| RSA-OAEP (SHA-256) | `CKM_RSA_PKCS_OAEP` | RSA | CEK wrapped directly to client's RSA public key |
| ECDH-ES + AES-WRAP | `CKM_ECDH1_DERIVE` + `CKM_AES_KEY_WRAP` | ECDSA/ECDH | Ephemeral ECDH key agreement derives a wrapping key |

Not all HSMs support all wrapping combinations.  The following table shows
which wrapping methods are available per vendor:

| Wrapping Method | Entrust nShield | Utimaco CryptoServer | Kryoptic | Thales Luna 7 |
|----------------|----------------|---------------------|----------|---------------|
| AES-256-WRAP | Yes | Yes | Yes | Yes |
| RSA-OAEP (SHA-256) | Yes | Yes | Yes | Yes |
| RSA-OAEP (SHA-384) | Yes | No | Yes | Yes |
| ECDH-ES + AES-WRAP | Yes | Yes | Yes | Yes |

## Per-Vendor Configuration

### Entrust nShield

The nShield HSM family includes the Solo XC (PCIe), Connect XC (network),
and Edge (compact form factor) models.

**Library path:**

```toml
[hsm]
library = "/opt/nfast/toolkits/pkcs11/libcknfast.so"
```

**Environment variables:**

```bash
# Security World configuration
export NFAST_HOME="/opt/nfast"
export NFAST_KMDATA="/opt/nfast/kmdata/local"
```

**Key generation (via nShield tools):**

```bash
# Generate an RSA 4096 CA key in the Security World
generatekey pkcs11 \
  --key-type=RSA \
  --size=4096 \
  --token-label="kipuka-ca" \
  --key-label="ca-signing-key" \
  --protect=module

# Generate an ECDSA P-384 CA key
generatekey pkcs11 \
  --key-type=EC \
  --curve=P-384 \
  --token-label="kipuka-ca" \
  --key-label="ca-ec-signing-key" \
  --protect=module
```

**Configuration example:**

```toml
[hsm]
library = "/opt/nfast/toolkits/pkcs11/libcknfast.so"
token_label = "kipuka-ca"
pin_env = "KIPUKA_HSM_PIN"

[[ca]]
id = "nshield-ca"
name = "nShield-backed CA"
cert = "/etc/kipuka/ca/nshield-ca.pem"
key = "pkcs11:token=kipuka-ca;object=ca-signing-key"
hsm_slot = 0
```

**Known limitations:**

- nShield requires the Security World to be initialized and the module to
  be in operational state before kipuka starts.
- Concurrent session limits depend on the module model and license.  The
  Solo XC supports up to 256 concurrent PKCS#11 sessions.
- ML-DSA is not supported as of nShield firmware 13.x.  Use Synta software
  fallback for post-quantum signing with nShield.

### Utimaco CryptoServer

Utimaco CryptoServer models include the LAN appliance, PCIe card, and
Se-Series (cloud HSM).

**Library path:**

```toml
[hsm]
library = "/usr/lib/utimaco/libcs_pkcs11_R3.so"
```

**Configuration file:**

Utimaco requires a configuration file referenced by the `CS_PKCS11_R3_CFG`
environment variable:

```bash
export CS_PKCS11_R3_CFG="/etc/utimaco/cs_pkcs11_R3.cfg"
```

Example `cs_pkcs11_R3.cfg`:

```ini
[Global]
Logging = 0
Logpath = /var/log/utimaco
SlotCount = 10

[CryptoServer]
Device = TCP:192.168.1.100:3001
Timeout = 30000
```

**Key generation (via Utimaco tools):**

```bash
# Generate RSA 4096 CA key
p11tool2 --module=/usr/lib/utimaco/libcs_pkcs11_R3.so \
  --login --so-pin=$SO_PIN \
  --generate-rsa --bits=4096 \
  --label="ca-signing-key" \
  --id=01

# Generate ECDSA P-384 CA key
p11tool2 --module=/usr/lib/utimaco/libcs_pkcs11_R3.so \
  --login --so-pin=$SO_PIN \
  --generate-ec --curve=P-384 \
  --label="ca-ec-signing-key" \
  --id=02
```

**Configuration example:**

```toml
[hsm]
library = "/usr/lib/utimaco/libcs_pkcs11_R3.so"
slot = 0
pin_env = "KIPUKA_HSM_PIN"

[[ca]]
id = "utimaco-ca"
name = "Utimaco-backed CA"
cert = "/etc/kipuka/ca/utimaco-ca.pem"
key = "pkcs11:slot=0;object=ca-signing-key"
hsm_slot = 0
```

**Known limitations:**

- RSA-OAEP with SHA-384 is not supported; use SHA-256 for `/serverkeygen`
  key wrapping.
- Maximum 128 concurrent PKCS#11 sessions.  Size the kipuka connection pool
  accordingly (`db.max_connections` should not exceed this when HSM-bound
  operations dominate).
- ML-DSA support depends on firmware version.  Check with Utimaco for
  availability on your CryptoServer model.

### Kryoptic

Kryoptic is a software PKCS#11 implementation used for development,
testing, and non-FIPS deployments.  It implements the standard PKCS#11
interface without requiring physical hardware.

**Library path:**

```toml
[hsm]
library = "/usr/lib/kryoptic/libkryoptic_pkcs11.so"
```

On macOS:

```toml
[hsm]
library = "/usr/local/lib/libkryoptic_pkcs11.dylib"
```

**Token initialization:**

```bash
# Initialize a Kryoptic token
pkcs11-tool --module=/usr/lib/kryoptic/libkryoptic_pkcs11.so \
  --init-token --label="kipuka-dev" \
  --so-pin=12345678

# Set the user PIN
pkcs11-tool --module=/usr/lib/kryoptic/libkryoptic_pkcs11.so \
  --init-pin --token-label="kipuka-dev" \
  --so-pin=12345678 --new-pin=userpin
```

**Key generation:**

```bash
# Generate RSA 2048 key for testing
pkcs11-tool --module=/usr/lib/kryoptic/libkryoptic_pkcs11.so \
  --login --pin=userpin \
  --token-label="kipuka-dev" \
  --keypairgen --key-type=RSA:2048 \
  --label="test-ca-key" --id=01

# Generate ECDSA P-256 key for testing
pkcs11-tool --module=/usr/lib/kryoptic/libkryoptic_pkcs11.so \
  --login --pin=userpin \
  --token-label="kipuka-dev" \
  --keypairgen --key-type=EC:prime256v1 \
  --label="test-ec-key" --id=02
```

**Configuration example:**

```toml
[hsm]
library = "/usr/lib/kryoptic/libkryoptic_pkcs11.so"
token_label = "kipuka-dev"
pin = "userpin"  # Acceptable for development only

[[ca]]
id = "dev-ca"
name = "Development CA"
cert = "/etc/kipuka/ca/dev-ca.pem"
key = "pkcs11:token=kipuka-dev;object=test-ca-key"
```

**Known limitations:**

- Kryoptic is a software implementation and does not hold a FIPS 140-3
  validation.  Do not use it for production deployments that require
  hardware-backed key protection.
- ML-DSA signing uses the Synta software fallback through
  `SoftwarePqcFallback`, not native PKCS#11 mechanisms.
- Token state is stored on the filesystem.  Protect the Kryoptic data
  directory with appropriate file permissions.
- Useful for CI/CD pipelines and integration testing where a real HSM is
  not available.

### Thales Luna 7 (Network HSM and PCIe)

The Thales Luna 7 family includes the Luna Network HSM (SA 7000) and Luna
PCIe HSM.

**Library path:**

```toml
[hsm]
library = "/usr/safenet/lunaclient/lib/libCryptoki2_64.so"
```

On macOS (Luna client):

```toml
[hsm]
library = "/usr/local/lib/libCryptoki2.dylib"
```

**Client configuration:**

Luna requires a client certificate registered with the HSM partition.
Configuration is managed through the Luna client tools and the
`Chrystoki.conf` file:

```ini
Chrystoki2 = {
  LibUNIX64 = /usr/safenet/lunaclient/lib/libCryptoki2_64.so;
}

LunaSA Client = {
  ServerCAFile = /etc/Chrystoki2/certs/server.pem;
  ClientCertFile = /etc/Chrystoki2/certs/client.pem;
  ClientPrivKeyFile = /etc/Chrystoki2/certs/client-key.pem;
  ServerName00 = luna-hsm.example.com;
  ServerPort00 = 1792;
}
```

**Key generation (via Luna tools):**

```bash
# Generate RSA 4096 CA key in partition
cmu generatekeypair \
  -modulusLen=4096 \
  -publicExponent=65537 \
  -label="ca-signing-key" \
  -sign=True \
  -verify=True \
  -extractable=False \
  -token=True

# Generate ECDSA P-384 CA key
cmu generatekeypair \
  -keyType=EC \
  -curvetype=3 \
  -label="ca-ec-signing-key" \
  -sign=True \
  -verify=True \
  -extractable=False \
  -token=True
```

**Configuration example:**

```toml
[hsm]
library = "/usr/safenet/lunaclient/lib/libCryptoki2_64.so"
slot = 1
pin_env = "KIPUKA_HSM_PIN"

[[ca]]
id = "luna-ca"
name = "Luna 7-backed CA"
cert = "/etc/kipuka/ca/luna-ca.pem"
key = "pkcs11:slot=1;object=ca-signing-key"
hsm_slot = 1
```

**Known limitations:**

- Maximum 64 concurrent PKCS#11 sessions per partition.  For high-throughput
  deployments, consider using HA groups across multiple partitions or HSMs.
- ML-DSA is not supported as of Luna firmware 7.x.  Use Synta software
  fallback for post-quantum signing.
- Luna Network HSM requires a network partition and registered client
  certificate.  The client certificate must be registered before kipuka
  can connect to the HSM.
- Session timeout: Luna partitions have a configurable idle session timeout.
  Set `Idle Sessions Timeout` to 0 (disabled) or to a value longer than
  kipuka's HA health check interval to prevent session churn.

## HSM Session Management

kipuka maintains a pool of PKCS#11 sessions to avoid the overhead of
opening and closing sessions for every signing operation.  The pool is
managed by the `Pkcs11Context` struct in `kipuka_hsm::pkcs11`.

| Parameter | Description | Recommendation |
|-----------|-------------|---------------|
| Session pool size | Controlled by `db.max_connections` (shared pool) | Set to the lesser of the HSM's max concurrent sessions and the expected peak signing rate |
| Login state | Sessions are logged in once at pool creation | The HSM PIN is used at startup; it is not stored in memory after login |
| Error recovery | Failed sessions are dropped and replaced | kipuka logs a `CaHealthChange` audit event when session errors exceed the HA threshold |

## Adding a New HSM

kipuka's HSM support is modular.  The `kipuka_hsm::providers` module
contains per-vendor configuration through the `HsmProvider` enum:

- `Entrust` -- Entrust nShield family
- `Utimaco` -- Utimaco CryptoServer family
- `Kryoptic` -- Kryoptic software PKCS#11
- `ThalesCsp` -- Thales CipherTrust / SafeNet (legacy)
- `ThalesTct` -- Thales Luna 7 and later

Each provider module exports:

- `default_library_path()` -- Platform-specific default library location
- `provider_config()` -- Vendor-specific PKCS#11 initialization settings
- `supported_mechanisms()` -- List of PKCS#11 mechanisms the provider is
  known to support

To add support for a new HSM vendor, implement these three functions in a
new module under `kipuka_hsm::providers` and add a variant to the
`HsmProvider` enum.  The PKCS#11 standard interface means most HSMs will
work without vendor-specific code as long as the library path is configured
correctly; the provider module primarily documents known quirks and
default paths.
