# EST Endpoints

kipuka implements the six operations defined by
[RFC 7030](https://www.rfc-editor.org/rfc/rfc7030) (Enrollment over Secure
Transport) and the clarifications in
[RFC 8951](https://www.rfc-editor.org/rfc/rfc8951).  All EST operations are
served under the `/.well-known/est/` path on the EST listener (default port
9443).

## Base URL and EST labels

The base URL for all operations is:

```
https://<host>:9443/.well-known/est/
```

When EST labels are configured, a label segment is inserted between `/est/`
and the operation name to route the request to a specific CA:

```
https://<host>:9443/.well-known/est/{label}/simpleenroll
```

For example, if two labels are configured -- `iot-fleet` backed by a
hardware-HSM CA and `corp-devices` backed by a Dogtag CA -- clients target the
appropriate CA by including the label in the URL:

```
/.well-known/est/iot-fleet/simpleenroll
/.well-known/est/corp-devices/simpleenroll
```

Requests to the unlabeled path (`/.well-known/est/simpleenroll`) use the
default CA.  See [EST Labels](../operator/est-labels.md) for configuration
details.

## Content types

EST uses CMS (PKCS #7) encoding throughout.  All request and response bodies
are base64-encoded DER unless otherwise noted.

| Direction | Content-Type | Encoding |
| --------- | ------------ | -------- |
| CSR request | `application/pkcs10` | base64-encoded DER PKCS #10 |
| Certificate response | `application/pkcs7-mime; smime-type=certs-only` | base64-encoded DER PKCS #7 |
| CMC request | `application/pkcs7-mime; smime-type=CMC-request` | base64-encoded DER CMS |
| CMC response | `application/pkcs7-mime; smime-type=CMC-response` | base64-encoded DER CMS |
| Server keygen response | `multipart/mixed` | See [Server-Side Key Generation](#post-serverkeygen) |
| CSR attributes | `application/csrattrs` | base64-encoded DER |

---

## GET /cacerts

Retrieve the CA certificate chain.  This operation requires no authentication
and is typically the first call a client makes to bootstrap trust.

**Authentication:** None

**Response:** `200 OK` with Content-Type `application/pkcs7-mime; smime-type=certs-only`.
The body is a base64-encoded PKCS #7 `certs-only` message containing the CA
certificate chain in order from the issuing CA to the root.

### Example

```bash
# Fetch the CA chain (no auth required)
curl -o cacerts.p7b \
  https://est.example.com:9443/.well-known/est/cacerts

# Decode the base64 PKCS#7 and view the certificates
base64 -d cacerts.p7b | openssl pkcs7 -inform DER -print_certs -noout

# Save decoded certificates to a PEM file
base64 -d cacerts.p7b | openssl pkcs7 -inform DER -print_certs -out ca-chain.pem
```

With an EST label:

```bash
curl -o cacerts.p7b \
  https://est.example.com:9443/.well-known/est/iot-fleet/cacerts
```

---

## POST /simpleenroll

Submit a PKCS #10 certificate signing request (CSR) for initial enrollment.
The server validates the request, signs the certificate using the configured CA,
and returns the signed certificate in a PKCS #7 response.

**Authentication:** OTP (HTTP Basic) or mTLS (client certificate).

For initial enrollment of a device that does not yet have a certificate, use
OTP authentication.  For enrollment of a device that already holds a valid
certificate from a trusted CA, use mTLS.

**Request body:** base64-encoded DER PKCS #10 CSR, Content-Type `application/pkcs10`.

**Response:** `200 OK` with Content-Type `application/pkcs7-mime; smime-type=certs-only`.

### Example with OTP authentication

```bash
# Generate a private key and CSR
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout device.key -out device.csr -nodes \
  -subj "/CN=device-001.example.com"

# Base64-encode the CSR (DER format)
openssl req -in device.csr -outform DER | base64 > device.csr.b64

# Enroll using OTP (entity-id:otp-value as HTTP Basic auth)
curl -X POST \
  --cacert ca-chain.pem \
  -u "device-001:a7f3b9c2d1e4" \
  -H "Content-Type: application/pkcs10" \
  --data-binary @device.csr.b64 \
  -o enrolled.p7b \
  https://est.example.com:9443/.well-known/est/simpleenroll

# Decode the response to get the signed certificate
base64 -d enrolled.p7b | openssl pkcs7 -inform DER -print_certs -out device.crt
```

### Example with mTLS authentication

```bash
# Enroll using an existing client certificate for authentication
curl -X POST \
  --cacert ca-chain.pem \
  --cert existing-device.crt \
  --key existing-device.key \
  -H "Content-Type: application/pkcs10" \
  --data-binary @device.csr.b64 \
  -o enrolled.p7b \
  https://est.example.com:9443/.well-known/est/simpleenroll
```

### Example with an EST label

```bash
curl -X POST \
  --cacert ca-chain.pem \
  -u "device-001:a7f3b9c2d1e4" \
  -H "Content-Type: application/pkcs10" \
  --data-binary @device.csr.b64 \
  -o enrolled.p7b \
  https://est.example.com:9443/.well-known/est/corp-devices/simpleenroll
```

---

## POST /simplereenroll

Renew or rekey an existing certificate.  The client authenticates with its
current certificate via mTLS and submits a new CSR.  The server validates that
the CSR subject matches the authenticated client certificate (or that the
change is permitted by policy) and returns a fresh certificate.

**Authentication:** mTLS required.  The client must present the certificate
being renewed.

**Request body:** base64-encoded DER PKCS #10 CSR, Content-Type `application/pkcs10`.

**Response:** `200 OK` with Content-Type `application/pkcs7-mime; smime-type=certs-only`.

### Example

```bash
# Generate a new CSR using the existing key (or a new key for rekeying)
openssl req -new -key device.key -out renew.csr -nodes \
  -subj "/CN=device-001.example.com"

# Base64-encode the CSR
openssl req -in renew.csr -outform DER | base64 > renew.csr.b64

# Re-enroll using the current device certificate for mTLS auth
curl -X POST \
  --cacert ca-chain.pem \
  --cert device.crt \
  --key device.key \
  -H "Content-Type: application/pkcs10" \
  --data-binary @renew.csr.b64 \
  -o renewed.p7b \
  https://est.example.com:9443/.well-known/est/simplereenroll

# Decode the renewed certificate
base64 -d renewed.p7b | openssl pkcs7 -inform DER -print_certs -out device-renewed.crt
```

---

## POST /fullcmc

Full Certificate Management over CMS (RFC 5272).  This operation accepts a
full CMC request wrapped in a CMS `SignedData` structure and returns a full CMC
response.  Full CMC supports advanced features not available through simple
enrollment: certificate revocation, key update with proof-of-possession, and
batch operations.

**Authentication:** The CMC request itself carries authentication (the CMS
`SignedData` is signed by the requester).  mTLS may also be required depending
on server policy.

**Request body:** base64-encoded DER CMS, Content-Type
`application/pkcs7-mime; smime-type=CMC-request`.

**Response:** `200 OK` with Content-Type
`application/pkcs7-mime; smime-type=CMC-response`.

### Example

```bash
# Full CMC requests are typically constructed by a CMC-aware client library.
# This example uses a pre-built CMC request.
curl -X POST \
  --cacert ca-chain.pem \
  --cert ra-agent.crt \
  --key ra-agent.key \
  -H "Content-Type: application/pkcs7-mime; smime-type=CMC-request" \
  --data-binary @cmc-request.b64 \
  -o cmc-response.p7b \
  https://est.example.com:9443/.well-known/est/fullcmc

# Decode the CMC response
base64 -d cmc-response.p7b | openssl cms -inform DER -cmsout -print
```

> **Note:** Full CMC support requires the `fullcmc` feature in the server
> configuration.  When Dogtag PKI is the back-end CA, CMC requests are
> forwarded to the Dogtag CMC profile.

---

## POST /serverkeygen

Request server-side key generation.  The server generates a key pair, signs the
certificate, and returns both the certificate and the encrypted private key.
This operation is used in environments where the client device cannot generate
strong keys locally, or where key escrow through a Key Recovery Authority (KRA)
is required.

**Authentication:** OTP (HTTP Basic) or mTLS.

**Request body:** base64-encoded DER PKCS #10 CSR, Content-Type `application/pkcs10`.
The CSR provides the subject and requested attributes; the public key in the
CSR is replaced by the server-generated key.

**Response:** `200 OK` with Content-Type `multipart/mixed`.  The response
contains two parts:

| Part | Content-Type | Contents |
| ---- | ------------ | -------- |
| 1 | `application/pkcs7-mime; smime-type=certs-only` | Signed certificate (base64 PKCS #7) |
| 2 | `application/pkcs8` | Encrypted private key (base64 PKCS #8) |

The private key is encrypted to the client using the asymmetric key from the
CSR or a pre-shared symmetric key, depending on configuration.

### Example

```bash
# Generate a throwaway CSR (the server will generate the real key pair)
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout throwaway.key -out serverkeygen.csr -nodes \
  -subj "/CN=device-002.example.com"

# Base64-encode
openssl req -in serverkeygen.csr -outform DER | base64 > serverkeygen.csr.b64

# Request server-side key generation
curl -X POST \
  --cacert ca-chain.pem \
  -u "device-002:b8e4c1d5f2a7" \
  -H "Content-Type: application/pkcs10" \
  --data-binary @serverkeygen.csr.b64 \
  -o serverkeygen-response.mime \
  https://est.example.com:9443/.well-known/est/serverkeygen

# The response is multipart/mixed -- extract the certificate and key
# (exact parsing depends on the MIME boundary in the response headers)
```

> **Note:** Server-side key generation requires a KRA (Key Recovery Authority)
> when key escrow is mandated by policy.  With Dogtag PKI, the KRA subsystem
> handles key archival automatically.

---

## GET /csrattrs

Retrieve the set of CSR attributes that the server expects or recommends
clients include in their certificate signing requests.  The response is an
ASN.1 sequence of OIDs and attribute definitions.

**Authentication:** None (or mTLS, depending on server policy).

**Response:** `200 OK` with Content-Type `application/csrattrs`.  The body is
a base64-encoded DER `CsrAttrs` structure as defined in RFC 7030 Section 4.5.2.

### Example

```bash
# Fetch supported CSR attributes
curl --cacert ca-chain.pem \
  -o csrattrs.b64 \
  https://est.example.com:9443/.well-known/est/csrattrs

# Decode and inspect (requires ASN.1 tools)
base64 -d csrattrs.b64 | openssl asn1parse -inform DER
```

Typical attributes returned include:

- **ecPublicKey** with **secp256r1** or **secp384r1** -- indicating preferred
  key algorithms
- **challengePassword** -- when the server requires a challenge in the CSR
- **Extension requests** -- specific X.509v3 extensions the server will honor

---

## Error responses

All EST endpoints return standard HTTP error codes.  The response body for
errors is `application/json` on the admin API and plain text on the EST
endpoints.

| Status | Meaning | When returned |
| ------ | ------- | ------------- |
| `400 Bad Request` | Malformed CSR, invalid base64 encoding, missing Content-Type, or CSR fails policy validation. | Any POST endpoint |
| `401 Unauthorized` | Missing or invalid authentication.  For OTP: the OTP value is wrong, expired, or already consumed.  For mTLS: no client certificate presented or the certificate is not trusted. | `/simpleenroll`, `/simplereenroll`, `/serverkeygen` |
| `403 Forbidden` | Authentication succeeded but the client is not authorized for the requested operation.  Common cause: re-enrollment with a certificate whose subject does not match the CSR. | `/simplereenroll` |
| `404 Not Found` | Unknown EST label. | Any endpoint with an invalid label |
| `500 Internal Server Error` | Server-side failure: HSM unreachable, database error, or CA signing failure. | Any endpoint |
| `503 Service Unavailable` | The requested CA is temporarily unavailable (all replicas down, HSM session exhausted). | Any endpoint |

### Retry-After

When an operation requires asynchronous processing (for example, a Dogtag PKI
back-end that queues signing requests for RA approval), the server returns
`202 Accepted` with a `Retry-After` header indicating the number of seconds
the client should wait before polling.

```
HTTP/1.1 202 Accepted
Retry-After: 30
Content-Length: 0
```

The client should repeat the same request (with the same CSR and
authentication) after the indicated interval.  The server tracks pending
requests and returns the signed certificate when it becomes available, or
another `202` if the request is still pending.

### Example: handling a 401

```bash
# A failed OTP enrollment returns 401
curl -v -X POST \
  --cacert ca-chain.pem \
  -u "device-001:wrong-otp-value" \
  -H "Content-Type: application/pkcs10" \
  --data-binary @device.csr.b64 \
  https://est.example.com:9443/.well-known/est/simpleenroll

# Response:
# < HTTP/1.1 401 Unauthorized
# < WWW-Authenticate: Basic realm="est"
```

---

## TLS requirements

The EST listener enforces TLS 1.2 or 1.3 for all connections.  The server
certificate must be configured in `[tls]` in the kipuka configuration file.

For mTLS-authenticated endpoints, the server's TLS configuration must include a
`client_ca` trust anchor that covers the certificates clients present.  See
[TLS Configuration](../operator/tls.md) for details.

```bash
# Verify server TLS configuration
openssl s_client -connect est.example.com:9443 -showcerts </dev/null
```
