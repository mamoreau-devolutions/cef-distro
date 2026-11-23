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


def out_dir(tree, target):
    arch = target.split("-")[1]
    return os.path.join(tree, "chromium", "src", "out", f"Release_GN_{arch}")


def ninja_binary(tree, target):
    name = "ninja.exe" if target.startswith("windows") else "ninja"
    return os.path.join(tree, "chromium", "src", "third_party", "ninja", name)


def ninja(tree, target, explain, targets=None):
    platform = target.split("-")[0]
    if targets is None:
        targets = {
            "linux": ["cefsimple", "chrome_sandbox"],
            "windows": ["cefclient", "bootstrap", "bootstrapc"],
            "macos": ["cefclient"],
        }[platform]
    command = [ninja_binary(tree, target), "-C", out_dir(tree, target), "-n"]
    if explain:
        command += ["-d", "explain"]
    process = subprocess.run(command + targets, capture_output=True, text=True, errors="replace")
    if process.returncode != 0:
        sys.stderr.write(process.stdout[-4000:] + process.stderr[-4000:])
        raise SystemExit(f"ninja -n failed: {process.returncode}")
    steps = [match.group(1) for match in map(STEP.match, process.stdout.splitlines()) if match]
    return steps, process.stdout.splitlines() + process.stderr.splitlines()


MOJOM_TOOLS = ("mojom_bindings_generator.py", "mojom_parser.py")
GENERATION_KINDS = {"ACTION", "STAMP", "COPY"}


def mojom_outputs(out):
    """First output of every build edge whose rule runs a mojom tool."""
    outputs = []
    for directory, _, names in os.walk(out):
        for name in names:
            if not name.endswith(".ninja"):
                continue
            rules, rule = set(), None
            with open(os.path.join(directory, name), encoding="utf-8", errors="replace") as stream:
                lines = stream.read().splitlines()
            for line in lines:
                if line.startswith("rule "):
                    rule = line[5:].strip()
                elif rule and line.startswith("  command = ") and any(tool in line for tool in MOJOM_TOOLS):
                    rules.add(rule)
                elif not line.startswith("  "):
                    rule = None
            for line in lines:
                if not line.startswith("build "):
                    continue
                # Outputs end at the first unescaped colon; "$ " and "$:" are escapes.
                head = re.split(r"(?<!\$):", line[6:], maxsplit=1)
                rule_used = head[1].split(None, 1)[0] if len(head) == 2 and head[1].strip() else None
                if rule_used in rules:
                    first = re.split(r"(?<!\$) ", head[0].strip(), maxsplit=1)[0]
                    outputs.append(first.replace("$ ", " ").replace("$:", ":").replace("$$", "$"))
    return outputs


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
    parser.add_argument("phase", choices=["baseline", "revert", "restore", "generate", "count"])
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

    if args.phase == "generate":
        # Running the mojom generators for real lets restat drop every dependent of
        # an output whose content did not change, which a dry run cannot see.
        outputs = mojom_outputs(out_dir(args.tree, args.target))
        batches = [outputs[start:start + 1500] for start in range(0, len(outputs), 1500)]
        planned = collections.Counter()
        for batch in batches:
            steps, _ = ninja(args.tree, args.target, explain=False, targets=batch)
            planned.update(map(kind, steps))
        print(f"Mojom edges: {len(outputs)}; steps to run them: {planned.most_common()}")
        other = {name: count for name, count in planned.items() if name not in GENERATION_KINDS}
        if other:
            raise SystemExit(f"Running the mojom generators would also build {other}")
        for batch in batches:
            command = [ninja_binary(args.tree, args.target), "-C", out_dir(args.tree, args.target), *batch]
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        with open(os.path.join(args.state, "generated.json"), "w", encoding="utf-8") as out:
            json.dump({"mojom_edges": len(outputs), "steps_run": sum(planned.values())}, out)
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
    generated_path = os.path.join(args.state, "generated.json")
    generated = {}
    if os.path.exists(generated_path):
        with open(generated_path, encoding="utf-8") as stream:
            generated = json.load(stream)
    summary = {
        "target": args.target,
        "mojom_salt": os.environ.get("PROBE_SALT", "version"),
        "mojom_steps_run": generated.get("steps_run", 0),
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
