# Contributing

kipuka welcomes contributions.  This document covers the license, code style,
commit conventions, security invariants, and how to report vulnerabilities.

## License

kipuka is licensed under the **GNU General Public License v3.0 or later**
(GPL-3.0-or-later).  The full license text is in the `LICENSE` file at the
repository root.

Source: [https://github.com/czinda/kipuka](https://github.com/czinda/kipuka)

### Contribution licensing

kipuka uses an **inbound = outbound** contribution model.  By submitting a
patch, you agree that your contribution is licensed under the same
GPL-3.0-or-later terms as the rest of the project.

### Developer Certificate of Origin (DCO)

All commits must include a `Signed-off-by` trailer certifying that you have
the right to submit the contribution under the project's license.  This
follows the [Developer Certificate of Origin](https://developercertificate.org/)
(DCO v1.1).

Add it automatically with `git commit -s`:

```bash
git commit -s -m "Add OTP lockout duration configuration"
```

This appends a line like:

```
Signed-off-by: Your Name <your.email@example.com>
```

Commits without a valid `Signed-off-by` line will be rejected.

## Code style

### Formatting

All Rust code must pass `cargo fmt` with no modifications:

```bash
cargo fmt --check
```

Format before committing:

```bash
cargo fmt
```

### Linting

All code must compile cleanly under `cargo clippy` with warnings treated as
errors:

```bash
cargo clippy -- -D warnings
```

Fix clippy warnings before submitting.  If a specific lint is intentionally
suppressed, add an `#[allow(...)]` attribute with a comment explaining why:

```rust
// Clippy suggests using `map_or`, but the explicit match is clearer
// for this error-handling path.
#[allow(clippy::manual_map)]
fn resolve_ca(&self, label: &str) -> Option<&CaConfig> {
    // ...
}
```

### Rust edition

kipuka uses Rust edition 2021.  Do not use unstable features or nightly-only
APIs.

## Commit message conventions

Follow a conventional commit style:

```
<type>: <short summary>

<optional body explaining what and why>

Signed-off-by: Your Name <your.email@example.com>
```

### Types

| Type | Use for |
| ---- | ------- |
| `feat` | New functionality visible to users or API consumers |
| `fix` | Bug fix |
| `refactor` | Code restructuring with no behavior change |
| `test` | Adding or updating tests |
| `docs` | Documentation changes |
| `chore` | Build system, CI, dependency updates |
| `security` | Security-related fixes (see disclosure process below) |

### Examples

```
feat: add GSSAPI principal-to-subject mapping

Administrators can now define explicit mappings from Kerberos principals
to X.509 subject DNs in kipuka.toml under [gssapi.principal_mapping].
A default template is also supported for unmapped principals.

Signed-off-by: Alice Engineer <alice@example.com>
```

```
fix: prevent OTP reuse after max_uses reached

The use_count check was off-by-one, allowing one extra use beyond
max_uses.  This commit corrects the comparison to use strict less-than.

Signed-off-by: Bob Developer <bob@example.com>
```

### Scope

Keep commits focused on a single logical change.  A commit that adds a
feature, fixes a bug, and reformats unrelated code should be split into
three commits.

## Security invariants

The following invariants are critical to kipuka's security posture.  Any patch
that weakens or removes these protections will be rejected.

### OTP values are never stored in plaintext

OTP tokens are hashed with argon2id (or the configured hash algorithm)
immediately upon generation.  The raw token is returned to the administrator
exactly once in the HTTP response.  Only the hash is persisted to the
database.

```rust
// Correct: hash before storage
let hash = argon2::hash_encoded(otp.as_bytes(), &salt, &config)?;
db::store_otp_hash(entity_id, &hash).await?;

// WRONG: never store the raw OTP
// db::store_otp(entity_id, &otp).await?;
```

### CA private keys are zeroized on drop

All types that hold CA private key material implement `Zeroize` and
`ZeroizeOnDrop` from the `zeroize` crate.  This ensures that key bytes are
overwritten with zeros when the value goes out of scope, preventing residual
key material in freed memory.

```rust
use zeroize::{Zeroize, ZeroizeOnDrop};

#[derive(Zeroize, ZeroizeOnDrop)]
struct CaPrivateKey {
    bytes: Vec<u8>,
}
```

Never use `std::mem::forget` or `ManuallyDrop` on types containing key
material.

### Timing-safe comparisons for all authentication checks

All authentication comparisons (OTP validation, bearer token checks, HMAC
verification) use constant-time operations from the `subtle` crate.  This
prevents timing side-channel attacks that could leak information about valid
credentials.

```rust
use subtle::ConstantTimeEq;

fn verify_token(provided: &[u8], expected: &[u8]) -> bool {
    provided.ct_eq(expected).into()
}
```

Never use `==` for comparing secrets, tokens, or hashes.

### CSPRNG for serial numbers

Certificate serial numbers are generated using `OsRng` from the `rand` crate,
which delegates to the operating system's cryptographically secure random
number generator (`/dev/urandom` on Linux, `CryptGenRandom` on Windows).

```rust
use rand::rngs::OsRng;
use rand::RngCore;

fn generate_serial() -> [u8; 20] {
    let mut serial = [0u8; 20];
    OsRng.fill_bytes(&mut serial);
    serial[0] &= 0x7f; // Ensure positive (RFC 5280)
    serial
}
```

Never use `rand::thread_rng()`, `rand::random()`, or any non-CSPRNG source
for serial numbers, nonces, or key material.  Non-cryptographic PRNGs are
predictable and can lead to serial number collisions or key compromise.

### No logging of sensitive material

The following data must never appear in log output at any verbosity level,
including `RUST_LOG=trace`:

- CA private keys or key bytes
- OTP token values (raw or hashed)
- CSR private keys
- HSM PINs or passwords
- Bearer tokens
- TLS session keys

When logging certificate-related operations, log only the certificate
fingerprint, subject DN, serial number, and outcome.  When logging OTP
operations, log only the entity ID and outcome (success/failure).

```rust
// Correct: log the fingerprint, not the key
tracing::info!(
    entity_id = %entity_id,
    fingerprint = %cert.fingerprint_sha256(),
    "Certificate issued"
);

// WRONG: never log key material
// tracing::debug!(key = ?ca_key, "Signing with CA key");
```

If you are unsure whether a value is sensitive, treat it as sensitive.

## Reporting security vulnerabilities

**Do not open a public issue for security vulnerabilities.**

Report vulnerabilities privately by emailing **security@kipuka.dev** with:

1. A description of the vulnerability
2. Steps to reproduce
3. Affected versions (if known)
4. Any suggested fix (optional)

You will receive an acknowledgment within 48 hours and a detailed response
within 7 business days.  Security fixes are developed privately and disclosed
after a patch is available.

If you prefer encrypted communication, request a PGP key in your initial
email.

## Submitting patches

### Workflow

1. Fork the repository on GitHub
2. Create a feature branch from `main`
3. Make your changes (following the conventions above)
4. Run the full check suite:

   ```bash
   cargo fmt --check
   cargo clippy -- -D warnings
   cargo test
   cargo test --features integration
   ```

5. Commit with `Signed-off-by` (use `git commit -s`)
6. Open a pull request against `main`

### Pull request checklist

Before requesting review, verify:

- [ ] All commits have `Signed-off-by` trailers
- [ ] `cargo fmt --check` passes
- [ ] `cargo clippy -- -D warnings` passes
- [ ] `cargo test` passes
- [ ] `cargo test --features integration` passes
- [ ] New database migrations exist for all three backends (if applicable)
- [ ] Security invariants listed above are preserved
- [ ] No sensitive data in log statements, comments, or test fixtures

### Review process

All pull requests require at least one maintainer review.  Security-sensitive
changes require two reviews.  CI must pass before merge.

## Feature requests and bug reports

File issues on the GitHub issue tracker:

[https://github.com/czinda/kipuka/issues](https://github.com/czinda/kipuka/issues)

For feature requests, describe the use case and expected behavior.  For bugs,
include:

- kipuka version (`kipuka --version`)
- Operating system and architecture
- Database backend and version
- Steps to reproduce
- Expected vs. actual behavior
- Relevant log output (with sensitive data redacted)
