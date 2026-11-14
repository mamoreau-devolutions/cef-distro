#!/usr/bin/env python3
"""Verify patches and build patched CEF in resumable stages."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
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


def run(*args, cwd=None, env=None):
    print("+", *map(str, args), flush=True)
    subprocess.run(args, cwd=cwd, env=env, check=True)


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


def verify_compatibility():
    url = ("https://raw.githubusercontent.com/chromiumembedded/cef/"
           f"{PINS['cef_commit']}/CHROMIUM_BUILD_COMPATIBILITY.txt")
    compatibility = ast.literal_eval(download(url).decode("utf-8"))
    if compatibility["chromium_checkout"] != f"refs/tags/{PINS['chromium_tag']}":
        raise ValueError("Chromium tag does not match CEF compatibility")
    if compatibility["depot_tools_checkout"] != PINS["depot_tools_commit"]:
        raise ValueError("depot_tools revision does not match CEF compatibility")


def check_patches():
    # This checks upstream files only; CEF's own Chromium patches may alter them.
    verify_patch_identity()
    verify_compatibility()
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



TARGETS = {
    "linux-x64": ("linux", "x64"), "linux-arm64": ("linux", "arm64"),
    "windows-x64": ("windows", "x64"), "windows-arm64": ("windows", "arm64"),
    "macos-x64": ("macos", "x64"), "macos-arm64": ("macos", "arm64"),
}
HOST_PLATFORM = {"win32": "windows", "darwin": "macos"}.get(sys.platform, "linux")
# Official configuration without ThinLTO, PGO, CFI, or symbols keeps the link
# within hosted-runner memory and time limits. No codec or branding flags.
GN_COMMON = ("is_official_build=true", "use_thin_lto=false", "chrome_pgo_phase=0",
             "symbol_level=0", "use_siso=false")


def build_env(target):
    platform, arch = TARGETS[target]
    if platform != HOST_PLATFORM:
        raise ValueError(f"{target} must be built on {platform}, not {HOST_PLATFORM}")
    gn = list(GN_COMMON)
    env = {"GN_OUT_CONFIGS": f"Release_GN_{arch}", "CEF_ARCHIVE_FORMAT": "tar.bz2",
           "DEPOT_TOOLS_UPDATE": "0"}
    if platform == "linux":
        gn += ["use_sysroot=true", "is_cfi=false"]
        if arch == "arm64":
            env["CEF_INSTALL_SYSROOT"] = "arm64"
    elif platform == "windows":
        env["DEPOT_TOOLS_WIN_TOOLCHAIN"] = "0"
    if platform != "linux":
        env["CEF_ENABLE_ARM64" if arch == "arm64" else "CEF_ENABLE_AMD64"] = "1"
    env["GN_DEFINES"] = " ".join(gn)
    return env


def ninja_targets(target):
    platform = TARGETS[target][0]
    return ["cefclient"] + {"linux": ["chrome_sandbox"],
                            "windows": ["bootstrap", "bootstrapc"]}.get(platform, [])


def layout(directory):
    src = directory / "chromium" / "src"
    return {"src": src, "cef": src / "cef", "depot_tools": directory / "depot_tools"}


def environment(directory, target):
    env = dict(os.environ)
    env.update(build_env(target))
    env["PATH"] = str(layout(directory)["depot_tools"]) + os.pathsep + env["PATH"]
    return env


def head(path):
    return subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()


def verify_checkouts(directory):
    paths = layout(directory)
    for name, path, expected in (("CEF", paths["cef"], PINS["cef_commit"]),
                                 ("Chromium", paths["src"], PINS["chromium_commit"]),
                                 ("depot_tools", paths["depot_tools"], PINS["depot_tools_commit"])):
        actual = head(path)
        if actual != expected:
            raise ValueError(f"Unexpected {name} checkout: {actual}")


def sync(directory, target):
    """Fetch pinned sources, apply patches, and generate the build directory."""
    verify_patch_identity()
    if directory.exists():
        raise ValueError(f"Build directory must not already exist: {directory}")
    verify_compatibility()
    directory.mkdir(parents=True)
    script = download("https://raw.githubusercontent.com/chromiumembedded/cef/"
                      f"{PINS['cef_commit']}/tools/automate/automate-git.py")
    if git_blob(script) != PINS["automate_git_blob"]:
        raise ValueError("Pinned automate-git.py blob does not match")
    automate = directory / "automate-git.py"
    automate.write_bytes(script)
    arch = TARGETS[target][1]
    env = environment(directory, target)
    # Bootstrap depot_tools at its pinned revision; automate then never updates it.
    depot_tools = layout(directory)["depot_tools"]
    run("git", "clone", "--quiet", "https://chromium.googlesource.com/chromium/tools/depot_tools.git",
        str(depot_tools))
    run("git", "-C", str(depot_tools), "checkout", "--quiet", PINS["depot_tools_commit"])
    if os.name == "nt":
        run("cmd", "/c", str(depot_tools / "bootstrap" / "win_tools.bat"), cwd=depot_tools, env=env)
    else:
        run("bash", str(depot_tools / "ensure_bootstrap"), cwd=depot_tools, env=env)
    run(sys.executable, str(automate), "--download-dir", str(directory),
        "--branch", PINS["cef_branch"], "--checkout", PINS["cef_commit"],
        "--no-depot-tools-update", "--no-chromium-history", f"--{arch}-build",
        "--no-build", "--no-distrib", env=env)
    verify_checkouts(directory)
    paths = layout(directory)
    apply_patches(paths["cef"], paths["src"], TARGETS[target][0] != "windows")
    # Runs CEF's own patcher after ours, then gn gen for the single output directory.
    run(sys.executable, "tools/gclient_hook.py", cwd=paths["cef"], env=env)


def ninja_path(directory):
    name = "ninja.exe" if os.name == "nt" else "ninja"
    return layout(directory)["src"] / "third_party" / "ninja" / name


def interrupt(process):
    """Ask ninja to stop gracefully; ninja records completed edges and drops partial ones."""
    try:
        if os.name == "nt":
            process.send_signal(signal.CTRL_BREAK_EVENT)
        else:
            os.killpg(process.pid, signal.SIGINT)
        process.wait(timeout=300)
    except (OSError, subprocess.TimeoutExpired):
        if os.name == "nt":
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(process.pid)], check=False)
        else:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def build(directory, target, deadline):
    """Run ninja until done or until the deadline; return whether all targets are built."""
    arch = TARGETS[target][1]
    command = [str(ninja_path(directory)), "-C", f"out/Release_GN_{arch}", *ninja_targets(target)]
    print("+", *command, flush=True)
    options = ({"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt"
               else {"start_new_session": True})
    process = subprocess.Popen(command, cwd=layout(directory)["src"],
                               env=environment(directory, target), **options)
    try:
        process.wait(timeout=max(0, deadline - time.time()))
    except subprocess.TimeoutExpired:
        print("Deadline reached; interrupting ninja to resume in the next stage.", flush=True)
        interrupt(process)
        return False
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, command)
    return True


def distrib(directory, target):
    platform, arch = TARGETS[target]
    paths = layout(directory)
    args = [sys.executable, "make_distrib.py", f"--output-dir={paths['cef'] / 'binary_distrib'}",
            "--ninja-build", f"--{arch}-build", "--minimal", "--no-docs", "--allow-partial"]
    if platform != "linux":
        args.append("--no-symbols")
    run(*args, cwd=paths["cef"] / "tools", env=environment(directory, target))


def tar_command(mode, directory):
    if mode == "create":
        # POSIX/pax headers keep sub-second mtimes, which ninja uses to resume.
        fmt = ["--format=posix"] if sys.platform.startswith("linux") else ["--format", "pax"]
        return ["tar", *fmt, "-cf", "-", "-C", str(directory), "."]
    return ["tar", "-xf", "-", "-C", str(directory)]


# Windows' bundled bsdtar crashes on Chromium trees, so Windows streams with tarfile.
# Exact mtimes travel in pax headers because tarfile's float mtimes lose precision.
DIRECTORY_LINK = "CEF.directory_link"


def write_tree(directory, stream):
    with tarfile.open(fileobj=stream, mode="w|", format=tarfile.PAX_FORMAT) as archive:
        pending = [directory]
        while pending:
            folder = pending.pop()
            with os.scandir(folder) as entries:
                for entry in sorted(entries, key=lambda item: item.name):
                    path = Path(entry.path)
                    name = path.relative_to(directory).as_posix()
                    link = entry.is_symlink() or os.path.isjunction(path)
                    info = archive.gettarinfo(str(path), name)
                    if link:
                        info.type, info.linkname, info.size = tarfile.SYMTYPE, os.readlink(path), 0
                    mtime = entry.stat(follow_symlinks=False).st_mtime_ns
                    info.mtime = mtime // 10**9
                    info.pax_headers = {"mtime": f"{mtime // 10**9}.{mtime % 10**9:09d}"}
                    if link and path.is_dir():
                        info.pax_headers[DIRECTORY_LINK] = "1"
                    if info.isreg():
                        with path.open("rb") as data:
                            archive.addfile(info, data)
                    else:
                        archive.addfile(info)
                    if info.isdir():
                        pending.append(path)


def read_tree(stream, directory):
    times = []
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for member in archive:
            target = directory / member.name
            if member.issym():
                target.parent.mkdir(parents=True, exist_ok=True)
                os.symlink(member.linkname, target,
                           target_is_directory=member.pax_headers.get(DIRECTORY_LINK) == "1")
            else:
                archive.extract(member, directory, set_attrs=not member.isdir(),
                                filter="fully_trusted")
            seconds, _, fraction = member.pax_headers.get("mtime", str(int(member.mtime))).partition(".")
            times.append((target, int(seconds) * 10**9 + int(fraction.ljust(9, "0")[:9] or 0)))
    # Children first, so restoring a file does not disturb its directory's mtime.
    for target, mtime in reversed(times):
        if os.name == "nt" and target.is_symlink():
            continue  # Windows cannot set a link's own times without following it.
        os.utime(target, ns=(mtime, mtime), follow_symlinks=os.name == "nt")


def zstd():
    return shutil.which("zstd") or r"C:\tools\zstd\zstd.exe"


def split(stream, output, part_size):
    index, written, part = 0, 0, None
    while chunk := stream.read(8 * 1024 * 1024):
        while chunk:
            if part is None or written >= part_size:
                if part:
                    part.close()
                part = (output / f"tree.tar.zst.{index:04d}").open("wb")
                index, written = index + 1, 0
            take = chunk[:part_size - written]
            part.write(take)
            written += len(take)
            chunk = chunk[len(take):]
    if part:
        part.close()
    return index


def pack(directory, output, part_size):
    output.mkdir(parents=True)
    tar = None if os.name == "nt" else subprocess.Popen(tar_command("create", directory),
                                                         stdout=subprocess.PIPE)
    compress = subprocess.Popen([zstd(), "-q", "-T0", "-3", "-c"],
                                stdin=tar.stdout if tar else subprocess.PIPE, stdout=subprocess.PIPE)
    parts = []
    splitter = threading.Thread(target=lambda: parts.append(split(compress.stdout, output, part_size)))
    splitter.start()
    try:
        if tar:
            tar.stdout.close()
        else:
            write_tree(directory, compress.stdin)
    finally:
        if not tar:
            compress.stdin.close()
        splitter.join()
    codes = (tar.wait() if tar else 0, compress.wait())
    compress.stdout.close()
    if any(codes) or not parts:
        raise RuntimeError(f"Failed to pack the build tree (tar={codes[0]}, zstd={codes[1]})")
    print(f"Packed {directory} into {parts[0]} parts", flush=True)


def unpack(parts, directory):
    files = sorted(parts.glob("tree.tar.zst.*"))
    if not files:
        raise FileNotFoundError(f"No tree parts in {parts}")
    directory.mkdir(parents=True)
    tar = None if os.name == "nt" else subprocess.Popen(tar_command("extract", directory),
                                                         stdin=subprocess.PIPE)
    decompress = subprocess.Popen([zstd(), "-q", "-d", "-c"], stdin=subprocess.PIPE,
                                  stdout=tar.stdin if tar else subprocess.PIPE)
    if tar:
        tar.stdin.close()
        reader = None
    else:
        errors = []

        def extract():
            try:
                read_tree(decompress.stdout, directory)
            except BaseException as error:
                errors.append(error)
                decompress.stdout.close()

        reader = threading.Thread(target=extract)
        reader.start()
    try:
        for path in files:
            with path.open("rb") as stream:
                shutil.copyfileobj(stream, decompress.stdin, 8 * 1024 * 1024)
            path.unlink()
    except BrokenPipeError:
        if not reader:
            raise
    finally:
        decompress.stdin.close()
        if reader:
            reader.join()
    if reader and errors:
        raise errors[0]
    codes = (decompress.wait(), tar.wait() if tar else 0)
    if decompress.stdout:
        decompress.stdout.close()
    if any(codes):
        raise RuntimeError(f"Failed to unpack the build tree (zstd={codes[0]}, tar={codes[1]})")


def write_output(name, value):
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            stream.write(f"{name}={value}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check-patches")
    for name in ("sync", "build", "distrib"):
        command = sub.add_parser(name)
        command.add_argument("--directory", type=Path, required=True)
        command.add_argument("--target", choices=TARGETS, required=True)
        if name == "build":
            command.add_argument("--deadline", type=float, required=True,
                                 help="Unix time at which to stop ninja gracefully")
    command = sub.add_parser("pack")
    command.add_argument("--directory", type=Path, required=True)
    command.add_argument("--output", type=Path, required=True)
    command.add_argument("--part-size", type=int, default=2 * 1024**3)
    command = sub.add_parser("unpack")
    command.add_argument("--parts", type=Path, required=True)
    command.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "check-patches":
        check_patches()
    elif args.command == "sync":
        sync(args.directory.resolve(), args.target)
    elif args.command == "build":
        complete = build(args.directory.resolve(), args.target, args.deadline)
        write_output("complete", str(complete).lower())
        print("Build complete." if complete else "Build incomplete; resume required.")
    elif args.command == "distrib":
        distrib(args.directory.resolve(), args.target)
    elif args.command == "pack":
        pack(args.directory.resolve(), args.output.resolve(), args.part_size)
    else:
        unpack(args.parts.resolve(), args.directory.resolve())


if __name__ == "__main__":
    main()
