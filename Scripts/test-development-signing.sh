#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

# Exercise the packaging script with disposable bundles and fake signing tools.
python3 - "$root/Scripts/build-app.sh" <<'PY'
import os
import base64
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()


def check(*, existing=True, detected="", explicit=None, query_fails=False, mode="dev", public_key=None,
          distribution=None, release_identity=None):
    with tempfile.TemporaryDirectory(prefix="traynook-signing-") as temporary:
        root = Path(temporary)
        scripts = root / "Scripts"
        scripts.mkdir()
        tools = root / "tools"
        tools.mkdir()
        output = root / "compiled"
        (output / "TrayNook_TrayNook.bundle").mkdir(parents=True)
        (output / "TrayNook").write_text("new executable")
        support = root / "Support"
        support.mkdir()
        (support / "Info.plist").write_text("fixture plist")
        (support / "AppIcon.icns").write_text("fixture icon")
        (root / "LICENSE").write_text("fixture license")
        for architecture in ("native", "arm64", "x86_64"):
            artifact = root / ".build" / "distribution" / architecture / "artifacts" / "sparkle" / "Sparkle"
            framework = artifact / "Sparkle.xcframework" / "macos-arm64_x86_64" / "Sparkle.framework"
            version = framework / "Versions" / "B"
            for name in ("Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
                         "XPCServices/Downloader.xpc/Contents/MacOS/Downloader", "XPCServices/Installer.xpc/Contents/MacOS/Installer"):
                executable = version / name
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_text("nested executable")
                executable.chmod(0o755)
            (framework / "Versions" / "Current").symlink_to("B")
            for name in ("Sparkle", "Autoupdate", "Updater.app", "XPCServices"):
                (framework / name).symlink_to(f"Versions/Current/{name}")
            (artifact / "LICENSE").write_text("fixture Sparkle license")
        app = root / "dist" / ("TrayNook.app" if mode == "release" else "TrayNook Dev.app")
        if existing:
            app.mkdir(parents=True)
            (app / "previous").write_text("preserve this app")
        mocks = {
            "security": '''#!/bin/bash
printf 'called\\n' >> "$TRAYNOOK_TEST_SECURITY_LOG"
if [[ "$TRAYNOOK_TEST_QUERY_FAILS" == 1 ]]; then exit 1; fi
if [[ -n "$TRAYNOOK_TEST_DETECTED" ]]; then
  printf '  1) %s "TrayNook Dev"\\n' "$TRAYNOOK_TEST_DETECTED"
fi
''',
            "codesign": '''#!/bin/bash
printf '%s\\t' "$@" >> "$TRAYNOOK_TEST_CODESIGN_LOG"
printf '\\n' >> "$TRAYNOOK_TEST_CODESIGN_LOG"
if [[ "$1" == -dv ]]; then echo 'Signature=adhoc' >&2; exit 0; fi
if [[ "$1" == --force ]]; then
  printf '%s\\n' "$3" > "$TRAYNOOK_TEST_SIGNATURE"
  printf '%s\\t' "$@" >> "$TRAYNOOK_TEST_SIGNING_LOG"
  printf '\\n' >> "$TRAYNOOK_TEST_SIGNING_LOG"
fi
''',
            "lipo": '''#!/bin/bash
if [[ "$1" == -create ]]; then cp "$2" "${@: -1}"; fi
''',
            "plutil": '''#!/bin/bash
printf '%s\\t' "$@" >> "$TRAYNOOK_TEST_PLUTIL_LOG"
printf '\\n' >> "$TRAYNOOK_TEST_PLUTIL_LOG"
''',
            "swift": '''#!/bin/bash
printf 'called\\n' >> "$TRAYNOOK_TEST_BUILDS"
for argument in "$@"; do
  if [[ "$argument" == --show-bin-path ]]; then printf '%s\\n' "$TRAYNOOK_TEST_COMPILED"; fi
done
''',
        }
        script = source
        for name, contents in mocks.items():
            mock = tools / name
            mock.write_text(contents)
            mock.chmod(0o755)
            script = script.replace(f"/usr/bin/{name}", str(mock))
        target = scripts / "build-app.sh"
        target.write_text(script)
        environment = os.environ.copy()
        for name in ("TRAYNOOK_DEV_SIGNING_IDENTITY", "TRAYNOOK_VERSION", "TRAYNOOK_BUILD", "TRAYNOOK_UPDATE_PUBLIC_KEY",
                     "TRAYNOOK_DISTRIBUTION", "TRAYNOOK_SIGNING_IDENTITY"):
            environment.pop(name, None)
        environment.update(
            PATH=f"{tools}:{environment['PATH']}",
            TRAYNOOK_TEST_DETECTED=detected,
            TRAYNOOK_TEST_QUERY_FAILS="1" if query_fails else "0",
            TRAYNOOK_TEST_SIGNATURE=str(root / "signature"),
            TRAYNOOK_TEST_SIGNING_LOG=str(root / "signing-log"),
            TRAYNOOK_TEST_CODESIGN_LOG=str(root / "codesign-log"),
            TRAYNOOK_TEST_SECURITY_LOG=str(root / "security-log"),
            TRAYNOOK_TEST_PLUTIL_LOG=str(root / "plutil-log"),
            TRAYNOOK_TEST_BUILDS=str(root / "builds"),
            TRAYNOOK_TEST_COMPILED=str(output),
        )
        if explicit is not None:
            environment["TRAYNOOK_DEV_SIGNING_IDENTITY"] = explicit
        if release_identity is not None:
            environment["TRAYNOOK_SIGNING_IDENTITY"] = release_identity
        if distribution is not None:
            environment["TRAYNOOK_DISTRIBUTION"] = distribution
        if public_key is not None:
            environment["TRAYNOOK_UPDATE_PUBLIC_KEY"] = public_key
        result = subprocess.run(["/bin/bash", str(target), mode], env=environment, capture_output=True, text=True)
        notarized = mode == "release" and distribution == "notarized"
        if mode == "release":
            assert not (root / "security-log").exists(), "Release queried the Apple keychain"
        if distribution is not None and distribution not in ("adhoc", "notarized"):
            assert result.returncode == 2 and "TRAYNOOK_DISTRIBUTION" in result.stderr
            assert not (root / "builds").exists()
            return
        if notarized and (not release_identity or release_identity == "-"):
            assert result.returncode == 2 and "Developer ID Application" in result.stderr
            assert not (root / "builds").exists(), "Notarized build fell back without a Developer ID"
            return
        should_reject = mode == "dev" and existing and not detected and explicit is None
        invalid_key = public_key is not None and public_key != base64.b64encode(bytes(32)).decode()
        if (mode == "release" and public_key is None) or invalid_key:
            assert result.returncode != 0, "Invalid/missing update key was accepted"
            assert not (root / "builds").exists(), "Build started before update key was valid"
            assert "TRAYNOOK_UPDATE_PUBLIC_KEY" in result.stderr
            return
        if should_reject:
            assert result.returncode != 0, "Existing ad-hoc app was silently replaced"
            assert (app / "previous").read_text() == "preserve this app"
            assert not (root / "builds").exists(), "Build started before signing was safe"
            assert "keychain" in result.stderr.lower(), result.stderr
            assert "TRAYNOOK_DEV_SIGNING_IDENTITY" in result.stderr, result.stderr
        else:
            assert result.returncode == 0, result.stderr
            assert (app / "Contents" / "MacOS" / "TrayNook").read_text() == "new executable"
            assert (app / "Contents" / "Resources" / "LICENSE").read_text() == "fixture license"
            identity = release_identity if notarized else ("-" if mode == "release" else (explicit or detected or "-"))
            assert (root / "signature").read_text().strip() == identity
            framework = app / "Contents" / "Frameworks" / "Sparkle.framework"
            assert (framework / "Versions" / "Current").is_symlink()
            assert (framework / "Autoupdate").is_symlink()
            assert os.access(framework / "Autoupdate", os.X_OK)
            assert (app / "Contents" / "Resources" / "Sparkle-LICENSE").read_text() == "fixture Sparkle license"
            signed = [line.split("\t")[:-1] for line in (root / "signing-log").read_text().splitlines()]
            suffixes = ["/Versions/B/Autoupdate", "/Versions/B/Updater.app/Contents/MacOS/Updater", "/Versions/B/Updater.app",
                        "/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader", "/Versions/B/XPCServices/Downloader.xpc",
                        "/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer", "/Versions/B/XPCServices/Installer.xpc",
                        "/Versions/B/Sparkle", "/Sparkle.framework", f"/{app.name}"]
            assert len(signed) == len(suffixes), signed
            for arguments, suffix in zip(signed, suffixes):
                assert arguments[-1].endswith(suffix), arguments
                assert arguments[2] == identity and "--deep" not in arguments
                assert ("--timestamp" in arguments) == notarized
                assert ("runtime" in arguments) == notarized
            assert ("anchor apple generic" in (root / "codesign-log").read_text()) == notarized
            expected_distribution = (distribution or "adhoc") if mode == "release" else "development"
            assert f"-replace\tTrayNookDistribution\t-string\t{expected_distribution}\t" in (root / "plutil-log").read_text()


check()
check(query_fails=True)
check(detected="fixture-certificate")
check(explicit="explicit-certificate")
check(explicit="-")
check(existing=False)
check(mode="release")
check(existing=False, public_key="invalid-key")
public_key = base64.b64encode(bytes(32)).decode()
check(mode="release", public_key=public_key)
check(mode="release", distribution="adhoc", public_key=public_key, explicit="ignored-dev-certificate", release_identity="ignored-release-certificate")
check(mode="release", distribution="notarized", public_key=public_key, release_identity="release-certificate")
check(mode="release", distribution="notarized", public_key=public_key)
check(mode="release", distribution="notarized", public_key=public_key, release_identity="-")
check(mode="release", distribution="invalid", public_key=public_key)
check(mode="release", distribution="", public_key=public_key)
print("Packaging guards passed: default ad-hoc Universal 2 release, optional Developer ID signing, distribution metadata, preserved development identity, update keys, and nested signatures.")
PY
