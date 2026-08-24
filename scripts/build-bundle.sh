#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$repo_root/versions.env"

work_dir=${WORK_DIR:-"$repo_root/_work"}
dist_dir=${DIST_DIR:-"$repo_root/dist"}
bundle_name=rust-format-tools
bundle_dir="$work_dir/$bundle_name"
archive="$dist_dir/$bundle_name.tar.xz"

mkdir -p "$work_dir/downloads" "$dist_dir"
rm -rf "$bundle_dir"
mkdir -p "$bundle_dir/bin" "$bundle_dir/lib" "$bundle_dir/LICENSES"

fetch_verified() {
    local filename=$1
    local url="$RUST_DIST_BASE/$filename"
    local archive_path="$work_dir/downloads/$filename"
    local checksum_path="$archive_path.sha256"

    if [[ ! -f "$archive_path" ]]; then
        curl --fail --location --retry 3 --retry-all-errors --output "$archive_path" "$url"
    fi
    curl --fail --location --retry 3 --retry-all-errors --output "$checksum_path" "$url.sha256"
    (
        cd "$work_dir/downloads"
        sha256sum --check "$(basename "$checksum_path")"
    )
}

source_archive="rustc-${RUST_VERSION}-src.tar.xz"
cargo_archive="cargo-${RUST_VERSION}-${TARGET}.tar.xz"
fetch_verified "$source_archive"
fetch_verified "$cargo_archive"

source_root="$work_dir/rustc-${RUST_VERSION}-src"
rm -rf "$source_root"
tar -C "$work_dir" -xf "$work_dir/downloads/$source_archive"
if [[ ! -d "$source_root" ]]; then
    echo "expected Rust source directory not found: $source_root" >&2
    exit 1
fi

(
    cd "$source_root"
    git apply --check "$repo_root/patches/rustfmt-direct-rustc-crates.patch"
    git apply "$repo_root/patches/rustfmt-direct-rustc-crates.patch"

    # rustfmt does not need a locally built LLVM. Reuse the matching LLVM
    # artifacts produced by Rust CI instead of spending CI time rebuilding LLVM.
    cat > bootstrap.toml <<'EOF_BOOTSTRAP'
[llvm]
download-ci-llvm = true
EOF_BOOTSTRAP

    python3 x.py build src/tools/rustfmt
)

rustfmt_bin="$source_root/build/$TARGET/stage1/bin/rustfmt"
cargo_fmt_bin="$source_root/build/$TARGET/stage1/bin/cargo-fmt"
for file in "$rustfmt_bin" "$cargo_fmt_bin"; do
    if [[ ! -x "$file" ]]; then
        echo "expected built executable not found: $file" >&2
        exit 1
    fi
done

cargo_root="$work_dir/cargo-${RUST_VERSION}-${TARGET}"
rm -rf "$cargo_root"
tar -C "$work_dir" -xf "$work_dir/downloads/$cargo_archive"
cargo_bin=$(find "$cargo_root" -type f -path '*/cargo/bin/cargo' -perm -u+x -print -quit)
if [[ -z "$cargo_bin" ]]; then
    echo "could not locate cargo executable in $cargo_archive" >&2
    exit 1
fi

cp "$cargo_bin" "$bundle_dir/bin/cargo"
cp "$cargo_fmt_bin" "$bundle_dir/bin/cargo-fmt"
cp "$rustfmt_bin" "$bundle_dir/bin/rustfmt"
strip --strip-unneeded "$bundle_dir/bin/cargo" "$bundle_dir/bin/cargo-fmt" "$bundle_dir/bin/rustfmt"

libgcc=$(gcc -print-file-name=libgcc_s.so.1)
if [[ -z "$libgcc" || ! -f "$libgcc" ]]; then
    echo "could not locate libgcc_s.so.1" >&2
    exit 1
fi
cp -L "$libgcc" "$bundle_dir/lib/libgcc_s.so.1"

cp "$source_root/LICENSE-APACHE" "$bundle_dir/LICENSES/Rust-LICENSE-APACHE"
cp "$source_root/LICENSE-MIT" "$bundle_dir/LICENSES/Rust-LICENSE-MIT"
if [[ -f /usr/share/doc/libgcc-s1/copyright ]]; then
    cp /usr/share/doc/libgcc-s1/copyright "$bundle_dir/LICENSES/libgcc_s-copyright.txt"
fi

source_sha=$(awk '{print $1}' "$work_dir/downloads/$source_archive.sha256")
cargo_sha=$(awk '{print $1}' "$work_dir/downloads/$cargo_archive.sha256")
patch_sha=$(sha256sum "$repo_root/patches/rustfmt-direct-rustc-crates.patch" | awk '{print $1}')

cargo_version=$($bundle_dir/bin/cargo --version)
rustfmt_version=$(LD_LIBRARY_PATH="$bundle_dir/lib" "$bundle_dir/bin/rustfmt" --version)
if [[ "$cargo_version" != cargo\ $RUST_VERSION* ]]; then
    echo "unexpected Cargo version: $cargo_version" >&2
    exit 1
fi
if [[ "$rustfmt_version" != *"${RUST_COMMIT:0:10}"* ]]; then
    echo "rustfmt does not report expected Rust commit ${RUST_COMMIT:0:10}: $rustfmt_version" >&2
    exit 1
fi

cat > "$bundle_dir/BUILD-INFO.txt" <<EOF_INFO
rust_version=$RUST_VERSION
rust_commit=$RUST_COMMIT
target=$TARGET
rust_source_url=$RUST_DIST_BASE/$source_archive
rust_source_sha256=$source_sha
cargo_component_url=$RUST_DIST_BASE/$cargo_archive
cargo_component_sha256=$cargo_sha
patch_sha256=$patch_sha
cargo_version=$cargo_version
rustfmt_version=$rustfmt_version
notes=rustfmt is built from Rust $RUST_VERSION with the checked-in patch that directly links compiler-private crates and removes the rustc_driver/LLVM runtime dependency.
EOF_INFO

(
    cd "$bundle_dir"
    sha256sum bin/cargo bin/cargo-fmt bin/rustfmt lib/libgcc_s.so.1 > SHA256SUMS
)

"$repo_root/scripts/test-bundle.sh" "$bundle_dir"

find "$bundle_dir" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
rm -f "$archive" "$archive.sha256"
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
    -C "$work_dir" -c "$bundle_name" | xz -6 -T1 > "$archive"
sha256sum "$archive" > "$archive.sha256"

bytes=$(stat -c %s "$archive")
printf 'built %s (%s bytes)\n' "$archive" "$bytes"
if (( bytes > MAX_SKILL_BYTES )); then
    echo "bundle exceeds skill budget of $MAX_SKILL_BYTES bytes" >&2
    exit 1
fi
