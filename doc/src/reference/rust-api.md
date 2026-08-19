# Rust API Reference

kipuka's Rust API documentation is auto-generated from source code doc comments
using `cargo doc` and published alongside this book.  The generated docs are
the authoritative reference for types, traits, function signatures, and module
structure.

**Online API docs:** [kipuka.dev/api/kipuka/](https://kipuka.dev/api/kipuka/)

## Workspace crates

The kipuka workspace is organized into six crates, each with a focused
responsibility:

| Crate | Path | API docs | Description |
| ----- | ---- | -------- | ----------- |
| **kipuka-est** | `crates/kipuka-est` | [kipuka_est](https://kipuka.dev/api/kipuka_est/) | EST protocol implementation.  Axum route handlers for all six RFC 7030 operations, TLS listener setup with rustls, mTLS client authentication, CSR validation, and certificate response encoding. |
| **kipuka-hsm** | `crates/kipuka-hsm` | [kipuka_hsm](https://kipuka.dev/api/kipuka_hsm/) | PKCS #11 HSM integration via the `cryptoki` crate.  Manages HSM sessions, slot enumeration, key lookup by label, signing operations (RSA-PSS, ECDSA), and session pool lifecycle. |
| **kipuka-otp** | `crates/kipuka-otp` | [kipuka_otp](https://kipuka.dev/api/kipuka_otp/) | OTP lifecycle management.  Generation of cryptographically random OTP values, salted hash storage, validation against entity ID binding, use-count tracking, and expiry enforcement. |
| **kipuka-util** | `crates/kipuka-util` | [kipuka_util](https://kipuka.dev/api/kipuka_util/) | Shared types and utilities.  Configuration file parsing (TOML), ASN.1 helpers built on `synta`, error type hierarchy, database connection pooling via `sqlx`, and audit log formatting. |
| **kipuka-dogtag** | `crates/kipuka-dogtag` | [kipuka_dogtag](https://kipuka.dev/api/kipuka_dogtag/) | Dogtag PKI REST client.  Submits certificate signing requests to a Dogtag CA subsystem, retrieves signed certificates, and interacts with the KRA subsystem for server-side key generation and escrow. |
| **kipuka-coap** | `crates/kipuka-coap` | [kipuka_coap](https://kipuka.dev/api/kipuka_coap/) | CoAP transport layer (RFC 7252).  Provides EST-over-CoAP endpoints for constrained IoT devices that cannot use HTTP/TLS, with DTLS for transport security. |

## Building the docs locally

To generate and open the API documentation from a local checkout:

```bash
# Clone the repository
git clone https://github.com/czinda/kipuka.git
cd kipuka

# Build docs for all workspace crates (skip dependency docs for speed)
cargo doc --no-deps --open
```

This builds HTML documentation into `target/doc/` and opens it in your
default browser.  The landing page lists all six crates with links to their
module trees.

To build docs for a single crate:

```bash
cargo doc --no-deps -p kipuka-est --open
```

### Including private items

By default, `cargo doc` only documents public API surface.  To include
private functions, types, and modules (useful during development):

```bash
cargo doc --no-deps --document-private-items --open
```

### Prerequisites

Building the docs requires:

- **Rust 1.88+** (edition 2021)
- A working C toolchain (required by `cryptoki` build script for PKCS #11
  header compilation)
- SQLx offline mode or a running database for query checking -- see
  [Development Setup](../developer/setup.md) for details

## Documentation conventions

The codebase follows these doc comment conventions:

- Every public type, trait, function, and module has a `///` doc comment.
- Examples in doc comments are runnable via `cargo test --doc` where practical.
- Cross-references use intra-doc links (`[`OtpStore`]`, `[`CaConfig`]`) for
  navigable HTML output.
- Safety invariants on `unsafe` blocks are documented with `# Safety` sections.
- Error conditions are documented with `# Errors` sections listing the
  specific error variants returned.
