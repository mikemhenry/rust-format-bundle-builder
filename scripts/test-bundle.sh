#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <bundle-directory-or-tar.xz>" >&2
    exit 2
fi

input=$(realpath "$1")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [[ -d "$input" ]]; then
    bundle=$input
else
    tar -C "$tmp" -xf "$input"
    bundle=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'rust-format-tools' -print -quit)
    if [[ -z "$bundle" ]]; then
        echo "archive does not contain rust-format-tools/" >&2
        exit 1
    fi
fi

for tool in cargo cargo-fmt rustfmt; do
    [[ -x "$bundle/bin/$tool" ]] || { echo "missing executable: $tool" >&2; exit 1; }
done
[[ -f "$bundle/lib/libgcc_s.so.1" ]] || { echo "missing libgcc_s.so.1" >&2; exit 1; }
[[ -f "$bundle/SHA256SUMS" ]] || { echo "missing SHA256SUMS" >&2; exit 1; }

(
    cd "$bundle"
    sha256sum --check SHA256SUMS
)

for tool in cargo cargo-fmt rustfmt; do
    linkage=$(LD_LIBRARY_PATH="$bundle/lib" ldd "$bundle/bin/$tool")
    if grep -q 'not found' <<<"$linkage"; then
        echo "$linkage" >&2
        echo "$tool has an unresolved runtime dependency" >&2
        exit 1
    fi
    # Reject compiler/build-environment libraries by identity, not by the
    # absolute directory printed by ldd.  The bundle itself is assembled under
    # _work/ in CI, so a blanket /_work/ check incorrectly rejects the bundled
    # libgcc_s.so.1 that we intentionally ship.
    if grep -Eq 'rustc_driver|libLLVM|\.pixi/|rustfmt-target/|rustc-[^/]+-src/(build|target)/' <<<"$linkage"; then
        echo "$linkage" >&2
        echo "$tool has an unexpected build/toolchain runtime dependency" >&2
        exit 1
    fi

    # If the executable needs libgcc_s, make sure the isolated validation run
    # resolves it from the bundle rather than from the host system.
    if grep -q 'libgcc_s\.so\.1 =>' <<<"$linkage" && \
       ! grep -Fq "libgcc_s.so.1 => $bundle/lib/libgcc_s.so.1" <<<"$linkage"; then
        echo "$linkage" >&2
        echo "$tool did not resolve libgcc_s.so.1 from the bundle" >&2
        exit 1
    fi
done

empty_home="$tmp/home"
probe="$tmp/probe"
mkdir -p "$empty_home" "$probe/crates/a/src" "$probe/crates/b/src"
cat > "$probe/Cargo.toml" <<'EOF_TOML'
[workspace]
members = ["crates/a", "crates/b"]
resolver = "2"
EOF_TOML
for crate in a b; do
    cat > "$probe/crates/$crate/Cargo.toml" <<EOF_TOML
[package]
name = "$crate"
version = "0.1.0"
edition = "2024"
EOF_TOML
    printf 'pub fn answer( )->u32{42}\n' > "$probe/crates/$crate/src/lib.rs"
done

run_fmt() {
    env -i \
        HOME="$empty_home" \
        PATH="$bundle/bin:/usr/bin:/bin" \
        LD_LIBRARY_PATH="$bundle/lib" \
        RUSTC=/definitely/not/a/rustc \
        "$@"
}

set +e
run_fmt cargo fmt --manifest-path "$probe/Cargo.toml" --all -- --check >"$tmp/bad.out" 2>&1
bad_status=$?
set -e
if [[ $bad_status -eq 0 ]]; then
    echo "malformed formatting unexpectedly passed" >&2
    cat "$tmp/bad.out" >&2
    exit 1
fi
if ! grep -q '^Diff in ' "$tmp/bad.out"; then
    echo "formatting failure did not contain a rustfmt diff" >&2
    cat "$tmp/bad.out" >&2
    exit 1
fi

run_fmt cargo fmt --manifest-path "$probe/Cargo.toml" --all
run_fmt cargo fmt --manifest-path "$probe/Cargo.toml" --all -- --check

echo "bundle validation passed"
