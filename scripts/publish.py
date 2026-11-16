#!/usr/bin/env python3
"""Assemble verified per-target candidates into one release directory.

Candidates may come from several workflow runs (for example after resuming one
target). Each must carry this checkout's pins and patch blobs, so a release never
mixes builds of different upstream revisions or patch sets.
"""
import argparse
import json
from pathlib import Path
import shutil

import cef
from release import sha256


def find(sources, target):
    for source in sources:
        candidate = source / f"candidate-{target}"
        if (candidate / "manifest.json").is_file():
            return candidate
    raise FileNotFoundError(f"No candidate for {target} in {', '.join(map(str, sources))}")


def verify(candidate, target):
    manifest = json.loads((candidate / "manifest.json").read_text(encoding="utf-8"))
    platform, arch = target.split("-")
    if (manifest["platform"], manifest["architecture"]) != (platform, arch):
        raise ValueError(f"{candidate}: manifest is for {manifest['platform']}-{manifest['architecture']}")
    if manifest["pins"] != cef.PINS or manifest["patch_git_blobs"] != cef.PATCH_BLOBS:
        raise ValueError(f"{candidate}: built from different pins or patches than this checkout")
    archive = candidate / manifest["archive"]
    if sha256(archive) != manifest["sha256"]:
        raise ValueError(f"{archive}: checksum does not match manifest")
    return manifest, archive


def assemble(sources, targets, output, smoke_proofs=None):
    cef.verify_patch_identity()
    output.mkdir(parents=True)
    sums = []
    for target in targets:
        candidate = find(sources, target)
        manifest, archive = verify(candidate, target)
        if smoke_proofs is not None:
            proof = smoke_proofs / f"native-smoke-{target}" / "archive.sha256"
            if proof.read_text(encoding="ascii").strip() != manifest["sha256"]:
                raise ValueError(f"{target}: native smoke tested a different archive")
        shutil.copyfile(archive, output / archive.name)
        shutil.copyfile(candidate / "manifest.json", output / f"manifest-{target}.json")
        sums.append(f"{manifest['sha256']}  {archive.name}\n")
        print(f"{target}: {archive.name} from {candidate} (commit {manifest['repository_commit']})")
    (output / "SHA256SUMS").write_text("".join(sums), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, action="append", required=True,
                        help="Directory containing candidate-<target> folders; first match wins")
    parser.add_argument("--targets", required=True, help="JSON list of targets")
    parser.add_argument("--smoke-proofs", type=Path,
                        help="Directory containing per-target native smoke checksums")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assemble(args.source, json.loads(args.targets), args.output, args.smoke_proofs)


if __name__ == "__main__":
    main()
