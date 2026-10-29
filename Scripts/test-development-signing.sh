#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

# Exercise the packaging script with disposable bundles and fake signing tools.
python3 - "$root/Scripts/build-app.sh" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()


def check(*, existing=True, detected="", explicit=None, query_fails=False):
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
        app = root / "dist" / "TrayNook Dev.app"
        if existing:
            app.mkdir(parents=True)
            (app / "previous").write_text("preserve this app")
        mocks = {
            "security": '''#!/bin/bash
if [[ "$TRAYNOOK_TEST_QUERY_FAILS" == 1 ]]; then exit 1; fi
if [[ -n "$TRAYNOOK_TEST_DETECTED" ]]; then
  printf '  1) %s "TrayNook Dev"\\n' "$TRAYNOOK_TEST_DETECTED"
fi
''',
            "codesign": '''#!/bin/bash
if [[ "$1" == -dv ]]; then echo 'Signature=adhoc' >&2; exit 0; fi
if [[ "$1" == --force ]]; then printf '%s\\n' "$3" > "$TRAYNOOK_TEST_SIGNATURE"; fi
''',
            "plutil": "#!/bin/bash\nexit 0\n",
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
        for name in ("TRAYNOOK_DEV_SIGNING_IDENTITY", "TRAYNOOK_VERSION", "TRAYNOOK_BUILD"):
            environment.pop(name, None)
        environment.update(
            PATH=f"{tools}:{environment['PATH']}",
            TRAYNOOK_TEST_DETECTED=detected,
            TRAYNOOK_TEST_QUERY_FAILS="1" if query_fails else "0",
            TRAYNOOK_TEST_SIGNATURE=str(root / "signature"),
            TRAYNOOK_TEST_BUILDS=str(root / "builds"),
            TRAYNOOK_TEST_COMPILED=str(output),
        )
        if explicit is not None:
            environment["TRAYNOOK_DEV_SIGNING_IDENTITY"] = explicit
        result = subprocess.run(["/bin/bash", str(target)], env=environment, capture_output=True, text=True)
        should_reject = existing and not detected and explicit is None
        if should_reject:
            assert result.returncode != 0, "Existing ad-hoc app was silently replaced"
            assert (app / "previous").read_text() == "preserve this app"
            assert not (root / "builds").exists(), "Build started before signing was safe"
            assert "keychain" in result.stderr.lower(), result.stderr
            assert "TRAYNOOK_DEV_SIGNING_IDENTITY" in result.stderr, result.stderr
        else:
            assert result.returncode == 0, result.stderr
            assert (app / "Contents" / "MacOS" / "TrayNook").read_text() == "new executable"
            assert (root / "signature").read_text().strip() == (explicit or detected or "-")


check()
check(query_fails=True)
check(detected="fixture-certificate")
check(explicit="explicit-certificate")
check(explicit="-")
check(existing=False)
print("Development signing guard passed: existing bundles preserved, certificate and explicit overrides honored.")
PY
