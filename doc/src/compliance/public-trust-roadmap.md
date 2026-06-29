# Public Trust Roadmap

This page outlines the engineering plan for making the kipuka + Dogtag
stack eligible for inclusion in browser root trust stores (Chrome, Mozilla,
Apple) under the CA/Browser Forum Baseline Requirements.

**Tracking:** [RHELBU-3179](https://redhat.atlassian.net/browse/RHELBU-3179)
| **BR Version:** 2.2.8 (June 2026)
| **Target:** Production readiness by mid-2027

## Target Customers

| Customer | Use Case | Scale |
|----------|----------|-------|
| GSA Federal PKI | Public trust TLS for `.gov` websites | 800K–1M certs |
| DISA PKI | Cross-pair trust with Federal PKI | ~50M certs |
| Enterprise | Any customer joining the public trust | Variable |

## Architecture

The public trust stack separates enrollment (kipuka), issuance (Dogtag),
and validation (external services):

```text
┌─────────────────────────────────────────────────────────────┐
│                    Browser Root Stores                       │
│                 (Chrome, Mozilla, Apple)                     │
└────────────────────────┬────────────────────────────────────┘
                         │ Trust
┌────────────────────────▼────────────────────────────────────┐
│                   Dogtag CA (RHCS)                           │
│    Certificate signing · CT log submission · CRL · OCSP      │
│    Enrollment profiles · Key archival (KRA)                  │
└────────────────────────┬────────────────────────────────────┘
                         │ Issue
┌──────────┐  ┌──────────▼──────────┐  ┌──────────────────┐
│ pkimetal  │◄─│    kipuka (RA/EST)   │─►│    Open MPIC     │
│ (linter)  │  │                      │  │ (geo-validated)  │
│           │  │  CAA · Key blocklist  │  │ 5 cloud regions  │
│ Container │  │  ACME · Audit log     │  │ across 3+ RIRs   │
│ sidecar   │  │  Conformance suite    │  │                  │
└──────────┘  └──────────┬──────────┘  └──────────────────┘
                         │ Enroll
              ┌──────────▼──────────┐
              │  EST / ACME Clients  │
              │  certbot · curl      │
              │  libest · cert-mgr   │
              └─────────────────────┘
```

**Component responsibilities:**

- **kipuka** — Registration Authority. Authenticates clients, validates
  CSRs, checks CAA records, enforces key blocklist, calls pkimetal for
  linting, calls MPIC for multi-perspective validation, forwards to
  Dogtag for signing.
- **Dogtag CA** — Certificate Authority. Signs certificates, manages CT
  log submission, generates CRLs, operates OCSP responder, enforces
  enrollment profiles.
- **pkimetal** — Pre-issuance linting sidecar. Wraps zlint, pkilint,
  certlint, and special-purpose checks (ROCA, Fermat, pwnedkeys) behind
  a single REST API.
- **Open MPIC** — Multi-perspective validation service. Corroborates
  domain validation and CAA checks from geographically distributed
  network perspectives.

## Compliance Gaps

### What's Already Compliant

| Requirement | BR Section | Component | Notes |
|-------------|-----------|-----------|-------|
| Serial number entropy (≥64 bits) | §7.1 | kipuka | 160-bit CSPRNG |
| Key size enforcement (RSA ≥2048) | §6.1.5 | kipuka | Enforced in CSR validation |
| Certificate extensions (AKI, SKI, BC, KU, EKU) | §7.1.2 | kipuka + synta | All mandatory extensions |
| PKCS#7 certs-only response format | §4.2.3 | kipuka | Fixed in v0.1.0 |
| Audit logging | §5.4 | kipuka + Dogtag | NIAP FAU_GEN.1 compliant |
| OCSP responder | §4.9.9 | Dogtag | Available |
| CRL generation | §4.9.7 | Dogtag | Auto-update configurable |
| Certificate Transparency | §7.1.2.9 | Dogtag | CTEngine with SCT embedding |
| Revocation processing | §4.9.1 | Dogtag | With CRLReason codes |
| DN encoding (UTF8String) | §7.1.4 | kipuka + synta | Per RFC 5280 |
| Name Constraints enforcement | §7.1.5 | kipuka | At CSR validation time |
| STAR short-lived certificates | RFC 8739 | kipuka | For 47-day mandate |
| RFC conformance test suite | — | kipuka | 12 suites, 129 assertions |

### What Needs to Be Built

| # | Gap | BR Section | Component | Status |
|---|-----|-----------|-----------|--------|
| P0 | Validity period enforcement | §6.3.2 | kipuka | **Live bug** — hardcoded 398, should be 200 |
| P1 | Default EKU `serverAuth`-only | §7.1.2.7.10 | kipuka | **Deadline passed** — includes `clientAuth` |
| P2 | CAA record checking | §4.2.2.1 | kipuka | Not implemented |
| P3 | Pre-issuance linting | §4.3.1.2 | kipuka + pkimetal | Not implemented |
| P4 | Key compromise blacklisting | §6.1.1.3 | kipuka | Not implemented |
| P5 | ACME protocol | RFC 8555 | kipuka | Not implemented |
| P6 | Multi-perspective validation | §3.2.2.9 | Open MPIC | Not implemented |
| P7 | CA hierarchy separation | Chrome Root Program | Dogtag + operational | Architecture decision |

## Phased Delivery Plan

### Phase 1: Fix Live Compliance Bugs (1 week)

**P0 — Validity Period (§6.3.2)**

The certificate validity check uses a hardcoded 398-day maximum. The
CA/B Forum reduced this to 200 days effective March 15, 2026 (Ballot
SC-081v3). This is a date-aware stepped schedule:

| Effective | Max Validity |
|-----------|-------------|
| Before 2026-03-15 | 398 days |
| **2026-03-15 – 2027-03-14** | **200 days** ← current |
| 2027-03-15 – 2029-03-14 | 100 days |
| 2029-03-15+ | 47 days |

**Fix:** Replace the static constant with a date-aware schedule function
in `src/ca/issue.rs`. Three code locations.

**P1 — EKU Default (Chrome Root Program v1.6)**

The default enrollment profile includes both `serverAuth` and
`clientAuth` in the Extended Key Usage extension. Chrome Root Program
v1.6+ requires `serverAuth`-only for publicly trusted TLS certificates.
The June 15, 2026 deadline for leaf certificates has passed.

**Fix:** Change default EKU to `serverAuth`-only. One code location.

### Phase 2: Hard Compliance Blockers (2–3 months)

**P2 — CAA Record Checking (RFC 8659)**

Before issuing a certificate, the RA must query DNS CAA records for each
domain in the CSR's Subject Alternative Name. If CAA records exist and
do not authorize kipuka's CA identity, issuance must be denied.

| Requirement | Effective | Status |
|-------------|-----------|--------|
| CAA record processing | Sep 2017 | Not implemented |
| RFC 8657 `accounturi` / `validationmethods` | SHOULD now, MUST Mar 2027 | Not implemented |
| DNSSEC validation of CAA queries | Mar 2026 | Not implemented |

**Implementation:** New `src/caa/` module in kipuka using the
`hickory-resolver` crate for async DNS with DNSSEC. The RFC 8659
tree-climbing algorithm queries CAA records from the FQDN up through
parent domains. ~1200 lines of Rust.

**P3 — Pre-Issuance Linting (Ballot SC-75)**

Mandatory since March 2025. The CA must lint every to-be-signed
certificate before signing. kipuka will integrate with
[pkimetal](https://github.com/pkimetal/pkimetal), a Go-based meta-linter
that wraps zlint, pkilint, certlint, and special-purpose checks behind a
REST API.

**Implementation:** pkimetal runs as a container sidecar. kipuka calls
its REST API after certificate construction, before returning to the
client. ~500 lines of Rust for the HTTP client and config.

**P4 — Key Compromise Blacklisting (Ballot SC-073)**

Mandatory since November 2024. The CA must reject certificate requests
using keys known to be compromised or weak.

| Check | Source |
|-------|--------|
| Previously compromised keys | Dynamic blocklist (revocation + reports) |
| Debian weak keys (CVE-2008-0166) | [cabforum/Debian-weak-keys](https://github.com/cabforum/Debian-weak-keys) |
| ROCA vulnerability | crocs-muni/roca |
| Close primes (Fermat, 100 rounds) | BR §6.1.1.3 |

**Implementation:** New `blocked_keys` database table with SHA-256 of
SPKI DER. CSR validation hook before issuance. Revocation cascade when
keys are reported compromised. ~600 lines of Rust.

### Phase 3: MPIC Infrastructure (2–3 months, parallel)

**P6 — Multi-Perspective Issuance Corroboration (Ballot SC-067v3)**

Already mandatory. Domain validation and CAA checks must be corroborated
from multiple geographically distributed network perspectives.

| Effective | Min Perspectives | Min RIR Regions |
|-----------|-----------------|----------------|
| Sep 2025 | 2 | — |
| Mar 2026 | 3 | 2 |
| **Jun 2026** | **4** | **2** ← current |
| Dec 2026 | 5 | 2 |

**Implementation:** Deploy [Open MPIC](https://open-mpic.org/) on
OpenShift across 5 cloud regions (ARIN, RIPE, APNIC minimum). kipuka
calls the MPIC Coordinator REST API as a pre-issuance hook. ~300 lines
of Rust integration + infrastructure deployment.

### Phase 4: ACME Protocol (3–4 months)

**P5 — ACME (RFC 8555)**

Not mandated by CA/B Forum, but required by customers for automated
certificate lifecycle. At 47-day validity (March 2029), manual
enrollment is unsustainable — ACME or EST automation becomes essential.

Dogtag has an existing ACME responder (`dogtag-pki-acme`) but it lacks
TLS-ALPN-01 (RFC 8737), External Account Binding, and is classified as
Technology Preview.

**Options:**
1. Build `kipuka-acme` crate alongside EST (preferred — full control,
   all 3 challenge types, reuses kipuka infrastructure)
2. Enhance Dogtag's Java ACME responder (existing code, but limited)
3. Deploy step-ca alongside Dogtag (mature ACME, but adds operational
   complexity)

**Scope:** Account management, order state machine, HTTP-01/DNS-01/
TLS-ALPN-01 challenge validators, CSR finalization through existing
issuance pipeline. 3–4 person-months.

### Phase 5: Architecture (parallel)

**P7 — CA Hierarchy Separation (Chrome Root Program)**

Chrome Root Program v1.6+ requires that publicly trusted TLS
certificates carry only `serverAuth` EKU — not just at the leaf level,
but throughout the entire CA hierarchy. This means:

- Dedicated TLS root → TLS intermediate(s): `serverAuth` only
- Separate hierarchy for client auth, S/MIME, code signing

This is an operational / architectural decision, not a code change.
Dogtag and kipuka already support multiple CA configurations with
distinct profiles.

## Timeline

```text
Jul 2026  ████ Phase 1: Fix P0 (validity) + P1 (EKU)
          ████ Phase 2 starts: P2 (CAA), P3 (linting), P4 (key blocklist)
Aug 2026  ████████ Phase 2 continues
          ████ Phase 3 starts: P6 (MPIC deployment)
Sep 2026  ████████ Phase 2 completes
Oct 2026  ████████ Phase 3: MPIC operational (4 perspectives)
          ████ Phase 4 starts: P5 (ACME)
Nov 2026  ████████ Phase 4 continues
Dec 2026  ████ Phase 3: MPIC 5th perspective added
Jan 2027  ████████ Phase 4: ACME MVP (HTTP-01 + DNS-01)
Feb 2027  ████ Phase 4: TLS-ALPN-01 + client compat testing
Mar 2027  ████ Phase 5: P7 hierarchy design finalized
          ████ WebTrust / ETSI audit engagement
Jun 2027  ████ Production readiness
```

## Additional BR Requirements (lower priority)

These are tracked in the [detailed BR mapping](./cab-forum.md) but are
not on the critical path for initial public trust:

| Requirement | BR Section | Status |
|-------------|-----------|--------|
| RSA exponent / key quality checks | §6.1.6 | Not implemented |
| `organizationalUnitName` prohibition | §7.1.2.10.2 | Not implemented |
| `notBefore` 48-hour enforcement | §7.1.2.7 | Not enforced |
| SHA-1 signing rejection | §7.1.3.2 | Not enforced |
| AIA / CDP extension injection | §7.1.2.7.7 | Not implemented (CA profile) |
| Certificate Policies OID enforcement | §7.1.2.7.9 | Partial |
| Debian weak key checks | §6.1.1.3 | Not implemented (covered by P4) |

## References

- [CA/B Forum Baseline Requirements v2.2.8](https://cabforum.org/working-groups/server/baseline-requirements/)
- [Ballot SC-081v3 — Reducing Certificate Validity](https://cabforum.org/2025/04/11/ballot-sc081v3-introduce-schedule-of-reducing-validity-and-data-reuse-periods/)
- [Ballot SC-075 — Pre-Issuance Linting](https://cabforum.org/2024/08/05/ballot-sc075-pre-sign-linting/)
- [Ballot SC-073 — Weak Key Rejection](https://www.mail-archive.com/servercert-wg@cabforum.org/msg00593.html)
- [Ballot SC-067v3 — Multi-Perspective Validation](https://cabforum.org/2024/08/05/ballot-sc067v3-require-domain-validation-and-caa-checks-to-be-performed-from-multiple-network-perspectives-corroboration/)
- [Chrome Root Program Policy](https://googlechrome.github.io/chromerootprogram/)
- [RFC 8659 — DNS CAA](https://datatracker.ietf.org/doc/html/rfc8659)
- [RFC 8657 — CAA Extensions](https://www.rfc-editor.org/rfc/rfc8657.html)
- [RFC 8555 — ACME](https://datatracker.ietf.org/doc/html/rfc8555)
- [pkimetal](https://github.com/pkimetal/pkimetal) — PKI Meta-Linter
- [Open MPIC](https://open-mpic.org/) — Multi-Perspective Issuance Corroboration
