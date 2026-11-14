import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("cef", ROOT / "scripts" / "cef.py")
cef = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cef)


class BuildTests(unittest.TestCase):
    def test_existing_directory_is_never_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "keep"
            marker.write_text("unchanged")
            with self.assertRaisesRegex(ValueError, "must not already exist"):
                cef.build(Path(directory), "x64")
            self.assertEqual(marker.read_text(), "unchanged")

    def test_apply_order_and_posix_gate(self):
        for posix in (False, True):
            with self.subTest(posix=posix), patch.object(cef, "run") as run:
                cef.apply_patches(Path("cef"), Path("chromium"), posix)
                applied = [Path(call.args[-1]).name for call in run.call_args_list
                           if "--check" not in call.args]
                expected = cef.PATCHES["cef"] + cef.PATCHES["chromium"]
                if posix:
                    expected += [cef.POSIX_PATCH]
                self.assertEqual(applied, expected)
                self.assertEqual(run.call_count, len(expected) * 2)

    def test_git_blob_matches_git_object_format(self):
        self.assertEqual(cef.git_blob(b"test\n"), "9daeafb9864cf43055ae93beb0afd6c7d144bfa4")

    def test_patch_identity_rejects_changed_bytes(self):
        with patch.object(cef, "PATCH_BLOBS", {"isolated-clipboard.patch": "0" * 40}):
            with self.assertRaisesRegex(ValueError, "Patch differs"):
                cef.verify_patch_identity()

    def test_compatibility_rejects_changed_chromium_tag(self):
        data = (f"{{'chromium_checkout': 'refs/tags/wrong', "
                f"'depot_tools_checkout': '{cef.PINS['depot_tools_commit']}'}}").encode()
        with patch.object(cef, "download", return_value=data):
            with self.assertRaisesRegex(ValueError, "Chromium tag"):
                cef.verify_compatibility()


if __name__ == "__main__":
    unittest.main()
