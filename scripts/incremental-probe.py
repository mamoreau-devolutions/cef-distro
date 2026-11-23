#!/usr/bin/env python3
"""Measure how much of a saved build tree an in-place version update rebuilds.

Run in three phases against a restored tree (CEF_TREE layout from the stage
action):

  baseline  Record what ninja still has to build in the tree as saved.
  revert    Record the content and mtime of every locally modified file in the
            Chromium, dependency and CEF checkouts, then revert them, so that
            the checkouts can move to new revisions.
  restore   After the checkouts moved and the patches were applied again, give
            every recorded file whose content is unchanged its old mtime back.
  count     Record what ninja has to build now, why, and summarize.

Ninja decides by mtime, so reverting and re-applying a patch would otherwise
rebuild everything that includes a patched file even when its content is the
same as before.
"""

import argparse
import collections
import hashlib
import json
import os
import re
import subprocess
import sys

STEP = re.compile(r"^\[\d+/\d+\] (.*)$")
OLDER = re.compile(r"^ninja explain: (?:output |restat of output )?(\S+) older than most recent input (\S+)")
COMMAND = re.compile(r"^ninja explain: command line changed for (\S+)")
MISSING = re.compile(r"^ninja explain: output (\S+) doesn't exist")


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


def ninja(tree, target, explain):
    platform, arch = target.split("-")
    src = os.path.join(tree, "chromium", "src")
    binary = os.path.join(src, "third_party", "ninja", "ninja.exe" if platform == "windows" else "ninja")
    targets = {
        "linux": ["cefsimple", "chrome_sandbox"],
        "windows": ["cefclient", "bootstrap", "bootstrapc"],
        "macos": ["cefclient"],
    }[platform]
    command = [binary, "-C", os.path.join(src, "out", f"Release_GN_{arch}"), "-n"]
    if explain:
        command += ["-d", "explain"]
    process = subprocess.run(command + targets, capture_output=True, text=True, errors="replace")
    if process.returncode != 0:
        sys.stderr.write(process.stdout[-4000:] + process.stderr[-4000:])
        raise SystemExit(f"ninja -n failed: {process.returncode}")
    steps = [match.group(1) for match in map(STEP.match, process.stdout.splitlines()) if match]
    return steps, process.stdout.splitlines() + process.stderr.splitlines()


def kind(description):
    word = description.split(" ", 1)[0]
    return word if word.isupper() else "OTHER"


def toolchain(description):
    parts = description.split(" ", 1)
    path = parts[1] if len(parts) > 1 else ""
    match = re.search(r"\(//build/toolchain/[^:]+:([^)]+)\)", path)
    if match:
        return match.group(1)
    first = path.split("/", 1)[0]
    return first if first.startswith("clang_") or first.startswith("win_clang_") else "target"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=["baseline", "revert", "restore", "count"])
    parser.add_argument("--tree", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--state", required=True, help="Directory for the probe's records")
    args = parser.parse_args()
    os.makedirs(args.state, exist_ok=True)
    record = os.path.join(args.state, "modified.json")

    if args.phase == "baseline":
        steps, _ = ninja(args.tree, args.target, explain=False)
        with open(os.path.join(args.state, "baseline.json"), "w", encoding="utf-8") as out:
            json.dump(steps, out)
        print(f"Steps pending in the saved tree: {len(steps)}")
        return

    if args.phase == "revert":
        files = {}
        for repo in repositories(args.tree):
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
                print(f"{os.path.relpath(repo, args.tree)}: reverted {len(tracked)}, removed {len(untracked)}")
        with open(record, "w", encoding="utf-8") as out:
            json.dump(files, out)
        print(f"Recorded {len(files)} locally modified files")
        return

    if args.phase == "restore":
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
        return

    with open(os.path.join(args.state, "baseline.json"), encoding="utf-8") as stream:
        baseline = set(json.load(stream))
    steps, lines = ninja(args.tree, args.target, explain=True)
    with open(os.path.join(args.state, "explain.txt"), "w", encoding="utf-8") as out:
        out.write("\n".join(lines))
    new = [step for step in steps if step not in baseline]
    causes = collections.Counter()
    reasons = collections.Counter()
    for line in lines:
        if match := OLDER.match(line):
            causes[match.group(2)] += 1
            reasons["older than an input"] += 1
        elif COMMAND.match(line):
            reasons["command line changed"] += 1
        elif MISSING.match(line):
            reasons["output missing"] += 1
    summary = {
        "target": args.target,
        "pending_before_update": len(baseline),
        "pending_after_update": len(steps),
        "added_by_update": len(new),
        "added_by_kind": collections.Counter(map(kind, new)).most_common(),
        "added_by_toolchain": collections.Counter(map(toolchain, new)).most_common(),
        "explain_reasons": reasons.most_common(),
        "top_direct_causes": causes.most_common(60),
    }
    with open(os.path.join(args.state, "summary.json"), "w", encoding="utf-8") as out:
        json.dump(summary, out, indent=1)
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
