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


TEAM = "TEAMFAKE01"   # invented


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
# Team-signed by default; TEST_BUILD_TEAM=- builds ad-hoc.
team=${TEST_BUILD_TEAM-TEAMFAKE01}
[ "$team" = - ] || echo "$team" > "$SPRAVA_APP_BUNDLE/team"
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
elif name == "codesign":
    # A stand-in bundle names its signer in a "team" file (none: ad-hoc); "odd-team" names an executable signed by
    # another team, "not-apple" a signature that is not Apple-issued, and "not-apple-exe" one executable whose
    # signature is not Apple-issued though it names the team.
    target = Path(args[-1])
    bundle = next((p for p in [target, *target.parents] if p.suffix == ".app"), target)
    team = (bundle / "team").read_text().strip() if (bundle / "team").exists() else "not set"
    if args[:3] == ["--verify", "--deep", "--strict"] and len(args) == 4:
        sys.exit(int(os.environ.get("TEST_CODESIGN_FAIL", "0")))
    if args[0] == "--verify" and args[1].startswith("-R=") and len(args) == 3:
        wanted = args[1].split('leaf[subject.OU] = "')[1].rstrip('"')
        assert args[1].startswith("-R=anchor apple generic and "), args
        odd_exe = (bundle / "not-apple-exe").read_text().strip() if (bundle / "not-apple-exe").exists() else None
        sys.exit(0 if team == wanted and not (bundle / "not-apple").exists() and target.name != odd_exe else 1)
    assert args[:2] == ["-d", "--verbose=2"] and len(args) == 3, args
    odd = (bundle / "odd-team").read_text().strip() if (bundle / "odd-team").exists() else None
    print("TeamIdentifier=" + ("TEAMOTHER9" if target.name == odd else team), file=sys.stderr)
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
        for name in ["launchctl", "lsof", "codesign", "osascript", "pgrep", "open", "sleep", "mv"]:
            (self.bin / name).symlink_to(fake)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        SPRAVA_INSTALL_DIR=str(self.apps), TEST_LOG=str(self.log), TEST_APP_RUNNING="1")

    def bundle(self, path, identifier="ca.orlenko.sprava"):
        """A stand-in for a built Sprava.app: its Info.plist and runtime executable; codesign is the fake."""
        import plistlib
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/MacOS/sprava-runtime").write_text("runtime\n")
        with open(path / "Contents/Info.plist", "wb") as f:
            plistlib.dump({"CFBundleIdentifier": identifier}, f)
        return path

    @property
    def build_app(self):
        return self.repo / "build/Sprava.app"

    def installed(self, team=None):
        self.app.mkdir()
        (self.app / "version").write_text("old\n")
        if team:
            (self.app / "team").write_text(team + "\n")

    def signed_elsewhere(self, team=TEAM, identifier="ca.orlenko.sprava"):
        """A bundle built and signed on another Mac, as the person copied it here."""
        path = self.bundle(self.root / "from the other Mac/Sprava.app", identifier)
        (path / "Contents/MacOS/SpravaApp").write_text("app\n")
        (path / "version").write_text("new\n")
        (path / "team").write_text(team + "\n")
        return path

    def install(self, path, team=TEAM, **env):
        return self.run_script("--install", str(path), "--team", team, **env)

    def run_script(self, *args, **env):
        result = subprocess.run([str(self.repo / "scripts/restart-app.sh"), *(args or ["-c", "release"])],
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

    def test_background_work_of_this_checkouts_build_moves_to_the_installed_app(self):
        self.bundle(self.build_app)
        for job_format in ["", "27"]:
            with self.subTest(job_format=job_format or "program ="):
                if self.app.exists():
                    shutil.rmtree(self.app)
                self.log.write_text("")
                Path(str(self.log) + ".quit").unlink(missing_ok=True)
                result = self.run_script(TEST_JOBS="1", TEST_JOB_FORMAT=job_format, TEST_JOB_APP=str(self.build_app))
                self.assertEqual(result.returncode, 0, result.stderr)
                events = self.log.read_text()
                self.assertIn(f"codesign --verify --deep --strict {self.build_app}", events)
                self.assertLess(events.index("build"), events.index("osascript"))
                self.assertIn(f"open {self.app} --args --refresh-background-registration", events)
                self.assertNotIn("kickstart", events)
                self.assertNotIn("bootout", events)
                self.assertEqual((self.app / "version").read_text(), "new\n")
                # The build copy itself is left as it was.
                self.assertTrue((self.build_app / "Contents/MacOS/sprava-runtime").is_file())

    def assert_refused(self, result, job_app):
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("build ", self.log.read_text())
        self.assertNotIn("open ", self.log.read_text())
        self.assertEqual((self.app / "version").read_text(), "old\n")

    def test_a_bundle_signed_elsewhere_is_installed_without_building(self):
        self.installed(TEAM)
        source = self.signed_elsewhere()
        result = self.install(source, TEST_JOBS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.log.read_text()
        self.assertNotIn("build", events)
        # Checked where it was and again once copied onto the install volume, all before Sprava is asked to quit.
        anchors = [i for i, line in enumerate(events.splitlines())
                   if "-R=anchor apple generic" in line and line.endswith("Sprava.app")]
        self.assertEqual(len(anchors), 2, events)
        self.assertIn(str(source), events.splitlines()[anchors[0]])
        self.assertIn(".sprava-update.", events.splitlines()[anchors[1]])
        self.assertLess(anchors[1], next(i for i, l in enumerate(events.splitlines()) if l.startswith("osascript")))
        self.assertIn(f"open {self.app} --args --refresh-background-registration", events)
        self.assertEqual((self.app / "version").read_text(), "new\n")
        self.assertEqual((source / "version").read_text(), "new\n")

    def test_a_bundle_signed_elsewhere_that_does_not_match_is_refused(self):
        cases = {
            "another team": (lambda b: (b / "team").write_text("TEAMOTHER9\n"), "Apple-issued identity of the team"),
            "not Apple-issued": (lambda b: (b / "not-apple").write_text(""), "Apple-issued identity of the team"),
            "a helper of another team": (lambda b: (b / "odd-team").write_text("sprava-runtime"),
                                         "sprava-runtime in"),
            "a helper not Apple-issued": (lambda b: (b / "not-apple-exe").write_text("sprava-runtime"),
                                          "sprava-runtime in"),
            "ad-hoc": (lambda b: (b / "team").unlink(), "Apple-issued identity of the team"),
            "another app": (lambda b: self.bundle_id(b, "org.invented.other"), "not Sprava"),
        }
        for case, (spoil, message) in cases.items():
            with self.subTest(case=case):
                shutil.rmtree(self.root / "from the other Mac", ignore_errors=True)
                shutil.rmtree(self.app, ignore_errors=True)
                self.installed(TEAM)
                self.log.write_text("")
                source = self.signed_elsewhere()
                spoil(source)
                result = self.install(source, TEST_JOBS="1")
                self.assert_refused(result, source)
                self.assertIn(message, result.stderr)
                self.assertNotIn("osascript", self.log.read_text())

    def bundle_id(self, path, identifier):
        import plistlib
        with open(path / "Contents/Info.plist", "wb") as f:
            plistlib.dump({"CFBundleIdentifier": identifier}, f)

    def test_a_bundle_that_fails_verification_is_refused(self):
        self.installed(TEAM)
        result = self.install(self.signed_elsewhere(), TEST_CODESIGN_FAIL="1")
        self.assert_refused(result, None)
        self.assertIn("does not pass signature verification", result.stderr)

    def test_install_arguments_are_checked_before_anything_else(self):
        self.installed(TEAM)
        source = self.signed_elsewhere()
        link = self.root / "link.app"
        link.symlink_to(source)
        for args, message in [
            (["--install", str(source)], "usage"),
            (["--install", str(source), "--team"], "usage"),
            (["--install", str(source), "--team", "teamfake01"], "not a team id"),
            (["--install", str(source), "--team", TEAM, "-c", "release"], "usage"),
            (["--install", str(link), "--team", TEAM], "must be an app folder"),
            (["--install", str(self.app), "--team", TEAM], "installed app itself"),
        ]:
            with self.subTest(args=args):
                self.log.write_text("")
                result = self.run_script(*args)
                self.assert_refused(result, source)
                self.assertIn(message, result.stderr)

    def reset(self, installed):
        shutil.rmtree(self.app, ignore_errors=True)
        shutil.rmtree(self.root / "from the other Mac", ignore_errors=True)
        Path(str(self.log) + ".quit").unlink(missing_ok=True)
        if installed != "none":
            self.installed(installed)
        self.log.write_text("")

    def test_an_ad_hoc_app_moves_to_a_team_signed_one_without_being_asked(self):
        # The move to stable signing this updater exists for: built here or signed elsewhere.
        for kind in ["build", "install"]:
            with self.subTest(kind=kind):
                self.reset(None)
                result = self.install(self.signed_elsewhere(), TEST_JOBS="1") if kind == "install" \
                    else self.run_script(TEST_JOBS="1")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.app / "version").read_text(), "new\n")

    def test_a_move_to_ad_hoc_or_another_team_is_refused_with_no_way_around(self):
        for installed, new, kind, message in [
            (TEAM, "-", "build", "not signed by a team"),
            (None, "-", "build", "not signed by a team"),
            ("none", "-", "build", "not signed by a team"),
            ("TEAMOTHER9", TEAM, "build", "does not move between teams"),
            ("TEAMOTHER9", TEAM, "install", "does not move between teams"),
        ]:
            # An override that an earlier version of this script honoured changes nothing.
            for env in [{}, {"SPRAVA_ALLOW_SIGNING_CHANGE": "1"}]:
                with self.subTest(installed=installed, new=new, kind=kind, env=env):
                    self.reset(installed)
                    if kind == "install":
                        result = self.install(self.signed_elsewhere(), TEST_JOBS="1", **env)
                    else:
                        result = self.run_script(TEST_JOBS="1", TEST_BUILD_TEAM=new, **env)
                    # Refused once the new bundle's signer is known: after building, before Sprava is asked to quit.
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)
                    self.assertNotIn("osascript", self.log.read_text())
                    self.assertNotIn("open ", self.log.read_text())
                    if installed != "none":
                        self.assertEqual((self.app / "version").read_text(), "old\n")
                    else:
                        self.assertFalse(self.app.exists())

    def test_a_team_signed_build_replaces_a_build_of_the_same_team(self):
        self.installed(TEAM)
        result = self.run_script(TEST_JOBS="1", TEST_BUILD_TEAM=TEAM)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "version").read_text(), "new\n")

    def test_a_build_of_another_checkout_is_refused(self):
        self.installed()
        other = self.bundle(self.root / "another checkout/build/Sprava.app")
        result = self.run_script(TEST_JOBS="1", TEST_JOB_FORMAT="27", TEST_JOB_APP=str(other))
        self.assert_refused(result, other)
        self.assertIn("another Sprava copy", result.stderr)
        self.assertIn("Login Items", result.stderr)
        self.assertNotIn("Health", result.stderr)
        self.assertNotIn("codesign", self.log.read_text())

    def test_a_build_copy_that_is_not_genuine_is_refused(self):
        self.installed()
        elsewhere = self.bundle(self.root / "elsewhere/Sprava.app")
        cases = {
            "signature": lambda: (self.bundle(self.build_app), {"TEST_CODESIGN_FAIL": "1"})[1],
            "identifier": lambda: (self.bundle(self.build_app, "org.invented.other"), {})[1],
            "linked app": lambda: ((self.repo / "build").mkdir(), self.build_app.symlink_to(elsewhere), {})[2],
            "linked build folder": lambda: ((self.repo / "build").symlink_to(elsewhere.parent), {})[1],
            "linked runtime": lambda: (self.bundle(self.build_app),
                                       (self.build_app / "Contents/MacOS/sprava-runtime").unlink(),
                                       (self.build_app / "Contents/MacOS/sprava-runtime").symlink_to(
                                           elsewhere / "Contents/MacOS/sprava-runtime"), {})[3],
            "missing": lambda: {},
        }
        for case, prepare in cases.items():
            with self.subTest(case=case):
                build = self.repo / "build"
                if build.is_symlink():
                    build.unlink()
                elif build.exists():
                    shutil.rmtree(build)
                self.log.write_text("")
                extra = prepare()
                result = self.run_script(TEST_JOBS="1", TEST_JOB_FORMAT="27", TEST_JOB_APP=str(self.build_app), **extra)
                self.assert_refused(result, self.build_app)
                self.assertIn("not a genuine Sprava build", result.stderr)


unittest.main(argv=[sys.argv[0]])
PY
