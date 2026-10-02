#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
mkdir -p .build/bin
export PATH="$ROOT/.build/bin:$HOME/.cargo/bin:$PATH"
install_tool() {
  local name="$1" version="$2" url="$3" sha="$4"
  if command -v "$name" >/dev/null && "$name" --version | grep -Fq "$version"; then return; fi
  [[ "$(uname -s)-$(uname -m)" == Linux-x86_64 ]] || { echo "Install $name $version first." >&2; exit 1; }
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$url" -o ".build/$name.tar.gz"
  printf '%s  %s\n' "$sha" ".build/$name.tar.gz" | sha256sum --check
  tar -xzf ".build/$name.tar.gz" -C .build/bin "$name"
}
install_tool mdbook 0.5.3 https://github.com/rust-lang/mdBook/releases/download/v0.5.3/mdbook-v0.5.3-x86_64-unknown-linux-gnu.tar.gz e2fd508a4fac06cbaa9f88b97d27bdc3b55a08946304ca845879fe26a3699e11
install_tool mdbook-mermaid 0.17.1 https://github.com/badboy/mdbook-mermaid/releases/download/v0.17.1/mdbook-mermaid-v0.17.1-x86_64-unknown-linux-gnu.tar.gz 9afcfa5b8463afe606d48595a7ae338564302903e626ea5b6edb8007d29393a5
if ! command -v rustup >/dev/null; then
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 https://sh.rustup.rs -o .build/rustup-init.sh
  sh .build/rustup-init.sh -y --profile minimal --default-toolchain none --no-modify-path
fi
rustup toolchain install 1.97.1 --profile minimal --no-self-update
export RUSTUP_TOOLCHAIN=1.97.1
if ! command -v cmake >/dev/null; then
  python3 -m venv .build/cmake-env
  .build/cmake-env/bin/pip install --disable-pip-version-check cmake==4.1.2
  export PATH="$ROOT/.build/cmake-env/bin:$PATH"
fi
REF="$(tr -d '\n\r' < KIPUKA_REF)"
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || { echo 'KIPUKA_REF requires a full commit SHA.' >&2; exit 1; }
SOURCE="$ROOT/.build/kipuka-source"
if [[ ! -d "$SOURCE/.git" ]]; then
  git init "$SOURCE"
  git -C "$SOURCE" remote add origin https://github.com/czinda/kipuka.git
fi
git -C "$SOURCE" fetch --depth 1 origin "$REF"
git -C "$SOURCE" checkout --detach "$REF"
(cd doc && mdbook build)
export CARGO_TARGET_DIR="$ROOT/.build/api-target"
rm -rf "$CARGO_TARGET_DIR/doc"
# Build the locked vendored OpenSSL rather than depending on the build image's
# system OpenSSL version. This produces documentation, not a deployed PKI server.
cargo doc --locked --workspace --no-deps --features openssl/vendored --manifest-path "$SOURCE/Cargo.toml" \
  --config "build.rustdocflags=[\"--extend-css\",\"$ROOT/api-theme.css\",\"--html-in-header\",\"$ROOT/api-header.html\"]"
rm -rf deploy
mkdir -p deploy/doc deploy/api
cp index.html favicon.svg deploy/
cp -R doc-build/. deploy/doc/
cp -R "$CARGO_TARGET_DIR/doc/." deploy/api/
cp api-index.html deploy/api/index.html
node scripts/build-info.mjs "$REF"
npm run check
