#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

python3 - "$root/Scripts" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

scripts = Path(sys.argv[1])
metadata = scripts / "release-metadata.sh"
for tag, version, prerelease in [
    ("v1.0.0", "1.0.0", "false"),
    ("v0.12.3-alpha.1", "0.12.3", "true"),
    ("v1.0.0-beta.12", "1.0.0", "true"),
    ("v2.3.4-rc.2", "2.3.4", "true"),
]:
    result = subprocess.run([str(metadata), tag], capture_output=True, text=True, check=True)
    assert result.stdout == f"version={version}\nrelease_version={tag[1:]}\nprerelease={prerelease}\n"

for arguments in [
    [], ["v1.0.0", "extra"], [""], ["1.0.0"], ["v1.0"], ["v01.0.0"],
    ["v1.00.0"], ["v1.0.01"], ["v1.0.0-alpha.0"], ["v1.0.0-beta.01"],
    ["v1.0.0-preview.1"], ["v1.0.0-rc"], ["v1.0.0+metadata"],
    ["v1.0.0\nprerelease=false"], ["v1.0.0-rc.1/../../escape"],
]:
    result = subprocess.run([str(metadata), *arguments], capture_output=True, text=True)
    assert result.returncode == 2 and not result.stdout, (arguments, result)

# Exercise both distributions with disposable bundles and no Apple credentials or tools.
def check_release(*, release_version=None, distribution=None, positional=(), identity=None, profile=None,
                  keychain=False, missing_private=False, notary_status="Accepted", expected_status=0, expected_error=None):
    with tempfile.TemporaryDirectory(prefix="traynook-release-") as directory:
        root = Path(directory)
        fixture_scripts = root / "Scripts"
        fixture_scripts.mkdir()
        shutil.copy2(metadata, fixture_scripts / metadata.name)
        for name in ("test.sh", "build-app.sh", "smoke-test.sh"):
            target = fixture_scripts / name
            target.write_text('#!/bin/bash\nprintf "%s %s %s\\n" "$(basename "$0")" "${1:-}" "$TRAYNOOK_DISTRIBUTION" >> "$TRAYNOOK_TEST_STEPS"\n')
            target.chmod(0o755)
        (fixture_scripts / "update-feed.py").write_text('''import os, pathlib, sys
assert pathlib.Path(sys.argv[1]).is_file()
assert pathlib.Path(sys.argv[sys.argv.index("--notes") + 1]).name == "CHANGELOG.md"
assert sys.argv[sys.argv.index("--signer") + 1].endswith("/x86_64/artifacts/sparkle/Sparkle/bin/sign_update")
apple_log = pathlib.Path(os.environ["TRAYNOOK_TEST_APPLE_LOG"])
if os.environ["TRAYNOOK_DISTRIBUTION"] == "notarized":
    assert "stapler\\tvalidate" in apple_log.read_text()
else:
    assert not apple_log.exists()
pathlib.Path(sys.argv[sys.argv.index("--output") + 1]).write_text("fixture appcast")
''')
        (root / "CHANGELOG.md").write_text("Fixture release notes")
        (root / "private-key").write_text("mock key; never passed to a real signer")
        (root / ".build").mkdir()
        (root / "dist" / "TrayNook.app").mkdir(parents=True)
        tools = root / "tools"
        tools.mkdir()
        mocks = {
            "plutil": '#!/bin/bash\nif [[ "$2" == status ]]; then echo "$TRAYNOOK_TEST_NOTARY_STATUS"; else echo 1.0.0; fi\n',
            "ditto": '#!/bin/bash\nprintf "%s\\n" "${@: -1}" >> "$TRAYNOOK_TEST_ARCHIVES"\ntouch "${@: -1}"\n',
            "xcrun": '''#!/bin/bash
printf '%s\\t' "$@" >> "$TRAYNOOK_TEST_APPLE_LOG"
printf '\\n' >> "$TRAYNOOK_TEST_APPLE_LOG"
if [[ "$1" == notarytool ]]; then printf "%s\\n" "$@" > "$TRAYNOOK_TEST_NOTARY_ARGUMENTS"; echo "{}"; fi
''',
            "codesign": "#!/bin/bash\nexit 0\n",
            "spctl": '#!/bin/bash\nprintf "spctl\\n" >> "$TRAYNOOK_TEST_APPLE_LOG"\n',
            "security": '#!/bin/bash\nprintf "security\\n" >> "$TRAYNOOK_TEST_APPLE_LOG"\nexit 99\n',
        }
        source = (scripts / "release.sh").read_text()
        for name, contents in mocks.items():
            target = tools / name
            target.write_text(contents)
            target.chmod(0o755)
            source = source.replace(f"/usr/bin/{name}", str(target)).replace(f"/usr/sbin/{name}", str(target))
        release = fixture_scripts / "release.sh"
        release.write_text(source)
        environment = os.environ.copy()
        for name in ("TRAYNOOK_RELEASE_VERSION", "TRAYNOOK_VERSION", "TRAYNOOK_BUILD", "TRAYNOOK_NOTARY_KEYCHAIN",
                     "TRAYNOOK_UPDATE_PRIVATE_KEY_FILE", "TRAYNOOK_DISTRIBUTION", "TRAYNOOK_SIGNING_IDENTITY", "TRAYNOOK_NOTARY_PROFILE"):
            environment.pop(name, None)
        environment.update(PATH=f"{tools}:{environment['PATH']}", TRAYNOOK_TEST_NOTARY_ARGUMENTS=str(root / "notary-arguments"),
                           TRAYNOOK_UPDATE_PRIVATE_KEY_FILE=str(root / "private-key"), TRAYNOOK_TEST_STEPS=str(root / "steps"),
                           TRAYNOOK_TEST_APPLE_LOG=str(root / "apple-log"), TRAYNOOK_TEST_ARCHIVES=str(root / "archives"),
                           TRAYNOOK_TEST_NOTARY_STATUS=notary_status)
        if release_version is not None:
            environment["TRAYNOOK_RELEASE_VERSION"] = release_version
        if distribution is not None:
            environment["TRAYNOOK_DISTRIBUTION"] = distribution
        if identity is not None:
            environment["TRAYNOOK_SIGNING_IDENTITY"] = identity
        if profile is not None:
            environment["TRAYNOOK_NOTARY_PROFILE"] = profile
        if keychain:
            environment["TRAYNOOK_NOTARY_KEYCHAIN"] = str(root / "disposable keychain")
        if missing_private:
            environment.pop("TRAYNOOK_UPDATE_PRIVATE_KEY_FILE")
        result = subprocess.run(["/bin/bash", str(release), *positional], env=environment, capture_output=True, text=True)
        assert result.returncode == expected_status, result.stderr
        archives = sorted(path.name for path in (root / "dist").glob("*.zip*"))
        effective_distribution = distribution if distribution is not None else ("notarized" if positional else "adhoc")
        if expected_status == 0:
            archive = f"TrayNook-{release_version or '1.0.0'}.zip"
            assert archives == [archive, f"{archive}.sha256"], archives
            assert (root / "dist" / f"{archive}.sha256").read_text().strip().endswith(f"  {archive}")
            assert (root / "dist" / "appcast.xml").exists() == (release_version is None or "-" not in release_version)
            assert f"build-app.sh release {effective_distribution}" in (root / "steps").read_text()
            generated_archives = (root / "archives").read_text().splitlines()
            if effective_distribution == "notarized":
                assert len(generated_archives) == 2
                arguments = (root / "notary-arguments").read_text().splitlines()
                if keychain:
                    index = arguments.index("--keychain")
                    assert arguments[index + 1] == environment["TRAYNOOK_NOTARY_KEYCHAIN"]
                else:
                    assert "--keychain" not in arguments
                apple_calls = (root / "apple-log").read_text()
                assert "stapler\tstaple" in apple_calls and "stapler\tvalidate" in apple_calls and "spctl" in apple_calls
            else:
                assert len(generated_archives) == 1
                assert not (root / "apple-log").exists(), "Ad-hoc release invoked Apple credential/notarization tools"
                assert not (root / "notary-arguments").exists()
        else:
            assert not archives and not (root / "dist" / "appcast.xml").exists(), "Failed release fell back to unsigned output"
            if expected_error:
                assert expected_error in result.stderr, result.stderr
            if notary_status != "Accepted":
                assert (root / "notary-arguments").exists()
                assert "stapler" not in (root / "apple-log").read_text()
            else:
                assert not (root / "apple-log").exists()
            if expected_error in ("TRAYNOOK_DISTRIBUTION", "Developer ID Application", "TRAYNOOK_UPDATE_PRIVATE_KEY_FILE"):
                assert not (root / "steps").exists(), "Release started before required credentials/mode were checked"


check_release()
check_release(release_version="1.0.0-beta.2")
check_release(release_version="2.0.0-rc.1", expected_status=2, expected_error="marketing version")
check_release(distribution="adhoc", identity="unused-certificate", profile="unused-profile")
check_release(distribution="adhoc", positional=("unused-certificate", "unused-profile"))
check_release(positional=("fixture-identity", "fixture-profile"))
check_release(distribution="notarized", identity="fixture-identity", profile="fixture-profile", keychain=True)
check_release(distribution="notarized", identity="fixture-identity", profile="fixture-profile", notary_status="Rejected",
              expected_status=1, expected_error="Apple did not accept")
check_release(distribution="notarized", expected_status=2, expected_error="Developer ID Application")
check_release(distribution="notarized", identity="fixture-identity", expected_status=2, expected_error="Developer ID Application")
check_release(distribution="notarized", identity="-", profile="fixture-profile", expected_status=2, expected_error="Developer ID Application")
check_release(positional=("fixture-identity",), expected_status=2, expected_error="Developer ID Application")
check_release(distribution="invalid", expected_status=2, expected_error="TRAYNOOK_DISTRIBUTION")
check_release(distribution="", expected_status=2, expected_error="TRAYNOOK_DISTRIBUTION")
check_release(missing_private=True, expected_status=2, expected_error="TRAYNOOK_UPDATE_PRIVATE_KEY_FILE")

print("Release metadata passed: default ad-hoc archives without Apple tools, opt-in notarization, fail-closed credentials/gates, stable feeds, and legacy arguments.")
PY
