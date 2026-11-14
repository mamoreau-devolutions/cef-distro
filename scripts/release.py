#!/usr/bin/env python3
"""Prepare a single draft release from an unmodified CEF minimal archive."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile

import cef

EXPORTS = (
    "cef_isolated_clipboard_enabled", "cef_isolated_clipboard_generation",
    "cef_isolated_clipboard_read", "cef_isolated_clipboard_write",
    "cef_isolated_clipboard_write_files", "cef_remote_media_enabled",
    "cef_remote_camera_get_format", "cef_remote_camera_push_frame",
    "cef_remote_microphone_active", "cef_remote_microphone_push",
    "cef_remote_webauthn_enabled", "cef_remote_webauthn_set_handler",
    "cef_remote_webauthn_respond", "cef_remote_webauthn_set_platform_available",
)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def pe_exports(data):
    """Return exported names from a PE32/PE32+ image."""
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("Not a PE image")
    sections, optional_size = struct.unpack_from("<H12xH", data, pe + 6)
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    directories = optional + {0x10B: 96, 0x20B: 112}[magic]
    export_rva = struct.unpack_from("<I", data, directories)[0]
    table = optional + optional_size
    ranges = [struct.unpack_from("<8xIIII", data, table + 40 * i) for i in range(sections)]

    def offset(rva):
        for virtual_size, address, raw_size, pointer in ranges:
            if address <= rva < address + max(virtual_size, raw_size):
                return rva - address + pointer
        raise ValueError(f"RVA outside sections: {rva:#x}")

    if not export_rva:
        return []
    count, names = struct.unpack_from("<24xI4xI", data, offset(export_rva))
    result = []
    for index in range(count):
        start = offset(struct.unpack_from("<I", data, offset(names) + 4 * index)[0])
        result.append(data[start:data.index(b"\0", start)].decode("ascii"))
    return result


def verify_exports(archive, platform, nm="nm"):
    root = archive.name.removesuffix(".tar.bz2")
    library = {"linux": "libcef.so", "windows": "libcef.dll",
               "macos": "Chromium Embedded Framework"}[platform]
    with tarfile.open(archive, "r:bz2") as tar:
        members = tar.getmembers()
        if any(PurePosixPath(m.name).parts[:1] != (root,) or
               ".." in PurePosixPath(m.name).parts for m in members):
            raise ValueError("Archive has an unexpected top-level directory or unsafe path")
        candidates = [m for m in members if m.isfile()
                      and PurePosixPath(m.name).name == library
                      and "Release" in PurePosixPath(m.name).parts]
        if len(candidates) != 1:
            raise ValueError(f"Expected one Release/{library}, found {len(candidates)}")
        with tempfile.TemporaryDirectory(prefix="cef-exports-") as temp:
            binary = Path(temp) / library
            with tar.extractfile(candidates[0]) as source, binary.open("wb") as target:
                shutil.copyfileobj(source, target)
            if platform == "windows":
                output = "\n".join(pe_exports(binary.read_bytes()))
            else:
                command = ([nm, "-g", "--defined-only", str(binary)] if platform == "macos"
                           else [nm, "-D", "--defined-only", str(binary)])
                output = subprocess.check_output(command, text=True, errors="replace")
    missing = [name for name in EXPORTS if not re.search(
        rf"(?<![A-Za-z0-9_])_?{name}(?![A-Za-z0-9_])", output)]
    if missing:
        raise ValueError("Missing patched exports: " + ", ".join(missing))


def prepare(build, output, platform, arch, revision):
    cef.verify_patch_identity()
    suffixes = {
        ("linux", "x64"): "linux64", ("linux", "arm64"): "linuxarm64",
        ("macos", "x64"): "macosx64", ("macos", "arm64"): "macosarm64",
        ("windows", "x64"): "windows64", ("windows", "arm64"): "windowsarm64",
    }
    name = f"cef_binary_{cef.PINS['cef_version']}_{suffixes[(platform, arch)]}_minimal.tar.bz2"
    archive = build / "chromium" / "src" / "cef" / "binary_distrib" / name
    if not archive.is_file():
        raise FileNotFoundError(f"Expected standard-named minimal archive: {archive}")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Expected a full repository commit SHA")
    # Chromium's llvm-nm reads cross-compiled binaries regardless of host architecture.
    llvm_nm = build / "chromium" / "src" / "third_party" / "llvm-build" / "Release+Asserts" / "bin" / "llvm-nm"
    verify_exports(archive, platform, str(llvm_nm) if llvm_nm.is_file() else "nm")
    output.mkdir()
    target = output / name
    shutil.copyfile(archive, target)
    checksum = sha256(target)
    (output / "SHA256SUMS").write_text(f"{checksum}  {name}\n", encoding="utf-8")
    manifest = {
        "schema": 1, "status": "draft-unvalidated", "repository_commit": revision,
        "platform": platform, "architecture": arch, "archive": name,
        "sha256": checksum, "pins": cef.PINS,
        "patch_git_blobs": cef.PATCH_BLOBS,
        "patch_sha256": {name: sha256(cef.ROOT / "patches" / name)
                         for name in cef.PATCH_BLOBS},
        "verified_exports": list(EXPORTS),
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared {target}: {checksum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--platform", choices=("linux", "macos", "windows"), required=True)
    parser.add_argument("--arch", choices=("x64", "arm64"), required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    prepare(args.build, args.output, args.platform, args.arch, args.revision)


if __name__ == "__main__":
    main()
