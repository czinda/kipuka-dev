# HSM Integration

kipuka supports Hardware Security Modules (HSMs) and software HSMs through the PKCS#11 (Cryptoki) standard. HSM integration ensures that CA private keys never leave the secure hardware boundary, with all signing operations delegated to the HSM.

## PKCS#11 Overview

kipuka uses the PKCS#11 API to interface with HSMs. The integration model follows these principles:

- The `[hsm]` section in `kipuka.toml` configures the PKCS#11 provider library and authentication
- CA definitions reference HSM-stored keys using the `hsm_slot` parameter in the `[[ca]]` section
- Private keys remain on the HSM at all times—signing operations are performed by the HSM
- When `hsm_slot` is set for a CA, the `key` parameter is ignored

This architecture ensures that sensitive key material never exists in kipuka's process memory or on the filesystem.

## Supported Vendors and Library Paths

kipuka works with any PKCS#11-compliant HSM. The following table lists common vendors and their typical library paths:

| Vendor | Product | Library Path (Linux) | Library Path (macOS) |
|--------|---------|---------------------|---------------------|
| Entrust | nShield | `/opt/nfast/toolkits/pkcs11/libcknfast.so` | N/A |
| Utimaco | CryptoServer | `/opt/utimaco/lib/libcs_pkcs11_R3.so` | N/A |
| Thales | Luna | `/usr/safenet/lunaclient/lib/libCryptoki2_64.so` | `/usr/safenet/lunaclient/lib/libCryptoki2.dylib` |
| Kryoptic | SoftHSM-compatible | `/usr/lib/pkcs11/libkryoptic_pkcs11.so` | `target/release/libkryoptic_pkcs11.dylib` |
| SoftHSM2 | SoftHSM2 | `/usr/lib/softhsm/libsofthsm2.so` | `/usr/local/lib/softhsm/libsofthsm2.so` |
| AWS | CloudHSM | `/opt/cloudhsm/lib/libcloudhsm_pkcs11.so` | N/A |
| YubiHSM | YubiHSM2 | `/usr/lib/x86_64-linux-gnu/pkcs11/yubihsm_pkcs11.so` | `/usr/local/lib/pkcs11/yubihsm_pkcs11.dylib` |

Consult your HSM vendor documentation for the exact library path on your system.

## PIN Management

kipuka supports three methods for providing the HSM PIN, evaluated in the following priority order:

### Environment Variable (RECOMMENDED)

Set `pin_env` to the name of an environment variable containing the PIN:

```toml
[hsm]
library = "/usr/lib/softhsm/libsofthsm2.so"
token_label = "kipuka"
pin_env = "KIPUKA_HSM_PIN"
```

Then start kipuka with the PIN in the environment:

```bash
export KIPUKA_HSM_PIN="your-pin-here"
kipuka
```

For systemd services, use `EnvironmentFile`:

```ini
[Service]
EnvironmentFile=/etc/kipuka/hsm.env
ExecStart=/usr/local/bin/kipuka
```

Where `/etc/kipuka/hsm.env` contains:

```
KIPUKA_HSM_PIN=your-pin-here
```

Set restrictive permissions on the environment file:

```bash
chmod 0400 /etc/kipuka/hsm.env
chown kipuka:kipuka /etc/kipuka/hsm.env
```

### PIN File

Set `pin_file` to a path containing only the PIN:

```toml
[hsm]
library = "/usr/lib/softhsm/libsofthsm2.so"
token_label = "kipuka"
pin_file = "/etc/kipuka/hsm.pin"
```

Secure the PIN file:

```bash
echo "your-pin-here" > /etc/kipuka/hsm.pin
chmod 0400 /etc/kipuka/hsm.pin
chown kipuka:kipuka /etc/kipuka/hsm.pin
```

### Plaintext PIN (NOT RECOMMENDED)

For development only, the PIN can be stored directly in the configuration:

```toml
[hsm]
library = "/usr/lib/softhsm/libsofthsm2.so"
token_label = "kipuka"
pin = "1234"
```

**Never use this method in production.** The PIN will be visible in the configuration file and process listings.

## Slot Configuration

PKCS#11 tokens are identified by either slot number or token label.

### By Slot Number

Reference the HSM token by its numeric slot identifier:

```toml
[hsm]
library = "/usr/lib/softhsm/libsofthsm2.so"
slot = 0
pin_env = "KIPUKA_HSM_PIN"
```

### By Token Label

Reference the HSM token by its label:

```toml
[hsm]
library = "/usr/lib/softhsm/libsofthsm2.so"
token_label = "kipuka"
pin_env = "KIPUKA_HSM_PIN"
```

Using `token_label` is generally more portable across HSM reconfigurations.

### Discovering Slots

Use `pkcs11-tool` to list available slots:

```bash
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so --list-slots
```

Example output:

```
Available slots:
Slot 0 (0x1d6d28f6): SoftHSM slot ID 0x1d6d28f6
  token label        : kipuka
  token manufacturer : SoftHSM project
  token model        : SoftHSM v2
  token flags        : login required, rng, token initialized, PIN initialized
  hardware version   : 2.6
  firmware version   : 2.6
  serial num         : 4c8e0a766d6d28f6
  pin min/max        : 4/255
```

The token label from this output can be used as the `token_label` value.

## Key Generation Examples

Before configuring kipuka to use HSM-stored keys, you must generate key pairs on the HSM. The following examples use `pkcs11-tool` from the OpenSC package.

### Generate RSA 2048-bit Key Pair

```bash
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --login \
  --pin 1234 \
  --keypairgen \
  --key-type rsa:2048 \
  --id 01 \
  --label "kipuka-ca-rsa-2048"
```

### Generate RSA 4096-bit Key Pair

```bash
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --login \
  --pin 1234 \
  --keypairgen \
  --key-type rsa:4096 \
  --id 02 \
  --label "kipuka-ca-rsa-4096"
```

### Generate ECDSA P-256 Key Pair

```bash
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --login \
  --pin 1234 \
  --keypairgen \
  --key-type EC:prime256v1 \
  --id 03 \
  --label "kipuka-ca-ec-p256"
```

### Generate ECDSA P-384 Key Pair

```bash
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --login \
  --pin 1234 \
  --keypairgen \
  --key-type EC:secp384r1 \
  --id 04 \
  --label "kipuka-ca-ec-p384"
```

### List HSM Objects

Verify key generation by listing objects on the token:

```bash
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --login \
  --pin 1234 \
  --list-objects
```

Example output:

```
Public Key Object; RSA 2048 bits
  label:      kipuka-ca-rsa-2048
  ID:         01
  Usage:      encrypt, verify, wrap
Private Key Object; RSA
  label:      kipuka-ca-rsa-2048
  ID:         01
  Usage:      decrypt, sign, unwrap
```

The `ID` field value is used as the `hsm_slot` parameter in kipuka's CA configuration.

## Development Setup with Kryoptic

Kryoptic is a Rust-based software PKCS#11 implementation suitable for development and testing. It provides a lightweight alternative to hardware HSMs.

### Installation

Install Kryoptic from crates.io:

```bash
cargo install kryoptic
```

Or build from source:

```bash
git clone https://github.com/latchset/kryoptic.git
cd kryoptic
cargo build --release
```

The PKCS#11 library will be at `target/release/libkryoptic_pkcs11.so` (Linux) or `target/release/libkryoptic_pkcs11.dylib` (macOS).

### Initialize a Token

Create a Kryoptic configuration directory:

```bash
mkdir -p ~/.config/kryoptic
```

Initialize a token using `pkcs11-tool`:

```bash
pkcs11-tool --module target/release/libkryoptic_pkcs11.so \
  --init-token \
  --label "kipuka-dev" \
  --so-pin 12345678
```

Set the user PIN:

```bash
pkcs11-tool --module target/release/libkryoptic_pkcs11.so \
  --init-pin \
  --so-pin 12345678 \
  --pin 1234
```

### Generate Development Keys

Generate an RSA 2048-bit key pair:

```bash
pkcs11-tool --module target/release/libkryoptic_pkcs11.so \
  --login \
  --pin 1234 \
  --keypairgen \
  --key-type rsa:2048 \
  --id 01 \
  --label "kipuka-dev-ca"
```

### Configure kipuka

Update `kipuka.toml` to use the Kryoptic library:

```toml
[hsm]
library = "/home/user/kryoptic/target/release/libkryoptic_pkcs11.so"
token_label = "kipuka-dev"
pin_env = "KIPUKA_HSM_PIN"

[[ca]]
id = "dev-ca"
name = "Development CA"
cert = "/etc/kipuka/ca/dev-ca.pem"
hsm_slot = 1
validity_days = 365
```

Generate the CA certificate (the private key remains on Kryoptic):

```bash
export KIPUKA_HSM_PIN=1234

# Generate a self-signed CA certificate using the HSM key
openssl req -new -x509 \
  -engine pkcs11 \
  -keyform engine \
  -key "pkcs11:token=kipuka-dev;id=%01;type=private" \
  -out /etc/kipuka/ca/dev-ca.pem \
  -days 3650 \
  -subj "/CN=kipuka Development CA"
```

Start kipuka:

```bash
kipuka
```

kipuka will now use the Kryoptic HSM for all signing operations for the `dev-ca` CA.

## Full Configuration Example

The following example shows a complete HSM configuration with multiple CAs:

```toml
# HSM configuration
[hsm]
library = "/usr/lib/pkcs11/libkryoptic_pkcs11.so"
token_label = "kipuka"
pin_env = "KIPUKA_HSM_PIN"

# Server configuration
[server]
listen = "0.0.0.0:8443"
tls_cert = "/etc/kipuka/server.pem"
tls_key = "/etc/kipuka/server-key.pem"

# RSA CA using HSM key
[[ca]]
id = "hsm-rsa-ca"
name = "HSM-Protected RSA CA"
cert = "/etc/kipuka/ca/hsm-rsa-ca.pem"
hsm_slot = 1
validity_days = 365
key_usage = ["digitalSignature", "keyCertSign", "cRLSign"]

# ECDSA CA using HSM key
[[ca]]
id = "hsm-ec-ca"
name = "HSM-Protected ECDSA CA"
cert = "/etc/kipuka/ca/hsm-ec-ca.pem"
hsm_slot = 3
validity_days = 365
key_usage = ["digitalSignature", "keyCertSign", "cRLSign"]
```

Key points:

- The `hsm_slot` parameter references the object ID assigned during key generation
- When `hsm_slot` is set, the `key` parameter must be omitted—the private key exists only on the HSM
- Multiple CAs can share the same HSM by using different slot identifiers
- The CA certificate in the `cert` parameter is the public certificate; the private key remains on the HSM

## Troubleshooting

### Library Not Found

If kipuka reports that the PKCS#11 library cannot be loaded, verify:

- The library path is correct for your system
- The library file has appropriate read and execute permissions
- Required dependencies are installed (consult HSM vendor documentation)

### Authentication Failures

If kipuka reports authentication failures:

- Verify the PIN is correct using `pkcs11-tool --login`
- Check that the token is not locked due to failed login attempts
- Ensure the environment variable or PIN file is readable by the kipuka process user

### Key Not Found

If kipuka reports that the key cannot be found in the HSM:

- List objects with `pkcs11-tool --list-objects` and verify the key exists
- Ensure the `hsm_slot` value matches the key's `ID` field
- Check that the token label or slot number is correct

### Performance Considerations

HSM signing operations have higher latency than software signing. For high-throughput deployments:

- Use hardware HSMs with dedicated crypto acceleration
- Consider load balancing across multiple kipuka instances
- Monitor HSM session limits and adjust `max_sessions` if supported by your HSM
