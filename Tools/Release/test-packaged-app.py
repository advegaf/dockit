#!/usr/bin/env python3
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("guard", pathlib.Path(__file__).with_name("validate-packaged-app.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class PackagedAppTests(unittest.TestCase):
    def check(self, extra, mode, extension_version="1.0.0"):
        with tempfile.TemporaryDirectory(prefix="dockit-package-guard.") as temporary:
            contents = pathlib.Path(temporary) / "Contents"
            contents.mkdir()
            with (contents / "Info.plist").open("wb") as target:
                plistlib.dump({"CFBundleIdentifier": "com.advegaf.dockit", "CFBundleShortVersionString": "1.0.0", **extra}, target)
            extension_contents = contents / "Extensions" / "DockitFocusExtension.appex" / "Contents"
            extension_contents.mkdir(parents=True)
            with (extension_contents / "Info.plist").open("wb") as target:
                plistlib.dump({"CFBundleShortVersionString": extension_version}, target)
            guard.validate(temporary, mode)

    def test_usable_modes_accept_normal_identity_without_test_environment(self):
        for mode in ("development", "release"):
            self.check({}, mode)

    def test_usable_modes_reject_each_test_environment_even_false(self):
        for mode in ("development", "release"):
            for key in ("DOCKIT_DEMO", "DOCKIT_TEST_HOST", "DOCKIT_DEMO_APPEARANCE"):
                for value in ("1", "0", ""):
                    with self.subTest(mode=mode, key=key, value=value):
                        with self.assertRaisesRegex(ValueError, "test environment"):
                            self.check({"LSEnvironment": {key: value}}, mode)

    def test_usable_modes_reject_preview_id_and_preview_name(self):
        for mode in ("development", "release"):
            for extra in ({"CFBundleIdentifier": "com.advegaf.dockit.finishing-final-preview"},
                          {"CFBundleDisplayName": "dockit preview"}):
                with self.assertRaises(ValueError):
                    self.check(extra, mode)

    def test_preview_allows_isolated_test_identity(self):
        self.check({"CFBundleIdentifier": "com.advegaf.dockit.preview",
                    "LSEnvironment": {"DOCKIT_DEMO": "1", "DOCKIT_TEST_HOST": "1"}}, "preview")

    def test_malformed_environment_rejected(self):
        with self.assertRaises(ValueError):
            self.check({"LSEnvironment": []}, "development")

    def test_usable_modes_reject_wrong_app_version(self):
        for mode in ("development", "release"):
            with self.assertRaisesRegex(ValueError, "app version 1.0.0"):
                self.check({"CFBundleShortVersionString": "0.9.0"}, mode)

    def test_usable_modes_reject_wrong_extension_version(self):
        for mode in ("development", "release"):
            with self.assertRaisesRegex(ValueError, "extension version 1.0.0"):
                self.check({}, mode, extension_version="0.9.0")


if __name__ == "__main__":
    unittest.main()
