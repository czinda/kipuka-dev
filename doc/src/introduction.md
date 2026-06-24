# Introduction

> **kipuka** (Hawaiian) — an area of older land surrounded by younger lava flows;
> an island of stability in a landscape of constant change.

kipuka is a Rust-based EST (Enrollment over Secure Transport) server that issues
and renews X.509 certificates at scale.  It targets environments where
compliance, high availability, and hardware-backed key protection are
non-negotiable: government enclaves, regulated enterprise networks, IoT device
fleets, and zero-trust architectures.

## What kipuka does

- **Certificate enrollment and renewal** — full RFC 7030 EST implementation
  including `/cacerts`, `/simpleenroll`, `/simplereenroll`, `/serverkeygen`,
  `/fullcmc`, and `/csrattrs`.
- **Multi-CA high availability** — route enrollment requests to different
  Certificate Authorities based on EST labels, with automatic failover.
- **HSM integration** — PKCS #11 support via `cryptoki` for hardware-backed CA
  signing keys (Thales Luna, YubiHSM 2, SoftHSM, and others).
- **One-time password enrollment** — generate and validate OTPs through the
  admin API for initial device bootstrapping.
- **Profile-based routing** — EST labels map incoming requests to specific CA
  configurations, certificate profiles, and policy sets.
- **Audit logging** — structured, tamper-evident logs suitable for NIAP and
  CA/Browser Forum audit requirements.
- **Dogtag PKI back-end** — delegate signing to a Red Hat Certificate System /
  Dogtag PKI instance when full CA lifecycle management is needed.
- **CoAP transport** — constrained-device enrollment over RFC 7252 (CoAP) for
  IoT environments with limited bandwidth.

## What kipuka does not do

- **Full CA lifecycle management** — kipuka is an enrollment front-end, not a
  complete CA.  It delegates signing to local key material, an HSM, or a
  back-end CA such as Dogtag PKI.  It does not manage CRL publication, OCSP
  responders, or CA key ceremonies.
- **ACME** — kipuka implements EST, not ACME (RFC 8555).  Use a dedicated ACME
  server if your clients speak that protocol.
- **Certificate transparency** — kipuka does not submit pre-certificates to CT
  logs.  Pair it with a CT-aware CA if your trust model requires it.
- **End-entity key management** — private keys for enrolled devices are
  generated client-side (or via `/serverkeygen`).  kipuka never stores
  end-entity private keys beyond the lifetime of a single request.

## Technology stack

| Component | Crate / Library | Role |
| --------- | --------------- | ---- |
| Language | **Rust** (edition 2021) | Memory safety, performance, fearless concurrency |
| HTTP framework | **axum** | Async request routing and middleware |
| TLS | **rustls** | TLS 1.2/1.3 termination with certificate-based client auth |
| Database | **sqlx** | Async database access (SQLite, PostgreSQL) |
| ASN.1 / X.509 | **synta** | DER/BER encoding, CSR parsing, certificate construction |
| PKCS #11 | **cryptoki** | HSM integration for hardware-backed signing |

## Standards implemented

kipuka targets conformance with the following specifications:

| Standard | Scope |
| -------- | ----- |
| **RFC 7030** | Enrollment over Secure Transport (EST) |
| **RFC 8951** | Clarifications and updates to EST |
| **RFC 5272** | Certificate Management over CMS (Full CMC) |
| **RFC 8739** | Short-term, automatically renewed certificates |
| **RFC 7252** | Constrained Application Protocol (CoAP) transport |
| **CA/Browser Forum Baseline Requirements** | TLS certificate issuance policy |
| **NIAP CA Protection Profile v2.0** | Common Criteria for Certificate Authorities |
| **FIPS 140-3** | Cryptographic module validation (via HSM) |

## Who this documentation is for

This book is organized for three audiences:

1. **Operators** — you deploy, configure, and maintain kipuka in production.
   Start with the [Quick Start](./quickstart/install.md) and then read the
   [Operator Guide](./operator/configuration.md) for the full configuration
   reference, HA setup, HSM integration, and audit logging.

2. **API integrators** — you write client software that enrolls certificates
   through kipuka.  The [API Reference](./reference/est-endpoints.md) documents
   every endpoint, request format, and response code.  The
   [Your First Certificate](./quickstart/first-certificate.md) walkthrough
   gives you a working example in five minutes.

3. **Contributors** — you want to build kipuka from source, run the test suite,
   or submit patches.  The [Developer Guide](./developer/architecture.md)
   covers the workspace layout, architecture decisions, database migrations,
   and contribution process.

## Quick navigation

| I want to ... | Start here |
| ------------- | ---------- |
| Run kipuka in a container in under two minutes | [Installation](./quickstart/install.md) |
| Issue my first certificate | [Your First Certificate](./quickstart/first-certificate.md) |
| Understand every configuration knob | [Configuration Reference](./operator/configuration.md) |
| Connect an HSM | [HSM Integration](./operator/hsm.md) |
| Set up multi-CA high availability | [High Availability](./operator/high-availability.md) |
| Integrate with Dogtag PKI | [Dogtag PKI Integration](./operator/dogtag.md) |
| Review RFC conformance details | [RFC Support Reference](./compliance/rfc-support.md) |
| Prepare for a NIAP evaluation | [NIAP CA Protection Profile](./compliance/niap.md) |
| Read the EST API specification | [EST Endpoints](./reference/est-endpoints.md) |
| Build from source and run tests | [Development Setup](./developer/setup.md) |
