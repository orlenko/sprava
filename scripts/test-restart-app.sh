#!/bin/sh
# Exercises the updater in a throwaway checkout; never launches or stops real apps.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd -P)
python3 - "$repo" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(sys.argv[1]) / "scripts/restart-app.sh"


class RestartAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sprava-restart-tests.")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "checkout with spaces"
        scripts = self.repo / "scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(SOURCE, scripts / "restart-app.sh")
        builder = scripts / "build-app.sh"
        builder.write_text('''#!/bin/sh
set -eu
echo "build $*" >> "$TEST_LOG"
[ "${TEST_BUILD_FAIL:-0}" = 0 ] || exit 1
mkdir -p "$SPRAVA_APP_BUNDLE"
echo new > "$SPRAVA_APP_BUNDLE/version"
''')
        builder.chmod(0o755)
        self.apps = self.root / "Applications with spaces"
        self.apps.mkdir()
        self.app = self.apps / "Sprava.app"
        self.log = self.root / "events"
        self.log.touch()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = self.bin / "fake"
        fake.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_LOG"], "a") as log:
    log.write(name + " " + " ".join(args) + "\\n")
if name == "launchctl":
    if args[0] == "print":
        if os.environ.get("TEST_JOBS") != "1":
            sys.exit(1)
        app = os.environ.get("TEST_JOB_APP", os.environ["SPRAVA_INSTALL_DIR"] + "/Sprava.app")
        if os.environ.get("TEST_JOB_FORMAT") == "27":
            # macOS 27 names the program relative to its bundle and gives the pid only while it runs.
            print("\\tprogram identifier = Contents/MacOS/sprava-runtime (mode: 2)")
            if os.environ.get("TEST_JOB_RUNNING", "1") == "1":
                print("\\tpid = 4242")
        else:
            print("program = " + app + "/Contents/MacOS/sprava-runtime")
elif name == "lsof":
    app = os.environ.get("TEST_JOB_APP", os.environ["SPRAVA_INSTALL_DIR"] + "/Sprava.app")
    assert args == ["-a", "-p", "4242", "-d", "txt", "-Fn"], args
    print("p4242\\nftxt\\nn" + app + "/Contents/MacOS/sprava-runtime")
elif name == "osascript":
    script = sys.stdin.read()
    assert script.index("display dialog") < script.index("to quit")
    assert "Save any unfinished notes" in script
    assert 'cancel button "Cancel"' in script
    Path(os.environ["TEST_LOG"] + ".quit").touch()
    sys.exit(int(os.environ.get("TEST_QUIT_FAIL", "0")))
elif name == "pgrep":
    running = os.environ.get("TEST_STILL_RUNNING") == "1" or (
        os.environ.get("TEST_APP_RUNNING") == "1" and
        not Path(os.environ["TEST_LOG"] + ".quit").exists())
    sys.exit(0 if running else 1)
elif name == "mv":
    if Path(args[0]).name == "Sprava.app" and ".sprava-update." in args[0]:
        if os.environ.get("TEST_INSTALL_FAIL") == "1":
            sys.exit(1)
    import shutil
    shutil.move(*args)
elif name == "open":
    if "--refresh-background-registration" in args:
        assert args[1:] == ["--args", "--refresh-background-registration"], args
        assert (Path(args[0]) / "version").read_text() == "new\\n"
    sys.exit(int(os.environ.get("TEST_OPEN_FAIL", "0")))
''')
        fake.chmod(0o755)
        for name in ["launchctl", "lsof", "osascript", "pgrep", "open", "sleep", "mv"]:
            (self.bin / name).symlink_to(fake)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        SPRAVA_INSTALL_DIR=str(self.apps), TEST_LOG=str(self.log), TEST_APP_RUNNING="1")

    def installed(self):
        self.app.mkdir()
        (self.app / "version").write_text("old\n")

    def run_script(self, **env):
        result = subprocess.run([str(self.repo / "scripts/restart-app.sh"), "-c", "release"],
                                env=dict(self.env, **env), capture_output=True, text=True)
        self.assertFalse(list(self.apps.glob(".sprava-update.*")), result.stderr)
        return result

    def test_first_install_does_not_enable_background_work(self):
        result = self.run_script(TEST_APP_RUNNING="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "version").read_text(), "new\n")
        events = self.log.read_text()
        self.assertIn("build -c release", events)
        self.assertIn(f"open {self.app}", events)
        self.assertNotIn("kickstart", events)
        self.assertNotIn("osascript", events)

    def test_update_builds_before_quitting_and_hands_registration_to_the_new_app(self):
        self.installed()
        result = self.run_script(TEST_JOBS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.log.read_text()
        self.assertLess(events.index("build"), events.index("osascript"))
        self.assertIn(f"open {self.app} --args --refresh-background-registration", events)
        self.assertNotIn("kickstart", events)
        self.assertEqual((self.app / "version").read_text(), "new\n")

    def test_build_failure_leaves_installed_app_running(self):
        self.installed()
        result = self.run_script(TEST_BUILD_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / "version").read_text(), "old\n")
        self.assertNotIn("osascript", self.log.read_text())
        self.assertNotIn("kickstart", self.log.read_text())

    def test_cancelled_update_leaves_installed_bundle(self):
        self.installed()
        result = self.run_script(TEST_QUIT_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / "version").read_text(), "old\n")

    def test_app_that_stays_open_is_never_force_killed(self):
        self.installed()
        result = self.run_script(TEST_STILL_RUNNING="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / "version").read_text(), "old\n")
        self.assertIn("Sprava has not quit", result.stderr)
        self.assertNotIn("kickstart", self.log.read_text())

    def test_background_job_from_another_copy_is_refused(self):
        self.installed()
        result = self.run_script(TEST_JOBS="1", TEST_JOB_APP="/another/Sprava.app")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("build", self.log.read_text())
        self.assertEqual((self.app / "version").read_text(), "old\n")

    def test_macos_27_running_job_of_this_copy_is_restarted(self):
        self.installed()
        result = self.run_script(TEST_JOBS="1", TEST_JOB_FORMAT="27")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"open {self.app} --args --refresh-background-registration", self.log.read_text())
        self.assertNotIn("kickstart", self.log.read_text())
        self.assertEqual((self.app / "version").read_text(), "new\n")

    def test_macos_27_running_job_of_another_copy_is_refused(self):
        self.installed()
        result = self.run_script(TEST_JOBS="1", TEST_JOB_FORMAT="27", TEST_JOB_APP="/another/Sprava.app")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("build", self.log.read_text())
        self.assertEqual((self.app / "version").read_text(), "old\n")

    def test_macos_27_job_that_is_not_running_is_left_to_the_app(self):
        self.installed()
        result = self.run_script(TEST_JOBS="1", TEST_JOB_FORMAT="27", TEST_JOB_RUNNING="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("kickstart", self.log.read_text())
        self.assertNotIn("--refresh-background-registration", self.log.read_text())
        self.assertEqual((self.app / "version").read_text(), "new\n")

    def test_failed_install_restores_and_opens_previous_bundle(self):
        self.installed()
        result = self.run_script(TEST_INSTALL_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / "version").read_text(), "old\n")
        self.assertIn(f"open {self.app}", self.log.read_text())

    def test_failed_open_is_reported_after_installing_the_complete_bundle(self):
        self.installed()
        result = self.run_script(TEST_JOBS="1", TEST_OPEN_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / "version").read_text(), "new\n")
        self.assertIn(f"open {self.app}", self.log.read_text())

    def test_install_link_is_refused(self):
        other = self.root / "other.app"
        other.mkdir()
        self.app.symlink_to(other)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("build", self.log.read_text())
        self.assertTrue(self.app.is_symlink())


unittest.main(argv=[sys.argv[0]])
PY
