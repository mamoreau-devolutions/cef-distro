import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import cef
import release


class ReleaseTests(unittest.TestCase):
    def test_prepares_original_archive_and_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            directory = root / "build" / "chromium" / "src" / "cef" / "binary_distrib"
            directory.mkdir(parents=True)
            name = f"cef_binary_{cef.PINS['cef_version']}_linux64_minimal.tar.bz2"
            archive = directory / name
            with tarfile.open(archive, "w:bz2") as tar:
                info = tarfile.TarInfo(f"{name[:-8]}/Release/libcef.so")
                info.size = 3
                tar.addfile(info, io.BytesIO(b"lib"))
            output = root / "output"
            symbols = "\n".join(release.EXPORTS)
            with patch.object(release.subprocess, "check_output", return_value=symbols):
                release.prepare(root / "build", output, "linux", "x64", "a" * 40)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual((output / name).read_bytes(), archive.read_bytes())
            self.assertEqual(manifest["sha256"], release.sha256(archive))
            self.assertEqual(manifest["repository_commit"], "a" * 40)
            self.assertEqual(manifest["patch_git_blobs"], cef.PATCH_BLOBS)
            self.assertEqual((output / "SHA256SUMS").read_text().strip(),
                             f"{manifest['sha256']}  {name}")

    def test_rejects_missing_patched_exports(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "cef_binary_test_linux64_minimal.tar.bz2"
            with tarfile.open(archive, "w:bz2") as tar:
                info = tarfile.TarInfo(f"{archive.name[:-8]}/Release/libcef.so")
                info.size = 3
                tar.addfile(info, io.BytesIO(b"lib"))
            with patch.object(release.subprocess, "check_output", return_value=""):
                with self.assertRaisesRegex(ValueError, "Missing patched exports"):
                    release.verify_exports(archive, "linux")

    def test_rejects_unexpected_archive_root(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "cef_binary_test_linux64_minimal.tar.bz2"
            with tarfile.open(archive, "w:bz2") as tar:
                info = tarfile.TarInfo("other/Release/libcef.so")
                info.size = 3
                tar.addfile(info, io.BytesIO(b"lib"))
            with self.assertRaisesRegex(ValueError, "unexpected top-level"):
                release.verify_exports(archive, "linux")


if __name__ == "__main__":
    unittest.main()
