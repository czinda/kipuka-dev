# Post-Quantum Cryptography Readiness

kipuka supports post-quantum cryptographic algorithms to prepare for the quantum computing threat to current public-key cryptography. This page covers ML-DSA digital signatures, ML-KEM key encapsulation, composite hybrid algorithms, and the CNSA Suite 2.0 transition timeline.

## Overview

**Quantum threat:** Shor's algorithm (running on a cryptographically relevant quantum computer, CRQC) can break RSA, ECDSA, and Diffie-Hellman in polynomial time. Current estimates suggest CRQCs may emerge in the 2030s, but data encrypted today using classical algorithms can be harvested and decrypted later ("store now, decrypt later" attacks).

**NIST PQC standards (August 2024):**
- **FIPS 204:** Module-Lattice-Based Digital Signature Standard (ML-DSA, formerly CRYSTALS-Dilithium)
- **FIPS 203:** Module-Lattice-Based Key-Encapsulation Mechanism Standard (ML-KEM, formerly CRYSTALS-Kyber)
- **FIPS 205:** Stateless Hash-Based Digital Signature Standard (SLH-DSA, formerly SPHINCS+, not yet supported in kipuka)

kipuka implements ML-DSA for certificate signing and ML-KEM for key establishment, with composite hybrid algorithms that pair PQC with classical algorithms (RSA/ECDSA) for defense-in-depth.

## ML-DSA (Digital Signatures)

ML-DSA (FIPS 204) is a lattice-based signature scheme offering three security levels aligned with AES key strengths:

| Algorithm | Security Level | Public Key Size | Signature Size | Classical Equivalent |
|-----------|----------------|-----------------|----------------|---------------------|
| **ML-DSA-44** | Level 2 (AES-128) | 1,312 bytes | 2,420 bytes | RSA-2048, ECDSA P-256 |
| **ML-DSA-65** | Level 3 (AES-192) | 1,952 bytes | 3,309 bytes | RSA-3072, ECDSA P-384 |
| **ML-DSA-87** | Level 5 (AES-256) | 2,592 bytes | 4,627 bytes | RSA-4096, ECDSA P-521 |

**Key observations:**
- **Larger signatures:** ML-DSA-87 signatures (~4.6 KB) are 8x larger than RSA-4096 (~512 bytes) and 36x larger than ECDSA P-384 (~128 bytes).
- **Faster verification:** ML-DSA verification is 2-5x faster than RSA for equivalent security.
- **Deterministic:** Unlike ECDSA, ML-DSA signatures are deterministic (no nonce selection vulnerability).

### Certificate Size Impact

A typical X.509 certificate with ML-DSA-87:
- **TBSCertificate (To-Be-Signed):** ~1.5 KB (subject, issuer, validity, extensions)
- **Public key (subjectPublicKeyInfo):** 2,592 bytes
- **CA signature:** 4,627 bytes
- **Total:** ~8.7 KB per certificate

A three-certificate chain (root → intermediate → end-entity) totals ~26 KB, compared to ~6 KB for RSA-2048 or ~3 KB for ECDSA P-256.

**Implications:**
- HTTP/TLS max record size (16 KB) may require fragmentation
- CoAP block-wise transfer essential (see [CoAP Transport](../operator/coap.md))
- Increased network bandwidth and storage

## ML-KEM (Key Encapsulation)

ML-KEM (FIPS 203) is a lattice-based key encapsulation mechanism (KEM) for establishing shared secrets, used in TLS handshakes and S/MIME key exchange.

| Algorithm | Security Level | Public Key Size | Ciphertext Size | Classical Equivalent |
|-----------|----------------|-----------------|-----------------|---------------------|
| **ML-KEM-512** | Level 1 (AES-128) | 800 bytes | 768 bytes | RSA-2048, ECDH P-256 |
| **ML-KEM-768** | Level 3 (AES-192) | 1,184 bytes | 1,088 bytes | RSA-3072, ECDH P-384 |
| **ML-KEM-1024** | Level 5 (AES-256) | 1,568 bytes | 1,568 bytes | RSA-4096, ECDH P-521 |

**Usage in kipuka:**
- **EST serverkeygen:** CA encrypts generated private key for client using ML-KEM
- **CMS EnvelopedData:** Encrypt EST responses with ML-KEM key exchange
- **Future TLS 1.3 integration:** Hybrid key exchange (X25519 + ML-KEM-768)

**Performance:**
- **Encapsulation:** 10-50 µs (faster than RSA encryption)
- **Decapsulation:** 10-50 µs (much faster than RSA decryption)

## Composite Hybrid Algorithms

To mitigate the risk of a breakthrough attack on lattice cryptography, kipuka supports composite hybrid signatures that bind a PQC algorithm with a classical algorithm. Both signatures must verify for the certificate to be valid.

**Rationale:** If ML-DSA is broken, the classical signature (RSA/ECDSA) still provides security. If the classical algorithm is broken by quantum computers, ML-DSA provides quantum resistance. This "belt-and-suspenders" approach is recommended during the PQC transition period (2025-2035).

### Composite Signature Algorithms

Based on **draft-ietf-lamps-pq-composite-sigs-19** (IETF LAMPS working group, expected RFC in 2025):

| Composite Algorithm | Components | OID Sub-Arc | Security Level |
|---------------------|-----------|-------------|----------------|
| **ML-DSA-44-RSA2048-PSS-SHA256** | ML-DSA-44 + RSA-2048-PSS | 37 | Level 2 (128-bit) |
| **ML-DSA-44-RSA2048-PKCS15-SHA256** | ML-DSA-44 + RSA-2048-PKCS#1 v1.5 | 38 | Level 2 (legacy compat) |
| **ML-DSA-44-Ed25519-SHA512** | ML-DSA-44 + Ed25519 | 39 | Level 2 (hybrid EdDSA) |
| **ML-DSA-44-ECDSA-P256-SHA256** | ML-DSA-44 + ECDSA P-256 | 40 | Level 2 (NIST curve) |
| **ML-DSA-65-RSA3072-PSS-SHA512** | ML-DSA-65 + RSA-3072-PSS | 41 | Level 3 (192-bit) |
| **ML-DSA-65-RSA3072-PKCS15-SHA512** | ML-DSA-65 + RSA-3072-PKCS#1 v1.5 | 42 | Level 3 (legacy compat) |
| **ML-DSA-65-ECDSA-P384-SHA512** | ML-DSA-65 + ECDSA P-384 | 43 | Level 3 (NIST curve) |
| **ML-DSA-65-ECDSA-brainpoolP256r1-SHA512** | ML-DSA-65 + ECDSA brainpoolP256r1 | 44 | Level 3 (Brainpool) |
| **ML-DSA-65-Ed25519-SHA512** | ML-DSA-65 + Ed25519 | 45 | Level 3 (hybrid EdDSA) |
| **ML-DSA-87-ECDSA-P384-SHA512** | ML-DSA-87 + ECDSA P-384 | 46 | Level 5 (256-bit) |
| **ML-DSA-87-ECDSA-brainpoolP384r1-SHA512** | ML-DSA-87 + ECDSA brainpoolP384r1 | 47 | Level 5 (Brainpool) |
| **ML-DSA-87-Ed448-SHA512** | ML-DSA-87 + Ed448 | 48 | Level 5 (hybrid EdDSA) |

**OID structure:** `id-composite-sig.{sub-arc}` where `id-composite-sig = 2.16.840.1.114027.80.5.2` (IANA PEN 114027, Entrust).

**Example OID:**
- ML-DSA-65-RSA3072-PSS-SHA512 → `2.16.840.1.114027.80.5.2.41`

### Signature Format

A composite signature contains two independent signatures concatenated:

```asn1
CompositeSignatureValue ::= SEQUENCE {
  pqcSignature BIT STRING,      -- ML-DSA signature
  traditionalSignature BIT STRING  -- RSA/ECDSA/EdDSA signature
}
```

**Verification:**
1. Extract `pqcSignature` and verify using ML-DSA public key
2. Extract `traditionalSignature` and verify using RSA/ECDSA/EdDSA public key
3. Both must verify for the certificate to be valid

**Certificate size:** Composite signatures roughly double the signature size:
- ML-DSA-65-RSA3072-PSS: 3,309 (ML-DSA) + 384 (RSA-PSS) ≈ 3,693 bytes
- ML-DSA-87-ECDSA-P384: 4,627 (ML-DSA) + 96 (ECDSA) ≈ 4,723 bytes

## CNSA Suite 2.0 Transition Timeline

The **Commercial National Security Algorithm (CNSA) Suite 2.0** (NSA, September 2022) provides guidance for U.S. government systems transitioning to post-quantum cryptography:

| Year | Requirement | Details |
|------|-------------|---------|
| **2025** | **Prefer PQC** | PQC algorithms should be used when available; classical algorithms still permitted |
| **2030** | **Require PQC for signing** | All certificates, firmware signatures, and document signing must use ML-DSA or composite hybrid |
| **2033** | **Require PQC for key establishment** | All TLS handshakes, key wrapping, and encryption must use ML-KEM or hybrid KEMs |
| **2035** | **Phase out classical-only systems** | Systems using only RSA/ECDSA/ECDH must be decommissioned or upgraded |

**Recommendations for kipuka deployments:**
- **2025-2029:** Use composite hybrid algorithms (ML-DSA + RSA/ECDSA) for compatibility
- **2030-2032:** Transition to ML-DSA-only for signing, hybrid KEM for key exchange
- **2033+:** Pure PQC (ML-DSA + ML-KEM) for all new certificates

**Grace periods:** Existing certificates issued before 2030 may remain valid until expiration (typical 1-3 year lifetime), but renewals must use PQC.

## Configuration

### Enable ML-DSA signing

```toml
[ca]
default_signature_algorithm = "ML-DSA-65"  # or ML-DSA-44, ML-DSA-87
```

### Enable composite hybrid signing

```toml
[ca]
default_signature_algorithm = "ML-DSA-65-RSA3072-PSS-SHA512"
# or ML-DSA-44-ECDSA-P256-SHA256, ML-DSA-87-ECDSA-P384-SHA512, etc.
```

### Per-profile configuration

```toml
[[ca.profiles]]
name = "TLS Server (PQC Ready)"
signature_algorithm = "ML-DSA-65-ECDSA-P384-SHA512"
key_usage = ["digitalSignature", "keyEncipherment"]
extended_key_usage = ["serverAuth"]

[[ca.profiles]]
name = "Code Signing (Pure PQC)"
signature_algorithm = "ML-DSA-87"
key_usage = ["digitalSignature"]
extended_key_usage = ["codeSigning"]
```

### Algorithm constraints

```toml
[ca.algorithm_policy]
allowed_signature_algorithms = [
  "ML-DSA-44",
  "ML-DSA-65",
  "ML-DSA-87",
  "ML-DSA-65-RSA3072-PSS-SHA512",
  "ML-DSA-87-ECDSA-P384-SHA512",
]
minimum_security_level = 3  # Reject Level 1 (ML-DSA-44) for production CAs
```

## OpenSSL 3.5 Requirement

**Critical dependency:** PQC support in software (non-HSM) mode requires **OpenSSL 3.5 or later** with the `pqc` provider enabled.

**OpenSSL 3.5 features:**
- Native ML-DSA (Dilithium) and ML-KEM (Kyber) implementations
- Composite signature support (via `pqc-combined` provider)
- EVP_PKEY interfaces for PQC key generation, signing, verification

**Check OpenSSL version:**
```bash
openssl version
# OpenSSL 3.5.0-dev  24 Apr 2025 (Library: OpenSSL 3.5.0-dev  24 Apr 2025)
```

**Enable PQC provider in `openssl.cnf`:**
```ini
[openssl_init]
providers = provider_sect

[provider_sect]
default = default_sect
pqc = pqc_sect

[default_sect]
activate = 1

[pqc_sect]
activate = 1
```

**Verify PQC support:**
```bash
openssl list -signature-algorithms | grep -i dilithium
# ML-DSA-44 @ pqc
# ML-DSA-65 @ pqc
# ML-DSA-87 @ pqc
```

**Alternative (Docker):** Use the kipuka container image which includes OpenSSL 3.5 with PQC support:
```bash
podman run -it registry.kipuka.dev/heebus/kipuka:latest openssl version
```

## HSM Support Roadmap

**Current status (June 2026):** PQC key generation and signing in HSMs is vendor-dependent. Most HSMs do not yet support FIPS 204 (ML-DSA) in firmware.

| HSM Vendor | Model | ML-DSA Support | Status | ETA |
|------------|-------|----------------|--------|-----|
| **Thales** | Luna Network HSM 7.4+ | ML-DSA-44, ML-DSA-65, ML-DSA-87 | Beta (firmware 7.10) | Q3 2026 GA |
| **Entrust** | nShield 5c+ | ML-DSA-65, ML-DSA-87 | Roadmap | Q4 2026 |
| **Utimaco** | SecurityServer Se Gen2 | ML-DSA-44, ML-DSA-65 | Experimental | Q1 2027 |
| **Kryoptic** | FOSS HSM | ML-DSA-44, ML-DSA-65, ML-DSA-87 | Alpha | Q3 2026 |
| **AWS CloudHSM** | - | None | Not announced | Unknown |
| **Azure Key Vault** | Managed HSM | None | Not announced | Unknown |

**Workaround:** Use software-based PQC signing (OpenSSL 3.5) for CA operations until HSM support is available. Root CA key can remain in HSM with RSA/ECDSA, using composite hybrid algorithms (ML-DSA-65-RSA3072-PSS) where the RSA component is HSM-backed.

**Migration path:**
1. **2025-2026:** Root CA uses RSA-4096 (HSM), intermediate CA uses ML-DSA-65-RSA3072-PSS-SHA512 (composite, RSA in HSM)
2. **2027:** Intermediate CA migrated to ML-DSA-65-only (HSM firmware updated)
3. **2028:** Root CA re-keyed to ML-DSA-87 (HSM-backed)

## CoAP Considerations

Post-quantum certificates significantly impact CoAP deployments due to UDP MTU constraints.

**Challenge:** A typical ML-DSA-87 certificate (~8.7 KB) requires:
- **16 blocks** at 512-byte block size
- **68 blocks** at 128-byte block size (constrained networks)

**Recommendations:**
1. **Use ML-DSA-44** (Level 2) for IoT devices: ~5 KB certificates fit in 10 blocks at 512 bytes
2. **Increase block size to 1024 bytes** for higher-bandwidth networks (reduces to 9 blocks)
3. **Enable block-wise transfer** with `max_payload = 131072` (128 KB) to accommodate full chains
4. **Use composite algorithms sparingly** (adds ~400 bytes per certificate for RSA component)
5. **Compress certificate chains** (remove intermediate CA if client has it pre-installed)

**Example CoAP config for PQC:**
```toml
[coap]
enabled = true
block_size = 1024  # Larger blocks for PQC
max_payload = 131072  # 128 KB (3x typical chain size)
session_timeout_secs = 600  # Longer timeout for multi-block transfers
```

**Performance impact:**
- **16 blocks × 200ms RTT** = 3.2 seconds for certificate chain retrieval (vs. 0.4s for RSA-2048)
- Mitigate with session resumption (cache CA certs client-side after first fetch)

## Example Workflows

### Workflow 1: Issue ML-DSA-65 certificate

```bash
# Generate ML-DSA-65 key pair (requires OpenSSL 3.5+)
openssl genpkey -algorithm ML-DSA-65 -out device-pqc.key

# Create CSR
openssl req -new -key device-pqc.key \
  -subj "/CN=pqc-device.example.com/O=Example Inc" \
  -out device-pqc.csr

# Submit to kipuka via EST
curl -X POST https://ca.example.com/.well-known/est/simpleenroll \
  --cert client-cert.pem --key client-key.pem \
  -H "Content-Type: application/pkcs10" \
  --data-binary @device-pqc.csr \
  -o device-pqc-cert.p7

# Extract certificate
openssl pkcs7 -in device-pqc-cert.p7 -print_certs -out device-pqc-cert.pem

# Verify signature algorithm
openssl x509 -in device-pqc-cert.pem -text -noout | grep "Signature Algorithm"
# Signature Algorithm: ML-DSA-65
```

### Workflow 2: Issue composite hybrid certificate

```bash
# Generate RSA-3072 key pair
openssl genrsa -out device-hybrid.key 3072

# Generate ML-DSA-65 key pair
openssl genpkey -algorithm ML-DSA-65 -out device-hybrid-pqc.key

# Combine keys into composite key (format TBD by OpenSSL provider)
# For now, CA generates composite signature from single CSR

# Create CSR (traditional key only; CA adds PQC component)
openssl req -new -key device-hybrid.key \
  -subj "/CN=hybrid-device.example.com/O=Example Inc" \
  -addext "signatureAlgorithm=ML-DSA-65-RSA3072-PSS-SHA512" \
  -out device-hybrid.csr

# Submit via EST
curl -X POST https://ca.example.com/.well-known/est/simpleenroll \
  --cert client-cert.pem --key client-key.pem \
  -H "Content-Type: application/pkcs10" \
  --data-binary @device-hybrid.csr \
  -o device-hybrid-cert.p7

# Verify composite signature
openssl x509 -in device-hybrid-cert.pem -text -noout | grep "Signature Algorithm"
# Signature Algorithm: ML-DSA-65-RSA3072-PSS-SHA512
```

## Testing PQC Support

```bash
# Verify kipuka supports PQC algorithms
curl https://ca.example.com/.well-known/est/csrattrs
# Response includes ML-DSA OIDs

# Generate test ML-DSA-44 certificate
openssl req -x509 -newkey ML-DSA-44 -keyout test.key -out test.crt -days 1

# Verify signature
openssl verify -CAfile test.crt test.crt
# test.crt: OK

# Check certificate size
ls -lh test.crt
# -rw-r--r-- 1 user user 5.2K Jun 25 12:34 test.crt
```

## Migration Best Practices

1. **Start with composite hybrid** (2025-2027): Use ML-DSA-65-RSA3072-PSS for broad compatibility
2. **Test PQC-only in staging** (2026-2028): Deploy ML-DSA-65-only CAs in non-production
3. **Monitor certificate sizes** (ongoing): Track storage and bandwidth impact of PQC certs
4. **Plan HSM upgrades** (2026-2027): Budget for firmware updates or HSM replacement
5. **Train operations teams** (2025-2026): PQC troubleshooting differs from classical crypto
6. **Update incident response** (ongoing): Quantum attacks may manifest as unexplained signature failures

## Security Considerations

1. **Algorithm agility:** Ensure CA can switch algorithms quickly if ML-DSA is compromised
2. **Hybrid during transition:** Use composite signatures until CRQC threat is imminent (2030+)
3. **Monitor NIST updates:** FIPS 204/203 may receive errata or revision (subscribe to NIST announcements)
4. **Avoid ML-DSA-44 in production CAs:** Level 2 security may be insufficient for long-lived root CAs
5. **Audit PQC implementations:** Software bugs in lattice reduction libraries are discovered regularly
6. **Plan for post-quantum hash functions:** SHA-256/SHA-512 are quantum-resistant for now, but monitor SHA-3 adoption

## References

- FIPS 204: Module-Lattice-Based Digital Signature Standard (ML-DSA)
- FIPS 203: Module-Lattice-Based Key-Encapsulation Mechanism Standard (ML-KEM)
- CNSA Suite 2.0 Cryptographic Algorithms (NSA, September 2022)
- draft-ietf-lamps-pq-composite-sigs-19: Composite ML-DSA for use in X.509 Public Key Infrastructure
- NIST PQC Standardization: https://csrc.nist.gov/projects/post-quantum-cryptography
- OpenSSL PQC Provider: https://github.com/openssl/openssl/blob/master/doc/designs/pqc-provider.md
