# rust-format-bundle-builder

Build the small Linux x86-64 Rust formatting payload used by the `rust-format` ChatGPT Skill.

The bundle contains `cargo`, `cargo-fmt`, a specially linked `rustfmt`, and `libgcc_s.so.1`. It intentionally does **not** contain `rustc`, `rustc_driver`, LLVM, Clippy, or a Rust sysroot.

The rustfmt modification is narrow: compiler-private crates used by rustfmt are linked directly as normal path dependencies, and the `rustc_driver` dependency/ICE hook are removed. This preserves rustfmt's formatting implementation while avoiding the large `rustc_driver` + LLVM runtime closure.

## Build

On a supported x86-64 Linux host with the prerequisites installed:

```fish
./scripts/build-bundle.sh
```

The script downloads and verifies the Rust 1.97.1 source and Cargo component from `static.rust-lang.org`, applies `patches/rustfmt-direct-rustc-crates.patch`, builds only rustfmt/cargo-fmt, assembles the runtime payload, runs isolated formatting tests with a deliberately invalid `RUSTC`, and writes:

```text
dist/rust-format-tools.tar.xz
dist/rust-format-tools.tar.xz.sha256
```

The final archive is rejected if it exceeds 25,000,000 bytes.

## CI

`.github/workflows/build.yml` runs the same build on `ubuntu-22.04` for pushes, pull requests, and manual dispatches, then uploads the `.tar.xz` and checksum as unwrapped GitHub Actions artifacts.

The workflow uses `actions/checkout@v7` and `actions/upload-artifact@v7`. GitHub's current checkout releases include v7, and upload-artifact v7 supports uploading a single file without wrapping it in an additional ZIP.

## Validation

The bundle test runs with an almost empty environment, an empty `HOME`, and `RUSTC=/definitely/not/a/rustc`. It verifies that:

- `cargo fmt --all -- --check` rejects deliberately misformatted members of a Cargo workspace.
- `cargo fmt --all` fixes the workspace.
- A subsequent formatting check passes.
- `rustfmt` has no runtime dependency on `rustc_driver`, LLVM, a Pixi environment, or the Rust build directory.

You can validate an existing archive locally:

```fish
./scripts/test-bundle.sh dist/rust-format-tools.tar.xz
```

## Reproducibility boundary

This repository pins the Rust version and target, verifies official upstream download checksums, checks in the complete source patch, normalizes archive metadata, and uses single-threaded XZ output.

It is **not yet a promise of byte-for-byte reproducibility across time**. In particular, GitHub's `ubuntu-22.04` runner image and the `libgcc_s.so.1` copied from that runner can receive updates. The first goal is a repeatable, auditable functional build for the Skill. A future hardening pass can pin the build image/runtime library if exact bit reproducibility becomes useful.

## Updating Rust

1. Change `RUST_VERSION`, `RUST_COMMIT`, and `SOURCE_DATE_EPOCH` in `versions.env`.
2. Rebase `patches/rustfmt-direct-rustc-crates.patch` onto the new Rust source.
3. Run the build and isolated tests.
4. Confirm the archive remains below the Skill size limit.
5. Update the Skill's bundled asset and recorded SHA-256.

## Licensing

Repository helper code is dual-licensed under MIT or Apache-2.0. The produced bundle includes the Rust project's MIT/Apache license texts. `libgcc_s` is copied from the build host; on Ubuntu the package copyright notice is included when available.
