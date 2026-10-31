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

# Exercise archive naming and version mismatch without Apple credentials or tools.
for release_version, expected_status in [(None, 0), ("1.0.0-beta.2", 0), ("2.0.0-rc.1", 2)]:
    with tempfile.TemporaryDirectory(prefix="traynook-release-") as directory:
        root = Path(directory)
        fixture_scripts = root / "Scripts"
        fixture_scripts.mkdir()
        shutil.copy2(metadata, fixture_scripts / metadata.name)
        for name in ("test.sh", "build-app.sh", "smoke-test.sh"):
            target = fixture_scripts / name
            target.write_text("#!/bin/bash\nexit 0\n")
            target.chmod(0o755)
        (root / ".build").mkdir()
        (root / "dist" / "TrayNook.app").mkdir(parents=True)
        tools = root / "tools"
        tools.mkdir()
        mocks = {
            "plutil": '#!/bin/bash\nif [[ "$2" == status ]]; then echo Accepted; else echo 1.0.0; fi\n',
            "ditto": '#!/bin/bash\ntouch "${@: -1}"\n',
            "xcrun": '#!/bin/bash\nif [[ "$1" == notarytool ]]; then printf "%s\\n" "$@" > "$TRAYNOOK_TEST_NOTARY_ARGUMENTS"; echo "{}"; fi\n',
            "codesign": "#!/bin/bash\nexit 0\n",
            "spctl": "#!/bin/bash\nexit 0\n",
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
        for name in ("TRAYNOOK_RELEASE_VERSION", "TRAYNOOK_VERSION", "TRAYNOOK_BUILD", "TRAYNOOK_NOTARY_KEYCHAIN"):
            environment.pop(name, None)
        environment.update(PATH=f"{tools}:{environment['PATH']}", TRAYNOOK_TEST_NOTARY_ARGUMENTS=str(root / "notary-arguments"))
        if release_version is not None:
            environment["TRAYNOOK_RELEASE_VERSION"] = release_version
            environment["TRAYNOOK_NOTARY_KEYCHAIN"] = str(root / "disposable keychain")
        result = subprocess.run(["/bin/bash", str(release), "fixture-identity", "fixture-profile"], env=environment, capture_output=True, text=True)
        assert result.returncode == expected_status, result.stderr
        archives = sorted(path.name for path in (root / "dist").glob("*.zip*"))
        if expected_status == 0:
            archive = f"TrayNook-{release_version or '1.0.0'}.zip"
            assert archives == [archive, f"{archive}.sha256"], archives
            assert (root / "dist" / f"{archive}.sha256").read_text().strip().endswith(f"  {archive}")
            arguments = (root / "notary-arguments").read_text().splitlines()
            if release_version is not None:
                index = arguments.index("--keychain")
                assert arguments[index + 1] == environment["TRAYNOOK_NOTARY_KEYCHAIN"]
            else:
                assert "--keychain" not in arguments
        else:
            assert not archives
            assert not (root / "notary-arguments").exists()
            assert "marketing version" in result.stderr

print("Release metadata passed: stable/prerelease tags, invalid input, archive names, version mismatch, and optional notarization keychain.")
PY
