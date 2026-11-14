#!/usr/bin/env python3
"""Verify patches against pinned source or build in a new, dedicated directory."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
PINS = json.loads((ROOT / "pins.json").read_text(encoding="utf-8"))
PATCHES = {
    "cef": ["isolated-clipboard.patch", "remote-devices-cef.patch"],
    "chromium": ["remote-devices-chromium.patch", "in-process-audio-shutdown.patch"],
}
POSIX_PATCH = "disable-chromium-shutdown-signals.patch"
PATCH_BLOBS = {
    "isolated-clipboard.patch": "ffb4fca9488c0851a0e4b6d6851dc79b3a33c14b",
    "remote-devices-cef.patch": "2febae6e2f9c88d4565c87146f9950732f795b24",
    "remote-devices-chromium.patch": "c4a158a7c6108c8316e5111eb1ea7415abeac830",
    "in-process-audio-shutdown.patch": "ac5215315c4e8439d88474989f245f2750c43116",
    "disable-chromium-shutdown-signals.patch": "bd49755a5de794d2b7b16e865b00b2332611f770",
}


def physical_memory():
    if sys.platform == "win32":
        class MemoryStatus(ctypes.Structure):
            _fields_ = [("length", ctypes.c_ulong), ("load", ctypes.c_ulong),
                        ("total", ctypes.c_ulonglong), ("available", ctypes.c_ulonglong),
                        ("total_page", ctypes.c_ulonglong), ("available_page", ctypes.c_ulonglong),
                        ("total_virtual", ctypes.c_ulonglong), ("available_virtual", ctypes.c_ulonglong),
                        ("available_extended", ctypes.c_ulonglong)]
        status = MemoryStatus()
        status.length = ctypes.sizeof(status)
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
            raise ctypes.WinError()
        return status.total
    if sys.platform == "darwin":
        return int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True))
    return os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")


def run(*args, cwd=None):
    print("+", *map(str, args), flush=True)
    subprocess.run(args, cwd=cwd, check=True)


def download(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def patch_paths(patch):
    return re.findall(r"^--- a/(.+)$", patch.read_text(encoding="utf-8"), re.MULTILINE)


def apply_patches(cef, chromium, posix):
    for tree, directory in (("cef", cef), ("chromium", chromium)):
        names = PATCHES[tree] + ([POSIX_PATCH] if tree == "chromium" and posix else [])
        for name in names:
            patch = ROOT / "patches" / name
            run("git", "-C", str(directory), "apply", "--check", str(patch))
            run("git", "-C", str(directory), "apply", str(patch))


def verify_patch_identity():
    for name, expected in PATCH_BLOBS.items():
        if git_blob((ROOT / "patches" / name).read_bytes()) != expected:
            raise ValueError(f"Patch differs from recorded blob: {name}")


def check_patches():
    # This checks upstream files only; CEF's own Chromium patches may alter them.
    verify_patch_identity()
    with tempfile.TemporaryDirectory(prefix="cef-patch-check-") as temp:
        trees = {name: Path(temp) / name for name in PATCHES}
        for tree, directory in trees.items():
            directory.mkdir()
            names = PATCHES[tree] + ([POSIX_PATCH] if tree == "chromium" else [])
            paths = set()
            for name in names:
                paths.update(patch_paths(ROOT / "patches" / name))
            for path in sorted(paths):
                if tree == "cef":
                    url = f"https://raw.githubusercontent.com/chromiumembedded/cef/{PINS['cef_commit']}/{path}"
                else:
                    url = f"https://raw.githubusercontent.com/chromium/chromium/{PINS['chromium_tag']}/{path}"
                target = directory / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(download(url))
        apply_patches(trees["cef"], trees["chromium"], True)
    print("All patches apply in order to the pinned upstream files.")


def git_blob(data):
    return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()


def build(directory, arch):
    verify_patch_identity()
    if directory.exists():
        raise ValueError(f"Build directory must not already exist: {directory}")
    if shutil.disk_usage(directory.parent).free < 200 * 1024**3:
        raise ValueError("At least 200 GiB free disk is required")
    if physical_memory() < 16 * 1024**3:
        raise ValueError("At least 16 GiB physical memory is required")
    directory.mkdir()
    url = ("https://raw.githubusercontent.com/chromiumembedded/cef/"
           f"{PINS['cef_commit']}/tools/automate/automate-git.py")
    script = download(url)
    if git_blob(script) != PINS["automate_git_blob"]:
        raise ValueError("Pinned automate-git.py blob does not match")
    automate = directory / "automate-git.py"
    automate.write_bytes(script)
    os.environ.setdefault("CEF_ARCHIVE_FORMAT", "tar.bz2")
    if sys.platform.startswith("linux"):
        gn = "is_official_build=true use_sysroot=true symbol_level=1 is_cfi=false"
        if arch == "arm64":
            gn += " use_thin_lto=false chrome_pgo_phase=0"
            os.environ.setdefault("CEF_INSTALL_SYSROOT", "arm64")
        os.environ.setdefault("GN_DEFINES", gn)
    else:
        gn = "is_official_build=true"
        if sys.platform == "win32" and arch == "arm64":
            gn += " use_thin_lto=false chrome_pgo_phase=0"
            os.environ.setdefault("CEF_ENABLE_ARM64", "1")
        os.environ.setdefault("GN_DEFINES", gn)
    common = [sys.executable, str(automate), "--download-dir", str(directory),
              "--branch", PINS["cef_branch"], "--checkout", PINS["cef_commit"],
              f"--{arch}-build"]
    if arch == "x64" or sys.platform == "darwin":
        common.append("--with-pgo-profiles")
    run(*common, "--no-build", "--no-distrib")
    cef = directory / "chromium" / "src" / "cef"
    chromium = directory / "chromium" / "src"
    actual_cef = subprocess.check_output(["git", "-C", str(cef), "rev-parse", "HEAD"], text=True).strip()
    if actual_cef != PINS["cef_commit"]:
        raise ValueError(f"Unexpected CEF checkout: {actual_cef}")
    actual_chromium = subprocess.check_output(["git", "-C", str(chromium), "rev-parse", "HEAD"], text=True).strip()
    expected_chromium = subprocess.check_output(["git", "-C", str(chromium), "rev-parse", f"refs/tags/{PINS['chromium_tag']}^{{commit}}"], text=True).strip()
    if actual_chromium != expected_chromium:
        raise ValueError(f"Unexpected Chromium checkout: {actual_chromium}")
    depot = directory / "depot_tools"
    actual_depot = subprocess.check_output(["git", "-C", str(depot), "rev-parse", "HEAD"], text=True).strip()
    if actual_depot != PINS["depot_tools_commit"]:
        raise ValueError(f"Unexpected depot_tools checkout: {actual_depot}")
    apply_patches(cef, chromium, os.name != "nt")
    run(*common, "--no-update", "--force-build", "--force-distrib",
        "--no-debug-build", "--minimal-distrib-only")
    print("Build finished. Inspect binary_distrib; do not publish without native verification.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check-patches")
    build_parser = sub.add_parser("build")
    build_parser.add_argument("--directory", type=Path, required=True,
                              help="new, dedicated directory (parent must exist)")
    build_parser.add_argument("--arch", choices=("x64", "arm64"), required=True)
    args = parser.parse_args()
    if args.command == "check-patches":
        check_patches()
    else:
        build(args.directory.resolve(), args.arch)


if __name__ == "__main__":
    main()
