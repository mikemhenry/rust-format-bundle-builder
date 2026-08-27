#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$repo_root/versions.env"

work_dir=${WORK_DIR:-"$repo_root/_work"}
dist_dir=${DIST_DIR:-"$repo_root/dist"}
source_dir="$repo_root/skill"
archive="$dist_dir/rust-format-tools.tar.xz"
checksum="$archive.sha256"
stage_parent="$work_dir/skill-package"
stage="$stage_parent/rust-format"
skill_zip="$dist_dir/skill.zip"

[[ -f "$archive" ]] || { echo "missing bundle: $archive" >&2; exit 1; }
[[ -f "$checksum" ]] || { echo "missing bundle checksum: $checksum" >&2; exit 1; }

(
    cd "$dist_dir"
    sha256sum --check "$(basename "$checksum")"
)

rm -rf "$stage_parent"
mkdir -p "$stage_parent"
cp -a "$source_dir" "$stage"
cp "$archive" "$stage/assets/rust-format-tools.tar.xz"
cp "$repo_root/patches/rustfmt-direct-rustc-crates.patch" \
    "$stage/references/rustfmt-1.97.1-portable.patch"

actual_archive_sha=$(sha256sum "$archive" | awk '{print $1}')
launcher_archive_sha=$(sed -n "s/^ARCHIVE_SHA256='\([0-9a-f]\{64\}\)'$/\1/p" "$stage/scripts/with-rust-format")
if [[ -z "$launcher_archive_sha" || "$launcher_archive_sha" != "$actual_archive_sha" ]]; then
    echo "Skill launcher archive SHA-256 does not match built payload" >&2
    echo "launcher: ${launcher_archive_sha:-missing}" >&2
    echo "payload:  $actual_archive_sha" >&2
    exit 1
fi

# Exercise the staged Skill launcher itself. The payload is formatting-only, so
# rustfmt must work even if RUSTC is deliberately unusable.
rm -rf "$work_dir/skill-cache"
version=$(env \
    XDG_CACHE_HOME="$work_dir/skill-cache" \
    RUSTC=/definitely/not/a/rustc \
    sh "$stage/scripts/with-rust-format" rustfmt --version)
if [[ "$version" != rustfmt\ 1.9.0* ]]; then
    echo "unexpected Skill rustfmt version: $version" >&2
    exit 1
fi

rm -f "$skill_zip"
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" python3 - "$stage_parent" "$skill_zip" <<'PY'
import os
import stat
import sys
import time
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

root = Path(sys.argv[1])
out = Path(sys.argv[2])
epoch = int(os.environ["SOURCE_DATE_EPOCH"])
zip_dt = time.gmtime(max(epoch, 315532800))[:6]  # ZIP timestamps start in 1980.

with ZipFile(out, "w", compression=ZIP_DEFLATED, compresslevel=6) as zf:
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        arcname = path.relative_to(root).as_posix()
        info = ZipInfo(arcname, zip_dt)
        info.compress_type = ZIP_DEFLATED
        mode = 0o755 if path.name == "with-rust-format" else 0o644
        info.external_attr = (stat.S_IFREG | mode) << 16
        zf.writestr(info, path.read_bytes(), compress_type=ZIP_DEFLATED, compresslevel=6)
PY

bytes=$(stat -c %s "$skill_zip")
printf 'built %s (%s bytes)\n' "$skill_zip" "$bytes"
if (( bytes > MAX_SKILL_BYTES )); then
    echo "Skill package exceeds budget of $MAX_SKILL_BYTES bytes" >&2
    exit 1
fi
