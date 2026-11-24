#!/usr/bin/env python3
"""Move a built CEF tree's checkouts without rebuilding files that did not change.

  revert   Record the content and mtime of every locally modified or added file
           in the Chromium, dependency and CEF checkouts, then revert them, so
           that the checkouts can move to new revisions.
  restore  After the checkouts moved and the patches were applied again, give
           every recorded file whose content is unchanged its old mtime back.

Ninja decides by mtime, so reverting and re-applying a patch would otherwise
rebuild everything that includes a patched file even when its content is the
same as before.
"""

import argparse
import hashlib
import json
import os
import subprocess


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True).stdout


def repositories(tree):
    chromium = os.path.join(tree, "chromium")
    scope = {}
    with open(os.path.join(chromium, ".gclient_entries"), encoding="utf-8") as entries:
        exec(entries.read(), scope)  # gclient writes it as Python.
    repos = [os.path.join(chromium, path) for path in scope["entries"]]
    repos.append(os.path.join(chromium, "src", "cef"))
    return sorted({repo for repo in repos if os.path.isdir(os.path.join(repo, ".git"))})


def sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def changes(repo):
    """Yields (status, path) for modified tracked and unignored untracked files."""
    output = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all")
    fields = output.split(b"\0")
    index = 0
    while index < len(fields):
        entry = fields[index].decode("utf-8", "surrogateescape")
        index += 1
        if not entry:
            continue
        status, path = entry[:2], entry[3:]
        if status[0] in "RC":
            index += 1  # The original path of a rename follows.
        yield status, path


def revert(tree, record):
    files = {}
    for repo in repositories(tree):
        listed = list(changes(repo))
        for status, path in listed:
            full = os.path.join(repo, path)
            if os.path.isfile(full):
                files[full] = {"sha": sha(full), "mtime_ns": os.stat(full).st_mtime_ns}
        tracked = [path for status, path in listed if status != "??"]
        untracked = [path for status, path in listed if status == "??"]
        for start in range(0, len(tracked), 200):
            git(repo, "checkout", "--", *tracked[start:start + 200])
        for path in untracked:
            full = os.path.join(repo, path)
            if os.path.isfile(full) or os.path.islink(full):
                os.remove(full)
        if listed:
            print(f"{os.path.relpath(repo, tree)}: reverted {len(tracked)}, removed {len(untracked)}")
    with open(record, "w", encoding="utf-8") as out:
        json.dump(files, out)
    print(f"Recorded {len(files)} locally modified files")


def restore(record):
    with open(record, encoding="utf-8") as stream:
        files = json.load(stream)
    restored = changed = gone = 0
    for path, before in files.items():
        if not os.path.isfile(path):
            gone += 1
        elif sha(path) == before["sha"]:
            os.utime(path, ns=(before["mtime_ns"], before["mtime_ns"]))
            restored += 1
        else:
            changed += 1
    print(f"Recorded files: {restored} unchanged (old mtime restored), {changed} changed, {gone} gone")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=["revert", "restore"])
    parser.add_argument("--tree", help="Build tree holding chromium/ (revert only)")
    parser.add_argument("--record", required=True, help="JSON file recording the reverted files")
    args = parser.parse_args()
    if args.phase == "revert":
        if not args.tree:
            parser.error("revert needs --tree")
        revert(args.tree, args.record)
    else:
        restore(args.record)


if __name__ == "__main__":
    main()
