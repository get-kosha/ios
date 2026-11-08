#!/usr/bin/env python3
"""Check release authentication and cleanup with fake build/signing commands."""
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.runner = self.root / "runner"
        self.runner.mkdir()
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        for name in ("release.sh", "ci-release.sh"):
            shutil.copy2(Path(__file__).parent / name, self.scripts / name)
        self.log = self.root / "commands.jsonl"
        stub = self.bin / "stub"
        stub.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
record = {"name": name, "args": args}
if name == "xcodebuild" and "-authenticationKeyPath" in args:
    key = pathlib.Path(args[args.index("-authenticationKeyPath") + 1])
    record["key_exists"] = key.is_file() and bool(key.read_text())
    record["key_mode"] = key.stat().st_mode & 0o777
with open(os.environ["TEST_COMMAND_LOG"], "a") as log:
    log.write(json.dumps(record) + "\\n")
if name == "git":
    print("43")
if name == "xcodebuild" and "archive" in args and os.environ.get("TEST_FAIL_ARCHIVE"):
    sys.exit(73)
''')
        stub.chmod(0o755)
        for name in ("git", "xcodegen", "xcodebuild", "security"):
            (self.bin / name).symlink_to(stub)
        self.env = {
            k: v for k, v in os.environ.items()
            if not k.startswith(("ASC_", "APPLE_", "TEST_"))
        }
        self.env.update(PATH=f"{self.bin}:{os.environ['PATH']}", RUNNER_TEMP=str(self.runner),
                        TEST_COMMAND_LOG=str(self.log))

    def invoke(self, name, **env):
        return subprocess.run(["/bin/zsh", str(self.scripts / name)],
                              env=self.env | env, text=True, capture_output=True)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def credentials(self):
        return dict(APPLE_CERTIFICATE_BASE64=base64.b64encode(b"test-certificate").decode(),
                    APPLE_CERTIFICATE_PASSWORD="test-password", ASC_KEY_ID="test-key",
                    ASC_ISSUER_ID="test-issuer", ASC_PRIVATE_KEY="test-private-key\n")

    def test_local_upload_keeps_xcode_account_signing(self):
        result = self.invoke("release.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [c for c in self.commands() if c["name"] == "xcodebuild"]
        self.assertEqual(len(builds), 2)
        self.assertIn("CURRENT_PROJECT_VERSION=43", builds[0]["args"])
        self.assertNotIn("-authenticationKeyPath", builds[0]["args"])
        self.assertIn("-exportArchive", builds[1]["args"])

    def test_ci_authenticates_both_build_steps_and_removes_signing_files(self):
        result = self.invoke("ci-release.sh", **self.credentials())
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [c for c in self.commands() if c["name"] == "xcodebuild"]
        self.assertEqual(len(builds), 2)
        for build in builds:
            self.assertTrue(build["key_exists"])
            self.assertEqual(build["key_mode"], 0o600)
            self.assertIn("test-key", build["args"])
            self.assertIn("test-issuer", build["args"])
        self.assertEqual(self.commands()[-1]["args"][0], "delete-keychain")
        self.assertEqual(list(self.runner.iterdir()), [])

    def test_failed_archive_never_uploads_and_still_cleans_up(self):
        result = self.invoke("ci-release.sh", **self.credentials(), TEST_FAIL_ARCHIVE="1")
        self.assertEqual(result.returncode, 73)
        builds = [c for c in self.commands() if c["name"] == "xcodebuild"]
        self.assertEqual(len(builds), 1)
        self.assertEqual(self.commands()[-1]["args"][0], "delete-keychain")
        self.assertEqual(list(self.runner.iterdir()), [])

    def test_partial_api_credentials_fail_before_building(self):
        result = self.invoke("release.sh", ASC_KEY_ID="test-key")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])
        self.assertNotIn("test-key", result.stderr)

    def test_missing_ci_secret_fails_before_installing_signing_assets(self):
        credentials = self.credentials()
        del credentials["ASC_PRIVATE_KEY"]
        result = self.invoke("ci-release.sh", **credentials)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])
        self.assertEqual(list(self.runner.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
