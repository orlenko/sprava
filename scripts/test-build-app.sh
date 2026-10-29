#!/bin/sh
# Exercises build-app.sh in a throwaway checkout with stand-ins for swift, codesign, plutil and pgrep; nothing is
# built, signed or launched. Run: ./scripts/test-build-app.sh
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd -P)
python3 - "$repo" <<'PY'
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(sys.argv[1])
PRODUCTS = ["SpravaApp", "sprava", "sprava-runtime", "sprava-mcp", "sprava-extract"]


class BuildAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sprava-build-tests.")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "checkout with spaces"
        (self.repo / "scripts").mkdir(parents=True)
        shutil.copy2(REPO / "scripts/build-app.sh", self.repo / "scripts/build-app.sh")
        shutil.copytree(REPO / "Resources", self.repo / "Resources")
        shutil.copy2(REPO / "LICENSE", self.repo / "LICENSE")
        # The model helper's build (scripts/build-llm.sh) is a stand-in that leaves its two files where the real one does.
        llm = self.repo / "scripts/build-llm.sh"
        llm.write_text('#!/bin/sh\nset -eu\ncd "$(dirname "$0")/.."\necho "build-llm" >> "$TEST_LOG"\n'
                       '[ "${TEST_LLM_FAIL:-0}" = 0 ] || exit 1\nmkdir -p build/llm\n'
                       'echo sprava-llm > build/llm/sprava-llm\necho notices > build/llm/LICENSES.txt\n')
        llm.chmod(0o755)
        self.products = self.root / "products"
        self.products.mkdir()
        for name in PRODUCTS:
            (self.products / name).write_text(name + "\n")
        self.restic = self.root / "restic" / "bin" / "restic"
        self.restic.parent.mkdir(parents=True)
        self.restic.write_text("restic\n")
        self.restic.chmod(0o755)
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
if name == "pgrep":
    sys.exit(1)
if name == "swift":
    if "--show-bin-path" in args:
        print(os.environ["TEST_PRODUCTS"])
    sys.exit(0)
if name == "security":
    # Invented identities only: a made-up SHA-1 and name per kind listed in TEST_IDENTITIES.
    kinds = [k for k in os.environ.get("TEST_IDENTITIES", "").split(",") if k]
    for i, kind in enumerate(kinds):
        print('  %d) %s "%s: Invented Signer (TEAMFAKE01)"' % (i + 1, ("%X" % (i + 10)) * 40, kind))
    print("     %d valid identities found" % len(kinds))
    sys.exit(0)
if name == "codesign":
    import json
    signers = Path(os.environ["TEST_LOG"] + ".signers")
    def key(path):
        # The main executable is signed with the bundle.
        return "bundle" if path.suffix == ".app" or path.name == "SpravaApp" else path.name
    if "--verify" in args:
        if any(a.startswith("-R=") for a in args):
            sys.exit(int(os.environ.get("TEST_ANCHOR_FAIL", "0")))
        sys.exit(int(os.environ.get("TEST_VERIFY_FAIL", "0")))
    if "-d" in args:
        if "--entitlements" in args:
            print("<key>com.apple.security.app-sandbox</key>")
        else:
            identity = json.loads(signers.read_text()).get(key(Path(args[-1])), "-") if signers.exists() else "-"
            team = "not set" if identity == "-" else os.environ.get("TEST_TEAM", "TEAMFAKE01")
            if Path(args[-1]).name == os.environ.get("TEST_ODD_TEAM"):
                team = "TEAMOTHER9"
            print("flags=0x10002(adhoc,runtime)\\nTeamIdentifier=" + team, file=sys.stderr)
        sys.exit(0)
    target = Path(args[-1])
    recorded = json.loads(signers.read_text()) if signers.exists() else {}
    recorded[key(target)] = args[args.index("--sign") + 1]
    signers.write_text(json.dumps(recorded))
    if target.is_dir():
        if os.environ.get("TEST_SIGN_FAIL") == "1":
            sys.exit(1)
        seal = target / "Contents/_CodeSignature/CodeResources"
        seal.parent.mkdir(parents=True, exist_ok=True)
        keys = ["<key>Library/LaunchAgents/%s</key>" % p.name
                for p in sorted((target / "Contents/Library/LaunchAgents").iterdir())
                if p.name != os.environ.get("TEST_UNSEALED")]
        keys += ["<key>Resources/%s</key>" % p.name for p in sorted((target / "Contents/Resources").iterdir())]
        seal.write_text("\\n".join(keys) + "\\n")
sys.exit(0)
''')
        fake.chmod(0o755)
        for name in ["swift", "codesign", "plutil", "pgrep", "security"]:
            (self.bin / name).symlink_to(fake)
        self.bundle = self.root / "staging with spaces" / "Sprava.app"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", TEST_LOG=str(self.log),
                        TEST_PRODUCTS=str(self.products), SPRAVA_RESTIC=str(self.restic),
                        SPRAVA_APP_BUNDLE=str(self.bundle), TEST_IDENTITIES="Developer ID Application")
        self.env.pop("SPRAVA_SIGN_IDENTITY", None)

    def previous(self):
        self.bundle.mkdir(parents=True)
        (self.bundle / "version").write_text("old\n")

    def run_script(self, **env):
        result = subprocess.run([str(self.repo / "scripts/build-app.sh"), "-c", "release"],
                                env=dict(self.env, **env), capture_output=True, text=True)
        if self.bundle.parent.exists():
            self.assertEqual([p.name for p in self.bundle.parent.iterdir() if p.name != "Sprava.app"], [],
                             result.stderr)
        return result

    def signed(self):
        return [line.split()[-1] for line in self.log.read_text().splitlines()
                if line.startswith("codesign --force")]

    def test_finished_bundle_is_sealed_and_signed_last(self):
        self.previous()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.bundle / "version").exists())
        contents = self.bundle / "Contents"
        for name in PRODUCTS + ["restic", "sprava-llm"]:
            self.assertTrue((contents / "MacOS" / name).is_file(), name)
        self.assertEqual((contents / "Resources/llama.cpp-LICENSES.txt").read_text(), "notices\n")
        seal = (contents / "_CodeSignature/CodeResources").read_text()
        for plist in (self.repo / "Resources/LaunchAgents").iterdir():
            self.assertTrue((contents / "Library/LaunchAgents" / plist.name).is_file())
            self.assertIn(f"<key>Library/LaunchAgents/{plist.name}</key>", seal)
        signed = self.signed()
        self.assertEqual(len(signed), 7)
        self.assertTrue(signed[-1].endswith(".building-Sprava.app"), signed)
        self.assertIn("swift build --product SpravaApp -c release", self.log.read_text())

    def test_app_icon_is_bundled_and_named_by_info_plist(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        resources = self.bundle / "Contents/Resources"
        with open(self.bundle / "Contents/Info.plist", "rb") as f:
            info = plistlib.load(f)
        # The legacy icon file, and the asset catalog that holds the icon named by CFBundleIconName.
        icns = resources / (info["CFBundleIconFile"].removesuffix(".icns") + ".icns")
        self.assertEqual(icns.read_bytes(), (REPO / "Resources/AppIcon/AppIcon.icns").read_bytes())
        self.assertEqual(icns.read_bytes()[:4], b"icns")
        catalog = (resources / "Assets.car").read_bytes()
        self.assertEqual(catalog, (REPO / "Resources/AppIcon/Assets.car").read_bytes())
        self.assertIn(info["CFBundleIconName"].encode(), catalog)
        # Both are in place before the bundle is signed, so its signature seals them.
        seal = (self.bundle / "Contents/_CodeSignature/CodeResources").read_text()
        for name in [icns.name, "Assets.car"]:
            self.assertIn(f"<key>Resources/{name}</key>", seal)

    def test_missing_app_icon_keeps_previous_bundle(self):
        for name in ["AppIcon.icns", "Assets.car"]:
            with self.subTest(name):
                shutil.rmtree(self.bundle, ignore_errors=True)
                self.previous()
                icon = self.repo / "Resources/AppIcon" / name
                saved = icon.read_bytes()
                icon.unlink()
                result = self.run_script()
                icon.write_bytes(saved)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.bundle / "version").read_text(), "old\n")

    def test_missing_restic_builds_and_copies_nothing(self):
        self.previous()
        result = self.run_script(SPRAVA_RESTIC=str(self.root / "missing" / "restic"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restic not found", result.stderr)
        self.assertNotIn("swift", self.log.read_text())
        self.assertEqual((self.bundle / "version").read_text(), "old\n")

    def test_failed_model_helper_build_builds_nothing_else(self):
        self.previous()
        result = self.run_script(TEST_LLM_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("swift", self.log.read_text())
        self.assertEqual((self.bundle / "version").read_text(), "old\n")

    def test_model_helper_is_signed_with_its_sandbox(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        line = next(l for l in self.log.read_text().splitlines()
                    if l.startswith("codesign --force") and l.endswith("MacOS/sprava-llm"))
        self.assertIn("--identifier ca.orlenko.sprava.llm --entitlements Resources/sprava-llm.entitlements", line)

    def test_failed_bundle_signing_keeps_previous_bundle(self):
        self.previous()
        result = self.run_script(TEST_SIGN_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.bundle / "version").read_text(), "old\n")

    def test_failed_signing_without_previous_bundle_leaves_none(self):
        result = self.run_script(TEST_SIGN_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.bundle.exists())

    def test_failed_verification_keeps_previous_bundle(self):
        self.previous()
        result = self.run_script(TEST_VERIFY_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.bundle / "version").read_text(), "old\n")

    def identities(self):
        return {line.split()[-1]: line.split()[line.split().index("--sign") + 1]
                for line in self.log.read_text().splitlines() if line.startswith("codesign --force")}

    def test_the_one_apple_issued_identity_signs_everything_without_a_timestamp(self):
        for kind in ["Developer ID Application", "Apple Development"]:
            with self.subTest(kind):
                self.log.write_text("")
                Path(str(self.log) + ".signers").unlink(missing_ok=True)
                result = self.run_script(TEST_IDENTITIES=kind)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(set(self.identities().values()), {"A" * 40})
                for line in self.log.read_text().splitlines():
                    if line.startswith("codesign --force"):
                        self.assertIn("--timestamp=none --options runtime", line)
                self.assertIn('-R=anchor apple generic and certificate leaf[subject.OU] = "TEAMFAKE01"', self.log.read_text())

    def test_no_identity_or_several_build_nothing(self):
        for kinds, message in [("", "no Developer ID Application"),
                               ("Developer ID Application,Apple Development", "2 signing identities"),
                               ("Apple Distribution", "no Developer ID Application")]:
            with self.subTest(kinds):
                shutil.rmtree(self.bundle, ignore_errors=True)
                self.previous()
                self.log.write_text("")
                result = self.run_script(TEST_IDENTITIES=kinds)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertIn("SPRAVA_SIGN_IDENTITY", result.stderr)
                self.assertNotIn("swift", self.log.read_text())
                self.assertEqual((self.bundle / "version").read_text(), "old\n")

    def test_a_named_identity_is_used_without_looking_for_one(self):
        result = self.run_script(SPRAVA_SIGN_IDENTITY="B" * 40, TEST_IDENTITIES="Developer ID Application,Apple Development")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(self.identities().values()), {"B" * 40})
        self.assertNotIn("security", self.log.read_text())

    def test_ad_hoc_only_when_asked_and_said_so(self):
        result = self.run_script(SPRAVA_SIGN_IDENTITY="-", TEST_IDENTITIES="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(self.identities().values()), {"-"})
        self.assertIn("ad-hoc", result.stderr)
        self.assertIn("development only", result.stderr)
        self.assertNotIn("-R=", self.log.read_text())

    def test_a_helper_of_another_team_keeps_the_previous_bundle(self):
        self.previous()
        result = self.run_script(TEST_ODD_TEAM="sprava-runtime")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sprava-runtime is not signed by the same team", result.stderr)
        self.assertEqual((self.bundle / "version").read_text(), "old\n")

    def test_a_signature_that_is_not_apple_issued_keeps_the_previous_bundle(self):
        self.previous()
        result = self.run_script(TEST_ANCHOR_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not Apple-issued", result.stderr)
        self.assertEqual((self.bundle / "version").read_text(), "old\n")

    def test_an_identity_that_leaves_no_team_keeps_the_previous_bundle(self):
        self.previous()
        result = self.run_script(TEST_TEAM="not set")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("carries no team", result.stderr)
        self.assertEqual((self.bundle / "version").read_text(), "old\n")

    def test_unsealed_launch_agent_plist_is_refused(self):
        self.previous()
        result = self.run_script(TEST_UNSEALED="ca.orlenko.sprava.runtime.plist")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ca.orlenko.sprava.runtime.plist is not sealed", result.stderr)
        self.assertEqual((self.bundle / "version").read_text(), "old\n")


unittest.main(argv=[sys.argv[0]])
PY
