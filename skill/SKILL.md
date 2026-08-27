---
name: rust-format
description: Check and apply Rust source formatting with bundled offline Cargo 1.97.1 and rustfmt 1.9.0. Use for `cargo fmt`, `rustfmt`, Rust formatting failures, CI or review format validation, and repository-defined Rust format tasks when Cargo/rustfmt may be missing or network installation is unavailable. Preserve repository formatting commands and toolchain pins, never modify files unless asked, and report formatter-version mismatches. Linux x86-64 only; the bundle does not include rustc or Clippy.
---

# Rust Format

Perform Rust formatting work without installing a Rust toolchain. Preserve the repository's own formatting semantics first; use the bundled Cargo/rustfmt environment when the required formatting tools are not already available.

The bundle supplies `cargo`, `cargo-fmt`, and `rustfmt`. It does **not** supply `rustc`, Clippy, package dependencies, or a general Rust build environment.

## Launcher

Run the launcher through `sh` so execution does not depend on the packaged executable bit:

```sh
sh <skill-dir>/scripts/with-rust-format <command> [args...]
```

Run it with the repository as the current working directory. Resolve `<skill-dir>` to this Skill's directory; do not copy the launcher into the repository. The launcher verifies the payload, extracts it into a writable cache, and prepends the bundled `bin` and `lib` directories to `PATH` and `LD_LIBRARY_PATH`.

## Workflow

1. Inspect formatting conventions before running anything.
   - Read `Cargo.toml` and workspace membership.
   - Check `rustfmt.toml`, `.rustfmt.toml`, and `rust-toolchain.toml` when present.
   - Inspect checked-in format tasks in Pixi, Make, just, CI, or other repository tooling.
   - Treat an explicit repository formatting command as authoritative over a guessed replacement.

2. Determine formatter fidelity.
   - The bundled versions are Cargo 1.97.1 and rustfmt 1.9.0, built from Rust 1.97.1.
   - If the repository pins a materially different Rust/rustfmt version, report the mismatch.
   - If an already-available repository environment provides the intended formatter and can run without installing or updating a toolchain, prefer that environment.
   - Otherwise use the bundled formatter as a fallback, but do not claim an exact reproduction of formatting from a different pinned toolchain.

3. Check formatting without modifying files when the user asks for validation, review, CI diagnosis, or a formatting check.
   - Use the repository-defined check command when available.
   - Otherwise, for a Cargo workspace, run through the launcher:

     ```sh
     cargo fmt --all -- --check
     ```

   - Treat exit status 0 as a formatting pass.
   - Treat a nonzero status with a rustfmt diff as a formatting failure, not a tooling failure.
   - Do not run a modifying format command merely to discover whether formatting is correct.

4. Apply formatting only when the user asks to format, fix, or modify code.
   - Use the repository-defined format command when available.
   - Otherwise, for a Cargo workspace, run through the launcher:

     ```sh
     cargo fmt --all
     ```

   - Inspect the resulting diff afterward.
   - Do not commit formatting changes unless explicitly requested.

5. Use `rustfmt` directly only when Cargo-aware formatting is inappropriate.
   - Prefer `cargo fmt` for Cargo projects because it discovers workspace targets correctly.
   - Use direct `rustfmt` for standalone Rust files or when the repository explicitly does so. Preserve the applicable Rust edition; if no project metadata establishes it, do not guess an edition unless required by the source syntax.

## Offline and scope boundaries

- Do not download, fetch, or install packages, environments, toolchains, or dependencies as a recovery step.
- Do not use `cargo fetch`, `cargo install`, `rustup`, `pixi install`, or equivalent installation commands.
- Do not repeatedly retry deterministic DNS, HTTP, or package-download failures.
- An already-materialized repository environment may still be usable; network failure alone does not prove an installed tool is unavailable.
- Do not expand a formatting request into `cargo build`, `cargo check`, `cargo test`, or Clippy. Those require a compiler and dependencies that this Skill does not provide.
- If a repository's aggregate format/CI task includes non-format checks, report separately what actually ran. Never claim the aggregate task passed if some parts were unavailable or skipped.

## Reporting

Report the operation and evidence, not just a generic success/failure:

- State whether formatting was **checked** or **applied**.
- Identify the workspace, package, or standalone file when relevant.
- Name the repository-defined formatting task if one was used.
- Surface the relevant rustfmt diff or error when formatting fails.
- Distinguish formatting failures from missing-tool/environment failures.
- Mention the bundled rustfmt version when a repository pin differs or exact CI fidelity matters.

## Bundled runtime

The payload contains `cargo`, `cargo-fmt`, `rustfmt`, and the required `libgcc_s` runtime library. It supports Linux x86-64 only and requires glibc 2.34 or newer. If the launcher reports an unsupported platform or an integrity failure, stop and report that condition rather than silently switching to unrelated system tooling.

The bundled rustfmt is reproducibly built from upstream Rust 1.97.1/rustfmt source with a small build-only adaptation that links the compiler-private crates rustfmt needs directly instead of loading `rustc_driver` and LLVM at runtime. It is not an unmodified official upstream rustfmt binary. Read [references/provenance.md](references/provenance.md) only when provenance, licensing, or binary construction matters.
