# Your First Certificate

This guide walks through a complete EST enrollment cycle: generating a one-time
password, creating a certificate signing request, enrolling through the EST
endpoint, and verifying the result.  By the end you will have a signed X.509
certificate issued by your kipuka server.

**Prerequisites:** A running kipuka instance from the [First Run](./first-run.md)
guide and the CA certificate saved as `ca.pem`.

## Step 1: Generate a one-time password

kipuka authenticates initial enrollment requests with a one-time password (OTP).
Generate one through the admin API:

```bash
curl -sk -X POST https://localhost:9443/admin/otp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"entity_id": "test-device"}'
```

Response:

```json
{
  "entity_id": "test-device",
  "otp": "a1b2c3d4e5f6",
  "expires_at": "2026-06-25T12:00:00Z"
}
```

Save the OTP value:

```bash
OTP="a1b2c3d4e5f6"
```

> **Note:** The admin API bearer token is configured in `kipuka.toml` under
> `[admin]`.  See the [Admin API Reference](../reference/admin-api.md) for
> details on token management.

## Step 2: Generate a CSR

Create an EC P-256 key pair and a certificate signing request:

```bash
openssl req -new \
  -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout client.key \
  -out client.csr \
  -nodes \
  -subj "/CN=test-device"
```

This produces two files:

| File | Contents |
| ---- | -------- |
| `client.key` | Private key (stays on the device, never sent to the server) |
| `client.csr` | Certificate signing request (sent to kipuka) |

> **Tip:** For production IoT devices, generate the key pair in a secure
> element or TPM and export only the CSR.

## Step 3: Enroll with OTP

Submit the CSR to the EST `/simpleenroll` endpoint, authenticating with the
entity ID and OTP as HTTP Basic credentials:

```bash
curl -sk \
  --cacert ca.pem \
  -u "test-device:${OTP}" \
  --data-binary @client.csr \
  -H "Content-Type: application/pkcs10" \
  -o cert.p7 \
  https://localhost:9443/.well-known/est/simpleenroll
```

The server returns a PKCS #7 (CMS) envelope containing the signed certificate
in DER format, saved here as `cert.p7`.

If enrollment succeeds, the HTTP response code is `200`.  Common error codes:

| Code | Meaning |
| ---- | ------- |
| `401` | Invalid or expired OTP |
| `400` | Malformed CSR |
| `403` | Subject name not permitted by CA policy |
| `503` | Back-end CA unavailable |

## Step 4: Extract the certificate

Convert the PKCS #7 envelope to PEM:

```bash
openssl pkcs7 -inform DER -in cert.p7 -print_certs -out client.pem
```

You now have the signed certificate in `client.pem`.

## Step 5: Verify the certificate

Inspect the certificate details:

```bash
openssl x509 -in client.pem -text -noout
```

Expected output (abbreviated):

```
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: ...
        Signature Algorithm: ecdsa-with-SHA256
        Issuer: CN = kipuka Test CA
        Validity
            Not Before: Jun 24 12:00:00 2026 GMT
            Not After : Jun 24 12:00:00 2027 GMT
        Subject: CN = test-device
        Subject Public Key Info:
            Public Key Algorithm: id-ecPublicKey
                Public-Key: (256 bit)
                ...
```

Verify the certificate chains back to your CA:

```bash
openssl verify -CAfile ca.pem client.pem
```

```
client.pem: OK
```

## Re-enrollment

Once a device holds a valid certificate, it can renew without an OTP by
authenticating with TLS client certificate authentication.  The EST
`/simplereenroll` endpoint accepts the same CSR format:

```bash
# Generate a new CSR (optionally with a new key pair)
openssl req -new \
  -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout client-new.key \
  -out client-new.csr \
  -nodes \
  -subj "/CN=test-device"

# Re-enroll using the existing certificate for authentication
curl -sk \
  --cacert ca.pem \
  --cert client.pem \
  --key client.key \
  --data-binary @client-new.csr \
  -H "Content-Type: application/pkcs10" \
  -o cert-new.p7 \
  https://localhost:9443/.well-known/est/simplereenroll
```

Extract the renewed certificate:

```bash
openssl pkcs7 -inform DER -in cert-new.p7 -print_certs -out client-new.pem
```

> **Key rotation:** The example above generates a fresh key pair during
> re-enrollment.  This is recommended practice.  If your use case requires
> keeping the same key, omit `-newkey` and pass the existing key with `-key
> client.key`.

## EST labels: profile-based routing

kipuka supports EST labels (also called path segments) to route enrollment
requests to different CA configurations or certificate profiles.  The label
appears in the URL path between `/.well-known/est/` and the operation name.

For example, if you configure a label called `iot-devices` that maps to a
dedicated CA and profile:

```toml
[[ca]]
id = "iot"
cert = "/etc/kipuka/ca/iot-ca.pem"
key = "/etc/kipuka/ca/iot-ca-key.pem"
label = "iot-devices"
validity_days = 90
```

Clients enroll against the labeled path:

```bash
curl -sk \
  --cacert iot-ca.pem \
  -u "sensor-001:${OTP}" \
  --data-binary @sensor.csr \
  -H "Content-Type: application/pkcs10" \
  -o sensor-cert.p7 \
  https://localhost:9443/.well-known/est/iot-devices/simpleenroll
```

The `/cacerts` endpoint also respects labels, returning only the CA
certificate(s) for that label:

```bash
curl -sk https://localhost:9443/.well-known/est/iot-devices/cacerts \
  | base64 -d \
  | openssl pkcs7 -inform DER -print_certs
```

Labels are a powerful mechanism for multi-tenant and multi-profile deployments.
See [EST Labels](../operator/est-labels.md) in the Operator Guide for the
complete configuration reference.

## Summary

You have completed a full EST enrollment lifecycle:

1. Generated a one-time password via the admin API
2. Created a CSR with an EC P-256 key pair
3. Enrolled through `/simpleenroll` with OTP authentication
4. Extracted and verified the signed certificate
5. Learned how to re-enroll with certificate-based authentication
6. Explored label-based routing for multi-CA deployments

Next steps:

- [Configuration Reference](../operator/configuration.md) — explore every
  `kipuka.toml` option
- [Authentication](../operator/authentication.md) — configure client
  certificate auth policies
- [HSM Integration](../operator/hsm.md) — move CA keys into hardware
- [Admin API Reference](../reference/admin-api.md) — full OTP and
  management API documentation
