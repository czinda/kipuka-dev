# CoAP Transport

kipuka supports EST-over-CoAP (RFC 9483) for constrained IoT devices. This enables lightweight certificate enrollment over UDP with DTLS protection, reducing overhead compared to HTTP/TLS while maintaining security.

## Overview

CoAP (Constrained Application Protocol, RFC 7252) is designed for resource-constrained devices with limited power, memory, and bandwidth. EST-over-CoAP adapts the EST protocol to CoAP's request/response model, making it suitable for:

- IoT sensors and actuators
- Embedded devices with limited RAM (< 1 MB)
- Low-power wireless networks (LoRaWAN, NB-IoT, 802.15.4)
- Environments where TCP overhead is prohibitive

The `kipuka-coap` crate implements the full RFC 9483 specification with DTLS 1.2/1.3 support, block-wise transfer for large payloads (critical for post-quantum certificates), and session resumption.

## Implementation Architecture

The CoAP transport is implemented across two layers:

- **`kipuka-coap` crate** -- Contains the `CoapDtlsServer` that manages the UDP listener and DTLS sessions (via OpenSSL), parses CoAP messages, handles block-wise transfer reassembly, and dispatches EST operations through the `EstHandler` trait.
- **`CoapEstHandler`** (in the main `kipuka-est` crate) -- Implements the `EstHandler` trait, bridging parsed CoAP requests to the same CA signing, CSR validation, and certificate issuance logic used by the HTTPS transport. This ensures both transports produce identical certificates and audit records.

When CoAP is enabled, `CoapDtlsServer::run()` is called at startup alongside the axum HTTP server. Both listeners share the same `AppState`, CA configurations, and database connections.

Currently supported EST operations over CoAP:

| Operation | Status |
|-----------|--------|
| `/cacerts` (GET /crts) | Implemented |
| `/simpleenroll` (POST /sen) | Implemented |
| `/simplereenroll` (POST /sren) | Implemented |
| `/csrattrs` (GET /att) | Implemented |
| `/serverkeygen` (POST /skg) | Not yet implemented over CoAP |

## Configuration

Enable CoAP in `kipuka.toml` under the `[coap]` section:

```toml
[coap]
enabled = true
listen_addr = "0.0.0.0:5684"
dtls_enabled = true
block_size = 512
max_payload = 65536
session_timeout_secs = 300
max_sessions = 1024
```

### Configuration Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `enabled` | bool | `false` | Enable CoAP transport |
| `listen_addr` | String | `"0.0.0.0:5684"` | UDP socket address (5684 is IANA-assigned for DTLS) |
| `dtls_enabled` | bool | `true` | Require DTLS encryption (strongly recommended) |
| `block_size` | u16 | `512` | Block size for block-wise transfer (16/32/64/128/256/512/1024) |
| `max_payload` | usize | `65536` | Maximum CoAP payload size (64 KB) |
| `session_timeout_secs` | u64 | `300` | DTLS session idle timeout (5 minutes) |
| `max_sessions` | usize | `1024` | Maximum concurrent DTLS sessions |

**Security Note:** Always enable `dtls_enabled = true` in production. Plain CoAP exposes CSRs and certificates in cleartext over the network.

## DTLS Setup

kipuka supports DTLS 1.2 (RFC 6347) and DTLS 1.3 (RFC 9147) for encrypted CoAP transport. DTLS provides:

- Encryption and integrity protection equivalent to TLS
- UDP-friendly handshake with retransmission
- Session resumption to reduce handshake overhead
- Client authentication via PSK or certificates (mTLS)

### DTLS Configuration

DTLS shares TLS certificates from the main `[tls]` section:

```toml
[tls]
cert_chain = "/path/to/server-chain.pem"
private_key = "/path/to/server-key.pem"
ca_bundle = "/path/to/trusted-cas.pem"
```

For PSK-based DTLS (pre-shared key authentication):

```toml
[coap]
dtls_psk_enabled = true
dtls_psk_identity = "IoTDevice001"
dtls_psk_key_hex = "deadbeef..."  # Hex-encoded shared secret
```

### Session Resumption

DTLS session resumption cache reduces handshake latency for returning clients:

- Session ID-based resumption (DTLS 1.2)
- Ticket-based resumption (DTLS 1.3, RFC 8446)
- Cache expires after `session_timeout_secs`

## EST Path Mapping

RFC 9483 section 5.1 defines CoAP path segments for EST operations. kipuka maps standard EST endpoints to shortened CoAP paths:

| CoAP Path | EST Endpoint | HTTP Method | CoAP Method | Description |
|-----------|--------------|-------------|-------------|-------------|
| `/sen` | `/simpleenroll` | POST | POST | Simple enrollment (CSR → certificate) |
| `/sren` | `/simplereenroll` | POST | POST | Simple re-enrollment (renewal with proof-of-possession) |
| `/skg` | `/serverkeygen` | POST | POST | Server-side key generation |
| `/att` | `/csrattrs` | GET | GET | CSR attributes hint |
| `/cacerts` or `/crts` | `/cacerts` | GET | GET | CA certificate chain |

**Example:** To enroll a device, send a POST to `coaps://est.example.com:5684/sen` with the CSR in PKCS#10 format.

## Content-Format IDs

CoAP uses numeric Content-Format IDs instead of MIME strings. RFC 9483 section 5.4 assigns:

| ID | MIME Type | Usage |
|----|-----------|-------|
| 280 | `application/pkcs7-mime; smime-type=server-generated` | Server-generated key response |
| 281 | `application/pkcs7-mime; smime-type=certs-only` | Certificate-only response (cacerts, enroll) |
| 285 | `application/pkcs10` | PKCS#10 CSR request |
| 286 | `application/pkcs8` | PKCS#8 encrypted private key |
| 287 | `application/csrattrs` | CSR attributes response |

Request and response payloads use these IDs in the CoAP Content-Format option.

## Block-Wise Transfer

CoAP message size is limited by UDP MTU (typically 1280 bytes for IPv6). Block-wise transfer (RFC 7959) splits large payloads across multiple CoAP messages using Block1 (request) and Block2 (response) options.

### Why Block Transfer Matters

Post-quantum certificates (ML-DSA-87 signatures) can exceed 7 KB. A typical PQC certificate chain:

- Root CA cert: ~3 KB (ML-DSA-87 signature)
- Intermediate CA cert: ~3.5 KB
- End-entity cert: ~4 KB
- **Total:** ~10.5 KB → requires ~21 blocks at 512-byte block size

### Configuration

Set `block_size` to match your network's MTU constraints:

- **16-64 bytes:** Very constrained links (802.15.4)
- **128-256 bytes:** Low-power WAN (NB-IoT, LoRa)
- **512 bytes (default):** General IoT deployments
- **1024 bytes:** High-bandwidth local networks

**Trade-off:** Larger blocks reduce round trips but increase packet loss impact.

### Example Flow

Client requests `/cacerts` with Block2 option:

1. Client: `GET /cacerts`, Block2: `0/0/512` (request 512-byte blocks)
2. Server: `2.05 Content`, Block2: `0/1/512` (block 0, more blocks follow)
3. Client: `GET /cacerts`, Block2: `1/0/512` (request next block)
4. Server: `2.05 Content`, Block2: `1/1/512` (block 1, more blocks)
5. ...
6. Server: `2.05 Content`, Block2: `20/0/512` (final block)

## Example with coap-client

Install `libcoap` tools:

```bash
# Fedora/RHEL
sudo dnf install libcoap

# Ubuntu/Debian
sudo apt install libcoap2-bin
```

### Fetch CA certificates

```bash
coap-client -m get \
  coaps://est.example.com:5684/cacerts \
  -u Client001 -k deadbeef... \
  -B 512 \
  -o cacerts.p7
```

- `-m get`: GET method
- `-u/-k`: DTLS PSK identity and key (hex)
- `-B 512`: Request 512-byte blocks
- `-o`: Save response to file

### Simple enrollment

```bash
# Generate CSR
openssl req -new -newkey rsa:2048 -nodes \
  -keyout device.key -out device.csr

# Convert CSR to DER
openssl req -in device.csr -outform DER -out device.csr.der

# Send enrollment request
coap-client -m post \
  coaps://est.example.com:5684/sen \
  -u Client001 -k deadbeef... \
  -f device.csr.der \
  -t application/pkcs10 \
  -B 512 \
  -o device-cert.p7
```

- `-f`: Request payload file
- `-t`: Content-Type (use MIME string; libcoap translates to ID 285)

## Troubleshooting

### DTLS handshake fails

**Symptom:** Client timeout or "DTLS handshake failed" error.

**Causes:**
- Firewall blocking UDP port 5684
- Mismatched PSK identity or key
- Client doesn't support DTLS 1.2/1.3
- Certificate verification failure (mTLS mode)

**Debug:**
```bash
# Enable verbose logging
coap-client -v 9 ...

# Check kipuka logs
journalctl -u kipuka -f | grep -i dtls
```

### Block transfer incomplete

**Symptom:** Partial payload received, transfer hangs.

**Causes:**
- Network packet loss exceeds retransmission limits
- `block_size` too large for MTU
- `max_payload` too small for certificate chain

**Fix:**
- Reduce `block_size` to 256 or 128
- Increase `max_payload` to 131072 (128 KB)
- Check network MTU: `ip link show | grep mtu`

### Session timeout errors

**Symptom:** "Session expired" after idle period.

**Cause:** Client inactive for > `session_timeout_secs`.

**Fix:**
- Increase `session_timeout_secs` to 600 (10 minutes)
- Implement session resumption in client
- Send periodic keepalive messages

### Max sessions exceeded

**Symptom:** New clients refused with "Too many sessions".

**Cause:** `max_sessions` limit reached (zombie sessions).

**Fix:**
- Increase `max_sessions` to 2048
- Reduce `session_timeout_secs` to 120 (2 minutes)
- Restart kipuka to clear session cache

## Performance Considerations

### Memory Usage

Each DTLS session consumes ~10-20 KB RAM:
- DTLS 1.2 state: ~8 KB
- DTLS 1.3 state: ~12 KB
- Session resumption cache: ~2 KB per session

**1024 sessions** → ~12-24 MB RAM overhead.

### Throughput

CoAP throughput is limited by:
- UDP round-trip time (RTT)
- Block-wise transfer overhead
- DTLS cryptographic processing

**Example:** 10 KB certificate chain, 512-byte blocks, 50ms RTT:
- 20 blocks × 1 round trip each = 20 RTT
- Total time: 20 × 50ms = 1 second

Larger block sizes reduce latency but require higher MTU.

## Security Recommendations

1. **Always enable DTLS** (`dtls_enabled = true`)
2. **Use strong PSK keys** (≥ 128 bits entropy)
3. **Rotate PSK keys** regularly (monthly for IoT)
4. **Limit session lifetime** (`session_timeout_secs ≤ 600`)
5. **Monitor session count** (alert on `max_sessions` threshold)
6. **Validate client certificates** (mTLS mode) or OTP (EST enrollment)
7. **Use firewall rules** to restrict CoAP port 5684 to authorized subnets
8. **Enable audit logging** for all enrollment requests

## Deployment Notes

### UDP Port and Firewall

The IANA-assigned port for CoAP over DTLS is **5684**. Ensure your firewall allows inbound UDP on this port:

```bash
# firewalld (Fedora/RHEL)
sudo firewall-cmd --permanent --add-port=5684/udp
sudo firewall-cmd --reload

# iptables
sudo iptables -A INPUT -p udp --dport 5684 -j ACCEPT
```

### Container Deployment

When running kipuka in a container, expose both the HTTPS and CoAP/DTLS ports:

```bash
podman run --rm \
  -v ./kipuka.toml:/etc/kipuka/kipuka.toml:ro \
  -v ./certs:/etc/kipuka/certs:ro \
  -p 9443:9443 \
  -p 5684:5684/udp \
  registry.kipuka.dev/kipuka:latest
```

Note the `/udp` suffix on port 5684 -- without it, only TCP is exposed.

### DTLS Certificate and Key

The CoAP/DTLS listener shares the TLS certificate and private key from the `[tls]` section. No separate certificate configuration is needed:

```toml
[tls]
cert_chain = "/etc/kipuka/certs/server-chain.pem"
private_key = "/etc/kipuka/certs/server-key.pem"
ca_bundle = "/etc/kipuka/certs/trusted-cas.pem"

[coap]
enabled = true
listen_addr = "0.0.0.0:5684"
dtls_enabled = true
```

### Full Configuration Example

A minimal configuration enabling both HTTPS and CoAP transports:

```toml
[server]
listen_addr = "0.0.0.0:9443"

[tls]
cert_chain = "/etc/kipuka/certs/server-chain.pem"
private_key = "/etc/kipuka/certs/server-key.pem"
ca_bundle = "/etc/kipuka/certs/trusted-cas.pem"

[[ca]]
id = "iot-ca"
cert = "/etc/kipuka/certs/iot-ca.pem"
key = "/etc/kipuka/certs/iot-ca-key.pem"
chain = "/etc/kipuka/certs/iot-ca-chain.pem"
validity_days = 365

[database]
url = "sqlite:///var/lib/kipuka/kipuka.db"

[coap]
enabled = true
listen_addr = "0.0.0.0:5684"
dtls_enabled = true
block_size = 512
max_payload = 65536
session_timeout_secs = 300
max_sessions = 1024
```

## References

- RFC 9483: Constrained Application Protocol (CoAP) over DTLS for EST
- RFC 7252: The Constrained Application Protocol (CoAP)
- RFC 7959: Block-Wise Transfers in CoAP
- RFC 6347: Datagram Transport Layer Security (DTLS) 1.2
- RFC 9147: The Datagram Transport Layer Security (DTLS) 1.3
- RFC 7030: Enrollment over Secure Transport (EST)
