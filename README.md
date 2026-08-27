# rust-format-bundle-builder

Build the small Linux x86-64 Rust formatting payload used by the `rust-format` ChatGPT Skill.

The bundle contains `cargo`, `cargo-fmt`, a specially linked `rustfmt`, and `libgcc_s.so.1`. It intentionally does **not** contain `rustc`, `rustc_driver`, LLVM, Clippy, or a Rust sysroot.

The rustfmt modification is narrow: compiler-private crates used by rustfmt are linked directly as normal path dependencies, and the `rustc_driver` dependency/ICE hook are removed. This preserves rustfmt's formatting implementation while avoiding the large `rustc_driver` + LLVM runtime closure.

## Build

On a supported x86-64 Linux host with the prerequisites installed:

```fish
./scripts/build-bundle.sh
```

The script downloads and verifies the Rust 1.97.1 source plus the matching official rustc, standard-library, and Cargo components from `static.rust-lang.org`, applies `patches/rustfmt-direct-rustc-crates.patch`, and builds rustfmt/cargo-fmt directly with that pinned release toolchain. The build uses an isolated `CARGO_HOME`, explicitly pins `RUSTC` and `PATH` to the private toolchain, reconstructs the `CFG_*` release/host metadata that Rust bootstrap normally supplies to compiler crates, and recognizes (without enabling) the `bootstrap` cfg name used by compiler-crate diagnostics. It intentionally bypasses `x.py` because Rust bootstrap classifies rustfmt as a `ToolRustcPrivate` tool and links it against compiler artifacts, which would recreate the `rustc_driver`/LLVM runtime dependency this bundle is designed to remove. The script then assembles the runtime payload, runs isolated formatting tests with a deliberately invalid `RUSTC`, packages the archive, round-trip validates that exact archive, and writes:

```text
dist/rust-format-tools.tar.xz
dist/rust-format-tools.tar.xz.sha256
```

The `.sha256` sidecar contains the archive's relative filename, so a downloaded pair can be checked directly with `sha256sum -c rust-format-tools.tar.xz.sha256`. The final archive is rejected if it exceeds 25,000,000 bytes.

## Skill package

The human-maintained ChatGPT Skill source lives under `skill/`. The generated 13 MB formatter payload is deliberately not committed there; `scripts/build-skill.sh` verifies the already-built bundle, stages the Skill source, injects `dist/rust-format-tools.tar.xz`, exercises the staged launcher with an invalid `RUSTC`, and packages the complete installable Skill as `dist/skill.zip`.

After building the bundle:

```fish
./scripts/build-skill.sh
```

The checked-in launcher and provenance intentionally pin the current payload hashes. If a future bundle changes, Skill packaging fails until those records are updated, preventing an accidentally stale Skill from being published. `build-skill.sh` injects the canonical rustfmt source patch from `patches/` into the packaged Skill for standalone provenance, avoiding a second checked-in copy that could drift.

## CI

`.github/workflows/build.yml` runs the same build on `ubuntu-22.04` for pushes, pull requests, and manual dispatches, then builds the installable Skill and uploads `skill.zip` alongside the `.tar.xz` and checksum as unwrapped GitHub Actions artifacts.

The workflow pins `actions/checkout` and `actions/upload-artifact` to full commit SHAs, with the corresponding release versions kept in comments for reviewability. `.github/dependabot.yml` checks GitHub Actions dependencies quarterly and proposes updates to those immutable pins.

## Validation

The bundle test accepts either the staging directory or the final `.tar.xz`. It verifies the bundle's internal `SHA256SUMS`, then runs with an almost empty environment, an empty `HOME`, and `RUSTC=/definitely/not/a/rustc`. It verifies that:

- `cargo fmt --all -- --check` rejects deliberately misformatted members of a Cargo workspace.
- `cargo fmt --all` fixes the workspace.
- A subsequent formatting check passes.
- `rustfmt` has no runtime dependency on `rustc_driver`, LLVM, a Pixi environment, or the Rust build directory.

You can validate an existing archive locally:

```fish
./scripts/test-bundle.sh dist/rust-format-tools.tar.xz
```

## Reproducibility boundary

This repository pins the Rust version and target, verifies the official source/compiler/standard-library/Cargo component checksums, checks in the complete source patch, records the build-tool versions, normalizes archive metadata, and uses single-threaded XZ output.

It is **not yet a promise of byte-for-byte reproducibility across time**. In particular, GitHub's `ubuntu-22.04` runner image and the `libgcc_s.so.1` copied from that runner can receive updates. The first goal is a repeatable, auditable functional build for the Skill. A future hardening pass can pin the build image/runtime library if exact bit reproducibility becomes useful.

## Updating Rust

1. Change `RUST_VERSION`, `RUST_COMMIT`, and `SOURCE_DATE_EPOCH` in `versions.env`.
2. Rebase `patches/rustfmt-direct-rustc-crates.patch` onto the new Rust source.
3. Run the build and isolated tests.
4. Confirm the archive remains below the Skill size limit.
5. Update the pinned payload/file hashes and provenance under `skill/`.
6. Run `./scripts/build-skill.sh` and validate the resulting `dist/skill.zip`.

## Licensing

Repository helper code is dual-licensed under MIT or Apache-2.0. The produced bundle includes the Rust project's MIT/Apache license texts. `libgcc_s` is copied from the build host; on Ubuntu the package copyright notice is included when available.
