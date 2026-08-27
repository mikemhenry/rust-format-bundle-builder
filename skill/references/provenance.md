# Rust Format Payload Provenance

The bundled payload is the reproducible CI-built artifact from `mikemhenry/rust-format-bundle-builder`, built on GitHub Actions from commit `2f20cc9fd339d570c86311d9835539d07a51a086`. The builder verifies all downloaded Rust release components against the official `static.rust-lang.org` checksums, applies the checked-in rustfmt source patch, builds directly with the pinned Rust 1.97.1 release toolchain, validates the staged bundle, archives it reproducibly, extracts the final archive, and validates it again.

The payload was additionally revalidated while updating this Skill: its external checksum matched, its internal `SHA256SUMS` matched, and the launcher completed the offline formatting round trip with `RUSTC` pointing to a nonexistent path.

## Payload

- Archive: `assets/rust-format-tools.tar.xz`
- SHA-256: `6352c6be19eb2daaa012062e31bd8b1b5b7f1027dfc311a0942083dc5de07039`
- Cargo: `cargo 1.97.1 (c980f4866 2026-06-30)`
- rustfmt: `rustfmt 1.9.0`
- Rust source release: `1.97.1`, commit `8bab26f4f68e0e26f0bb7960be334d5b520ea452`
- Platform: Linux x86-64
- Maximum observed GLIBC symbol requirement across the bundled executables: `GLIBC_2.34`

Extracted-file SHA-256 values:

- `bin/cargo`: `5a16ac90925b488d889cde417f0cf813289acf0dd13fa61671e0d869915a4762`
- `bin/cargo-fmt`: `29355c1503fe3be23baa7e98ea0cdbf00236d9fabd809e31dea4011929d5fc56`
- `bin/rustfmt`: `37de000cbb42d8f4eb4c6e1aeecc9a87b364e051decd815966ca70563753b98c`
- `lib/libgcc_s.so.1`: `fc9d43b2f6c20e53b009238f767c5b949d202389e20de9e202ea684b4ba3729a`

The archive's embedded `BUILD-INFO.txt` records the official component URLs and checksums used by the reproducible builder. Its source patch SHA-256 is `0c9f2dc7cdc543b5562b070332184ab69640126c3916ac9a8b7e0a7afdb89cd5`, which matches the canonical builder patch. `build-skill.sh` injects that exact patch into packaged Skills as `references/rustfmt-1.97.1-portable.patch`.

## rustfmt build adaptation

The rustfmt binary is built from the Rust 1.97.1 source tree. The adaptation:

- adds direct path dependencies on the compiler-private crates used by rustfmt;
- adds `thin-vec = "0.2.15"` explicitly;
- removes the sysroot `extern crate` declarations and the `rustc_driver` object-code carrier;
- removes the `rustc_driver::install_ice_hook` integration from the rustfmt binary.

This removes runtime dependencies on `librustc_driver` and LLVM while preserving rustfmt's formatting implementation. The exact source diff is injected into packaged Skills as `references/rustfmt-1.97.1-portable.patch` from the builder repository's canonical `patches/rustfmt-direct-rustc-crates.patch`.

## Scope boundary

This payload is intentionally formatting-only. It does not bundle rustc and must not be represented as a general Rust toolchain. Cargo is included for workspace/target discovery used by `cargo fmt`.
