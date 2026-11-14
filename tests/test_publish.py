import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import cef
import publish
from release import sha256


def candidate(root, target, pins=None):
    directory = root / f"candidate-{target}"
    directory.mkdir(parents=True)
    archive = directory / f"cef_binary_{target}_minimal.tar.bz2"
    archive.write_bytes(target.encode())
    platform, arch = target.split("-")
    manifest = {"platform": platform, "architecture": arch, "archive": archive.name,
                "sha256": sha256(archive), "pins": pins or cef.PINS,
                "patch_git_blobs": cef.PATCH_BLOBS, "repository_commit": "a" * 40}
    (directory / "manifest.json").write_text(json.dumps(manifest))
    return archive


class PublishTests(unittest.TestCase):
    def test_assembles_targets_from_several_runs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            first = candidate(root / "run1", "linux-x64")
            candidate(root / "run1", "macos-arm64").write_bytes(b"truncated")
            second = candidate(root / "run2", "macos-arm64")
            with self.assertRaisesRegex(ValueError, "checksum"):
                publish.assemble([root / "run1", root / "run2"], ["linux-x64", "macos-arm64"],
                                 root / "bad")
            publish.assemble([root / "run2", root / "run1"], ["linux-x64", "macos-arm64"],
                             root / "out")
            self.assertEqual((root / "out" / second.name).read_bytes(), b"macos-arm64")
            self.assertEqual((root / "out" / "SHA256SUMS").read_text().splitlines(),
                             [f"{sha256(first)}  {first.name}", f"{sha256(second)}  {second.name}"])

    def test_rejects_candidates_with_other_pins(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            candidate(root, "windows-x64", pins={**cef.PINS, "cef_commit": "0" * 40})
            with self.assertRaisesRegex(ValueError, "different pins"):
                publish.assemble([root], ["windows-x64"], root / "out")


if __name__ == "__main__":
    unittest.main()
