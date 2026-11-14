import importlib.util
import os
from pathlib import Path
import shutil
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
                cef.sync(Path(directory), next(t for t, (p, _) in cef.TARGETS.items()
                                               if p == cef.HOST_PLATFORM))
            self.assertEqual(marker.read_text(), "unchanged")

    def test_build_env_selects_single_release_config(self):
        expected = {
            "linux-arm64": {"CEF_INSTALL_SYSROOT": "arm64"},
            "windows-arm64": {"CEF_ENABLE_ARM64": "1", "DEPOT_TOOLS_WIN_TOOLCHAIN": "0"},
            "macos-x64": {"CEF_ENABLE_AMD64": "1"},
        }
        for target, extra in expected.items():
            with self.subTest(target=target), \
                    patch.object(cef, "HOST_PLATFORM", cef.TARGETS[target][0]):
                env = cef.build_env(target)
                self.assertEqual(env["GN_OUT_CONFIGS"], f"Release_GN_{cef.TARGETS[target][1]}")
                self.assertIn("is_official_build=true", env["GN_DEFINES"])
                self.assertIn("use_siso=false", env["GN_DEFINES"])
                self.assertEqual(env.get("CEF_INSTALL_SYSROOT"), extra.get("CEF_INSTALL_SYSROOT"))
                for key, value in extra.items():
                    self.assertEqual(env[key], value)

    def test_build_env_rejects_foreign_host(self):
        with patch.object(cef, "HOST_PLATFORM", "linux"):
            with self.assertRaisesRegex(ValueError, "must be built on windows"):
                cef.build_env("windows-x64")

    @unittest.skipUnless(shutil.which("zstd"), "zstd is required")
    def test_pack_round_trip_preserves_nanosecond_mtimes(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source"
            (source / "out").mkdir(parents=True)
            stamp = 1_700_000_000_123_456_789
            files = {source / "input.cc": os.urandom(4096), source / "out" / "input.o": b"o" * 3000}
            for index, (path, data) in enumerate(files.items()):
                path.write_bytes(data)
                os.utime(path, ns=(stamp + index, stamp + index))
            cef.pack(source, Path(temp) / "parts", part_size=1024)
            parts = sorted((Path(temp) / "parts").iterdir())
            self.assertGreater(len(parts), 1)
            restored = Path(temp) / "restored"
            cef.unpack(Path(temp) / "parts", restored)
            self.assertFalse(any((Path(temp) / "parts").iterdir()))
            for index, (path, data) in enumerate(files.items()):
                copy = restored / path.relative_to(source)
                self.assertEqual(copy.read_bytes(), data)
                if os.name != "nt":
                    self.assertEqual(copy.stat().st_mtime_ns, stamp + index)

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
