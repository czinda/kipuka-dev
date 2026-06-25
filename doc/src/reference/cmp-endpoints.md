# CMP Endpoints

kipuka implements the Certificate Management Protocol (CMP, RFC 4210 / RFC 9810) for automated certificate lifecycle management. CMP provides a standardized framework for certificate requests, renewals, revocations, and CA interactions with cryptographic protection.

## Endpoint

CMP operations are served at the IANA-assigned well-known URI:

```
POST /.well-known/cmp
```

This single endpoint handles all CMP message types, with the operation determined by the `PKIMessage` body type.

## Request Format

### HTTP Headers

```http
POST /.well-known/cmp HTTP/1.1
Host: ca.example.com
Content-Type: application/pkixcmp
Content-Length: 1234

[Binary PKIMessage]
```

### Content Type

- **Request:** `application/pkixcmp`
- **Response:** `application/pkixcmp`

CMP messages are ASN.1 DER-encoded structures defined in RFC 4210 section 5.1.

## Response Format

```http
HTTP/1.1 200 OK
Content-Type: application/pkixcmp
Content-Length: 5678

[Binary PKIMessage response]
```

**Note:** CMP always returns HTTP 200 OK. Error conditions are encoded in the `PKIStatus` field of the `PKIMessage` body, not HTTP status codes.

## Message Types

CMP supports the following request/response pairs:

| Request Type | Code | Description | Response Type | Code |
|--------------|------|-------------|---------------|------|
| **ir** (Initialization Request) | 0 | Initial certificate request from new entity | **ip** (Initialization Response) | 1 |
| **cr** (Certification Request) | 2 | Certificate request from existing entity | **cp** (Certification Response) | 3 |
| **kur** (Key Update Request) | 7 | Certificate renewal with new key pair | **kup** (Key Update Response) | 8 |
| **rr** (Revocation Request) | 11 | Certificate revocation request | **rp** (Revocation Response) | 12 |
| **error** | 23 | Error message (response only) | N/A | N/A |

### Initialization Request (ir → ip)

Used for first-time enrollment when the entity has no existing certificate from the CA.

**Request fields:**
- `certReqId`: Integer identifier for this request
- `certTemplate`: Certificate template with subject DN, public key, extensions
- `popo`: Proof of possession (signature, key agreement, or key encipherment)

**Response fields:**
- `certReqId`: Matches request ID
- `status`: PKIStatusInfo (granted/rejected/waiting)
- `certifiedKeyPair`: Issued certificate + optional encrypted private key
- `rspInfo`: Additional response information (OCSPResponse, timestampToken)

### Certification Request (cr → cp)

Used for subsequent certificate requests when the entity already has a certificate from the CA.

**Differences from ir:**
- Request must be signature-protected using existing certificate
- May reference existing certificate in `oldCertId`
- CA may skip out-of-band verification (already authenticated)

### Key Update Request (kur → kup)

Used for certificate renewal with a new key pair. Similar to `cr` but explicitly signals key rollover.

**Request fields:**
- `certTemplate`: New subject DN (if changing), new public key, validity period
- `oldCertId`: Reference to certificate being renewed

**Response:**
- New certificate with updated `serialNumber` and `subjectPublicKeyInfo`
- Original subject DN preserved (unless change requested)

### Revocation Request (rr → rp)

Revokes an issued certificate.

**Request fields:**
- `certDetails`: Certificate serial number + issuer DN to revoke
- `crlEntryDetails`: Optional revocation reason (keyCompromise, affiliationChanged, cessationOfOperation, etc.)

**Response:**
- `status`: Revocation accepted/rejected
- `revCerts`: List of revoked certificate identifiers

## Protection Methods

CMP messages must be cryptographically protected to prevent tampering and verify sender identity. kipuka supports two protection mechanisms:

### 1. MAC-Based Protection (Shared Secret)

Uses HMAC-SHA256 with a pre-shared secret (password or OTP).

**Protection fields:**
```asn1
protectionAlg: id-PasswordBasedMac (1.2.840.113533.7.66.13)
  salt: OCTET STRING (16 bytes, random)
  iterationCount: INTEGER (10000)
  mac: AlgorithmIdentifier (hmacWithSHA256)
protection: BIT STRING (HMAC-SHA256 digest)
```

**Use case:** Initial enrollment when client has no certificate yet.

**Security:** Shared secret must be delivered out-of-band (OTP, provisioning portal, physical token).

### 2. Signature-Based Protection (Certificate)

Uses the entity's existing certificate to sign the message.

**Protection fields:**
```asn1
protectionAlg: sha256WithRSAEncryption (or ECDSA/Ed25519)
senderKID: KeyIdentifier (SKI of signing cert)
protection: BIT STRING (Digital signature)
extraCerts: [1] SEQUENCE OF Certificate (signing cert + chain)
```

**Use case:** Re-enrollment, key update, revocation (client already has valid certificate).

**Verification:** kipuka validates signature against `extraCerts` chain and checks revocation status (CRL/OCSP).

## Status Codes

The `PKIStatusInfo` structure in responses contains:

| Status Code | Name | Description |
|-------------|------|-------------|
| 0 | **accepted** | Request granted, certificate issued |
| 1 | **grantedWithMods** | Granted but some requested values modified (e.g., validity period) |
| 2 | **rejection** | Request rejected (see `failInfo` for reason) |
| 3 | **waiting** | Request pending manual approval (CA policy) |
| 4 | **revocationWarning** | Certificate issued but old cert revocation failed |
| 5 | **revocationNotification** | Certificate not issued due to revocation issue |
| 6 | **keyUpdateWarning** | Key update succeeded but with warnings |

### Failure Reasons (failInfo)

When `status = rejection`, the `failInfo` bit string indicates why:

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | badAlg | Unacceptable algorithm (e.g., MD5, RSA-1024) |
| 1 | badMessageCheck | Message integrity check failed |
| 2 | badRequest | Malformed request (invalid ASN.1) |
| 5 | badDataFormat | Incorrect data encoding |
| 14 | badCertTemplate | Invalid certificate template (e.g., subject DN constraints) |
| 17 | notAuthorized | Authentication failed or insufficient privileges |

## Error Handling

### Client Errors (Invalid Requests)

kipuka returns HTTP 400 Bad Request for:
- Invalid Content-Type (not `application/pkixcmp`)
- Malformed ASN.1 DER encoding
- Missing required `PKIMessage` fields

### CMP-Level Errors

CMP protocol errors return HTTP 200 OK with an `error` message type (code 23):

```asn1
PKIMessage {
  header: { sender, recipient, messageTime, transactionID }
  body: error [23] {
    pKIStatusInfo: {
      status: rejection (2)
      statusString: "MAC verification failed"
      failInfo: badMessageCheck (bit 1)
    }
    errorCode: INTEGER (optional)
    errorDetails: UTF8String (optional)
  }
}
```

### Server Errors (CA Unavailable)

If the CA backend is unreachable or times out, kipuka returns:

```http
HTTP/1.1 503 Service Unavailable
Retry-After: 60

CA temporarily unavailable
```

## Examples

### Example 1: Initial Enrollment (MAC-Protected)

**Request:**
```http
POST /.well-known/cmp HTTP/1.1
Host: ca.example.com
Content-Type: application/pkixcmp
Content-Length: 832

[Binary PKIMessage with ir body, MAC protection]
```

**Key fields:**
- `body.ir.certReqMsg.certTemplate.subject`: CN=device001.example.com
- `body.ir.certReqMsg.certTemplate.publicKey`: RSA 2048-bit public key
- `protectionAlg`: id-PasswordBasedMac with HMAC-SHA256
- `protection`: HMAC computed over entire message

**Response:**
```http
HTTP/1.1 200 OK
Content-Type: application/pkixcmp
Content-Length: 1456

[Binary PKIMessage with ip body]
```

**Key fields:**
- `body.ip.status.status`: accepted (0)
- `body.ip.certifiedKeyPair.certOrEncCert`: Issued X.509 certificate (DER)

### Example 2: Renewal (Signature-Protected)

**Request:**
```http
POST /.well-known/cmp HTTP/1.1
Host: ca.example.com
Content-Type: application/pkixcmp
Content-Length: 1124

[Binary PKIMessage with kur body, signature protection]
```

**Key fields:**
- `body.kur.certTemplate.publicKey`: New RSA 3072-bit public key
- `body.kur.oldCertId`: Serial number of certificate being renewed
- `protectionAlg`: sha256WithRSAEncryption
- `protection`: Digital signature using old certificate's private key
- `extraCerts`: [old_cert, issuing_ca_cert]

**Response:**
```http
HTTP/1.1 200 OK
Content-Type: application/pkixcmp
Content-Length: 1489

[Binary PKIMessage with kup body]
```

**Key fields:**
- `body.kup.status.status`: accepted (0)
- `body.kup.certifiedKeyPair.certOrEncCert`: New certificate with updated key and serial

### Example 3: Revocation

**Request:**
```http
POST /.well-known/cmp HTTP/1.1
Host: ca.example.com
Content-Type: application/pkixcmp
Content-Length: 892

[Binary PKIMessage with rr body]
```

**Key fields:**
- `body.rr.certDetails.serialNumber`: 0x123456789abcdef
- `body.rr.certDetails.issuer`: CN=Kipuka Issuing CA
- `body.rr.crlEntryDetails.reasonCode`: keyCompromise (1)

**Response:**
```http
HTTP/1.1 200 OK
Content-Type: application/pkixcmp
Content-Length: 456

[Binary PKIMessage with rp body]
```

**Key fields:**
- `body.rp.status[0].status`: accepted (0)
- `body.rp.revCerts[0].certId`: Matches request serialNumber

## curl Examples

### Generate CMP ir message with OpenSSL

```bash
# Generate key pair
openssl genrsa -out device.key 2048

# Create CMP initialization request (requires OpenSSL CMP support)
openssl cmp -cmd ir \
  -server ca.example.com:8080/.well-known/cmp \
  -path /.well-known/cmp \
  -ref device001 \
  -secret "OTP:abc123def456" \
  -newkey device.key \
  -subject "/CN=device001.example.com/O=Example Inc" \
  -certout device.pem

# OpenSSL handles PKIMessage encoding, MAC protection, and response parsing
```

**Note:** OpenSSL 3.0+ includes built-in CMP client support. For older versions, use third-party tools like `libcmp` or Python `asn1crypto`.

### Raw curl (for debugging)

```bash
# Construct PKIMessage manually (requires ASN.1 encoding library)
# Example: Python script using asn1crypto or pyasn1

python3 cmp_client.py \
  --operation ir \
  --subject "CN=device002.example.com" \
  --key device.key \
  --secret "abc123" \
  --output ir.der

# Send to server
curl -X POST https://ca.example.com/.well-known/cmp \
  -H "Content-Type: application/pkixcmp" \
  --data-binary @ir.der \
  -o ip.der

# Parse response
openssl asn1parse -inform DER -in ip.der
```

## Security Considerations

1. **Always use HTTPS** for CMP transport (TLS 1.2+ with strong ciphers)
2. **Validate MAC/signature** before processing requests (prevent replay attacks)
3. **Use nonces and transaction IDs** to prevent replay (RFC 9480)
4. **Rotate shared secrets** regularly (monthly for OTP-based enrollment)
5. **Check certificate revocation status** before accepting signature-protected requests
6. **Limit request rate** to prevent DoS (max 10 requests/min per client)
7. **Audit all operations** (enrollment, renewal, revocation) with client identity

## Configuration

Enable CMP in `kipuka.toml`:

```toml
[cmp]
enabled = true
endpoint_path = "/.well-known/cmp"
max_message_size = 65536  # 64 KB
mac_iterations = 10000    # PBKDF2 iterations for MAC protection
signature_verify_chain = true
require_popo = true       # Require proof-of-possession
allowed_algorithms = ["RSA-2048", "RSA-3072", "RSA-4096", "ECDSA-P256", "ECDSA-P384", "Ed25519"]
```

## References

- RFC 4210: Internet X.509 Public Key Infrastructure Certificate Management Protocol (CMP)
- RFC 9480: Certificate Management Protocol (CMP) Updates (nonce, transaction ID)
- RFC 9810: Update to CMP Algorithms (modern crypto algorithms)
- RFC 9483: Lightweight CMP Profile (for constrained environments)
