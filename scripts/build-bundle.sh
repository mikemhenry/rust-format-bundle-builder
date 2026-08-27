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
toolchain_dir="$work_dir/rust-$RUST_VERSION-$TARGET-toolchain"
rustfmt_target="$work_dir/rustfmt-target"
cargo_home="$work_dir/cargo-home"

mkdir -p "$work_dir/downloads" "$dist_dir"
rm -rf "$bundle_dir" "$toolchain_dir" "$rustfmt_target" "$cargo_home"
mkdir -p "$bundle_dir/bin" "$bundle_dir/lib" "$bundle_dir/LICENSES" "$cargo_home"

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

install_component() {
    local filename=$1
    local component_root="$work_dir/${filename%.tar.xz}"

    rm -rf "$component_root"
    tar -C "$work_dir" -xf "$work_dir/downloads/$filename"
    if [[ ! -x "$component_root/install.sh" ]]; then
        echo "expected installer not found: $component_root/install.sh" >&2
        exit 1
    fi
    "$component_root/install.sh" --prefix="$toolchain_dir" --disable-ldconfig
    rm -rf "$component_root"
}

source_archive="rustc-${RUST_VERSION}-src.tar.xz"
rustc_archive="rustc-${RUST_VERSION}-${TARGET}.tar.xz"
rust_std_archive="rust-std-${RUST_VERSION}-${TARGET}.tar.xz"
cargo_archive="cargo-${RUST_VERSION}-${TARGET}.tar.xz"
for filename in "$source_archive" "$rustc_archive" "$rust_std_archive" "$cargo_archive"; do
    fetch_verified "$filename"
done

source_root="$work_dir/rustc-${RUST_VERSION}-src"
rm -rf "$source_root"
tar -C "$work_dir" -xf "$work_dir/downloads/$source_archive"
if [[ ! -d "$source_root" ]]; then
    echo "expected Rust source directory not found: $source_root" >&2
    exit 1
fi

# Use the official release compiler only as a build tool. Building rustfmt via
# x.py would classify it as ToolRustcPrivate and deliberately link it against
# compiler artifacts from a bootstrapped sysroot, recreating the rustc_driver
# runtime dependency that this bundle is designed to avoid.
install_component "$rustc_archive"
install_component "$rust_std_archive"
install_component "$cargo_archive"

build_rustc_version=$($toolchain_dir/bin/rustc --version)
build_cargo_version=$($toolchain_dir/bin/cargo --version)
if [[ "$build_rustc_version" != rustc\ $RUST_VERSION* ]]; then
    echo "unexpected build rustc version: $build_rustc_version" >&2
    exit 1
fi
if [[ "$build_cargo_version" != cargo\ $RUST_VERSION* ]]; then
    echo "unexpected build Cargo version: $build_cargo_version" >&2
    exit 1
fi

source_patch="$repo_root/patches/rustfmt-direct-rustc-crates.patch"
(
    cd "$source_root"

    # The extracted Rust source lives underneath this builder repository's
    # work directory. Avoid `git apply` here: Git can discover the enclosing
    # builder worktree, which makes the patch target ambiguous. Apply the
    # source patch directly to the extracted tree instead.
    patch --dry-run --batch --forward -p1 < "$source_patch"
    patch --batch --forward -p1 < "$source_patch"

    # Fail before the expensive Cargo build if the portable-linkage
    # transformation did not actually land. The stock rustfmt source loads
    # compiler-private crates from the sysroot and explicitly pulls in
    # rustc_driver; our build must instead use the checked-in path
    # dependencies and must not reference rustc_driver.
    if grep -Eq '^extern crate (rustc_ast|rustc_ast_pretty|rustc_data_structures|rustc_errors|rustc_expand|rustc_parse|rustc_session|rustc_span|thin_vec|rustc_driver);' \
        src/tools/rustfmt/src/lib.rs; then
        echo "rustfmt source patch did not remove sysroot extern-crate loading" >&2
        sed -n '1,35p' src/tools/rustfmt/src/lib.rs >&2
        exit 1
    fi
    if grep -q 'rustc_driver' src/tools/rustfmt/src/bin/main.rs; then
        echo "rustfmt source patch did not remove rustc_driver from bin/main.rs" >&2
        exit 1
    fi
    for dependency in \
        rustc_ast \
        rustc_ast_pretty \
        rustc_data_structures \
        rustc_errors \
        rustc_expand \
        rustc_parse \
        rustc_session \
        rustc_span; do
        expected_path_line="$dependency = { path = \"../../../compiler/$dependency\" }"
        if ! grep -Fq "$expected_path_line" src/tools/rustfmt/Cargo.toml; then
            echo "rustfmt source patch did not add path dependency: $dependency" >&2
            exit 1
        fi
    done
    if ! grep -Fq 'thin-vec = "0.2.15"' src/tools/rustfmt/Cargo.toml; then
        echo "rustfmt source patch did not add thin-vec dependency" >&2
        exit 1
    fi

    # The patched rustfmt uses unstable compiler-private crates as ordinary
    # path dependencies. RUSTC_BOOTSTRAP permits those in this controlled
    # in-tree build. Keep git discovery inside the extracted source tree so
    # rustfmt's build.rs cannot accidentally report the builder repository's
    # commit as Rust provenance.
    # Do not let Cargo discover the GitHub runner's rustup shims. The Rust
    # source tree contains rust-toolchain.toml, so invoking a rustup-proxied
    # `rustc` from here would make rustup try to materialize/update that
    # toolchain instead of using the release compiler installed above.
    export PATH="$toolchain_dir/bin:/usr/bin:/bin"
    export CARGO_HOME="$cargo_home"
    export CARGO_TARGET_DIR="$rustfmt_target"
    export RUSTC="$toolchain_dir/bin/rustc"
    export GIT_CEILING_DIRECTORIES="$source_root"
    export RUSTC_BOOTSTRAP=1
    unset RUSTUP_HOME RUSTUP_TOOLCHAIN RUSTC_WRAPPER RUSTFLAGS CARGO_ENCODED_RUSTFLAGS

    # Compiler crates use cfg(bootstrap) in a few diagnostic/doc attributes.
    # We are not a bootstrap build, so do not define the cfg; only teach
    # rustc's check-cfg lint that the name is expected. This is diagnostic-only
    # and leaves cfg(bootstrap) false.
    export RUSTFLAGS='--check-cfg=cfg(bootstrap)'

    # Compiler-private crates are normally built through bootstrap, which
    # supplies release/host metadata consumed with env!() at compile time.
    # Direct Cargo intentionally bypasses bootstrap, so reproduce that
    # metadata from the pinned official release compiler instead of adding
    # variables reactively as individual compiler crates request them.
    rustc_verbose=$($RUSTC --version --verbose)
    cfg_ver_hash=$(awk -F': ' '/^commit-hash:/ {print $2}' <<< "$rustc_verbose")
    cfg_ver_date=$(awk -F': ' '/^commit-date:/ {print $2}' <<< "$rustc_verbose")
    cfg_release=$(awk -F': ' '/^release:/ {print $2}' <<< "$rustc_verbose")
    cfg_host=$(awk -F': ' '/^host:/ {print $2}' <<< "$rustc_verbose")
    cfg_short_commit=${cfg_ver_hash:0:9}
    cfg_version=${build_rustc_version#rustc }

    if [[ "$cfg_release" != "$RUST_VERSION" ]]; then
        echo "unexpected rustc release metadata: $cfg_release" >&2
        exit 1
    fi
    if [[ "$cfg_ver_hash" != "$RUST_COMMIT" ]]; then
        echo "unexpected rustc commit metadata: $cfg_ver_hash" >&2
        exit 1
    fi
    if [[ "$cfg_host" != "$TARGET" ]]; then
        echo "unexpected rustc host metadata: $cfg_host" >&2
        exit 1
    fi
    if [[ -z "$cfg_ver_date" ]]; then
        echo "rustc did not report commit-date metadata" >&2
        exit 1
    fi

    export CFG_COMMIT_DATE="$cfg_ver_date"
    export CFG_COMMIT_HASH="$cfg_ver_hash"
    export CFG_COMPILER_BUILD_TRIPLE="$cfg_host"
    export CFG_COMPILER_HOST_TRIPLE="$cfg_host"
    export CFG_RELEASE="$cfg_release"
    export CFG_RELEASE_CHANNEL=stable
    export CFG_RELEASE_NUM="$RUST_VERSION"
    export CFG_SHORT_COMMIT_HASH="$cfg_short_commit"
    export CFG_VERSION="$cfg_version"
    export CFG_VER_DATE="$cfg_ver_date"
    export CFG_VER_HASH="$cfg_ver_hash"
    export CFG_VIRTUAL_RUST_SOURCE_BASE_DIR="/rustc/$cfg_ver_hash"

    resolved_rustc=$(command -v rustc)
    resolved_cargo=$(command -v cargo)
    if [[ "$resolved_rustc" != "$toolchain_dir/bin/rustc" ]]; then
        echo "unexpected rustc on PATH: $resolved_rustc" >&2
        exit 1
    fi
    if [[ "$resolved_cargo" != "$toolchain_dir/bin/cargo" ]]; then
        echo "unexpected Cargo on PATH: $resolved_cargo" >&2
        exit 1
    fi

    # Fail fast if the private compiler + standard library cannot link a normal
    # host executable. This is much cheaper than discovering a toolchain
    # installation problem halfway through the rustfmt build.
    probe_src="$work_dir/toolchain-probe.rs"
    probe_bin="$work_dir/toolchain-probe"
    printf 'fn main() { println!("toolchain-ok"); }\n' > "$probe_src"
    "$RUSTC" "$probe_src" -o "$probe_bin"
    [[ "$($probe_bin)" == toolchain-ok ]]
    rm -f "$probe_src" "$probe_bin"

    cargo build \
        --locked \
        --release \
        --manifest-path src/tools/rustfmt/Cargo.toml \
        --bin rustfmt \
        --bin cargo-fmt
)

rustfmt_bin="$rustfmt_target/release/rustfmt"
cargo_fmt_bin="$rustfmt_target/release/cargo-fmt"
for file in "$rustfmt_bin" "$cargo_fmt_bin"; do
    if [[ ! -x "$file" ]]; then
        echo "expected built executable not found: $file" >&2
        exit 1
    fi
done

cp "$toolchain_dir/bin/cargo" "$bundle_dir/bin/cargo"
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
rustc_sha=$(awk '{print $1}' "$work_dir/downloads/$rustc_archive.sha256")
rust_std_sha=$(awk '{print $1}' "$work_dir/downloads/$rust_std_archive.sha256")
cargo_sha=$(awk '{print $1}' "$work_dir/downloads/$cargo_archive.sha256")
patch_sha=$(sha256sum "$repo_root/patches/rustfmt-direct-rustc-crates.patch" | awk '{print $1}')

cargo_version=$($bundle_dir/bin/cargo --version)
rustfmt_version=$(LD_LIBRARY_PATH="$bundle_dir/lib" "$bundle_dir/bin/rustfmt" --version)
if [[ "$cargo_version" != cargo\ $RUST_VERSION* ]]; then
    echo "unexpected bundled Cargo version: $cargo_version" >&2
    exit 1
fi
if [[ "$rustfmt_version" != rustfmt\ 1.9.0* ]]; then
    echo "unexpected rustfmt version: $rustfmt_version" >&2
    exit 1
fi

cat > "$bundle_dir/BUILD-INFO.txt" <<EOF_INFO
rust_version=$RUST_VERSION
rust_commit=$RUST_COMMIT
target=$TARGET
rust_source_url=$RUST_DIST_BASE/$source_archive
rust_source_sha256=$source_sha
build_rustc_url=$RUST_DIST_BASE/$rustc_archive
build_rustc_sha256=$rustc_sha
build_rust_std_url=$RUST_DIST_BASE/$rust_std_archive
build_rust_std_sha256=$rust_std_sha
cargo_component_url=$RUST_DIST_BASE/$cargo_archive
cargo_component_sha256=$cargo_sha
patch_sha256=$patch_sha
build_rustc_version=$build_rustc_version
build_cargo_version=$build_cargo_version
cargo_version=$cargo_version
rustfmt_version=$rustfmt_version
notes=rustfmt is built directly with the official Rust $RUST_VERSION release toolchain from the checked-in patched source; x.py/bootstrap is intentionally not used so rustfmt does not inherit the ToolRustcPrivate rustc_driver/LLVM runtime linkage.
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
(
    cd "$dist_dir"
    sha256sum "$bundle_name.tar.xz" > "$bundle_name.tar.xz.sha256"
)

# Validate the exact distributable archive after the tar/xz round trip, not
# only the staging directory used to create it.
"$repo_root/scripts/test-bundle.sh" "$archive"

bytes=$(stat -c %s "$archive")
printf 'built %s (%s bytes)\n' "$archive" "$bytes"
if (( bytes > MAX_SKILL_BYTES )); then
    echo "bundle exceeds skill budget of $MAX_SKILL_BYTES bytes" >&2
    exit 1
fi
