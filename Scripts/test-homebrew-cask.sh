#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

python3 - "$root/Scripts/homebrew-cask.py" <<'PY'
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

generator = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="traynook-cask-") as temporary:
    root = Path(temporary)
    output = root / "Casks" / "traynook.rb"

    def assets(version="1.0.0", contents="fixture"):
        archive = root / f"TrayNook-{version}.zip"
        with zipfile.ZipFile(archive, "w") as zipped:
            zipped.writestr("TrayNook.app/Contents/Info.plist", contents)
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        sidecar = root / f"{archive.name}.sha256"
        sidecar.write_text(f"{checksum}  {archive.name}\n")
        return archive, sidecar, checksum

    archive, sidecar, checksum = assets()

    def run(version="1.0.0", archive=archive, sidecar=sidecar, current=None, succeeds=False):
        previous = output.read_bytes() if output.exists() else None
        arguments = [sys.executable, str(generator), "--version", version, "--archive", str(archive),
                     "--checksum", str(sidecar), "--output", str(output)]
        if current is not None:
            arguments.extend(["--current-cask", str(current)])
        result = subprocess.run(arguments, capture_output=True, text=True)
        assert result.returncode == (0 if succeeds else 2), (arguments, result.stderr)
        if not succeeds:
            assert (output.read_bytes() if output.exists() else None) == previous, "Error replaced the existing cask"
        return result

    run(succeeds=True)
    content = output.read_text()
    assert 'version "1.0.0"' in content
    assert f'sha256 "{checksum}"' in content
    assert 'https://github.com/TrayNook/traynook/releases/download/v#{version}/TrayNook-#{version}.zip' in content
    assert 'depends_on macos: :ventura' in content
    assert 'auto_updates true' in content
    assert 'app "TrayNook.app"' in content
    assert 'uninstall quit: "io.github.mahenzon.TrayNook"' in content
    assert 'io.github.mahenzon.TrayNook.dev' not in content
    if shutil.which("ruby"):
        subprocess.run(["ruby", "-c", str(output)], check=True, capture_output=True)

    for version in ["", "v1.0.0", "1.0", "01.0.0", "1.00.0", "1.0.01", "1.0.0-alpha.1",
                    "1.0.0+metadata", "1.0.0\n", "1.0.0/../../escape"]:
        run(version=version)
    run(archive=root / "different.zip")
    run(archive=root / "missing" / archive.name)
    run(sidecar=root / "missing.sha256")

    original_sidecar = sidecar.read_bytes()
    for malformed in [
        f"{'a' * 63}  {archive.name}\n",
        f"{'G' * 64}  {archive.name}\n",
        f"{checksum}  other.zip\n",
        f"{checksum}  ../{archive.name}\n",
        f"{checksum}  {archive.name}\nextra\n",
        f"{'0' * 64}  {archive.name}\n",
    ]:
        sidecar.write_text(malformed)
        run()
    sidecar.write_bytes(b"\xff")
    run()
    sidecar.write_bytes(original_sidecar)

    run(current=output, succeeds=True)
    run(current=root / "not-created.rb", succeeds=True)
    newer_archive, newer_sidecar, _ = assets("1.1.0")
    run(version="1.1.0", archive=newer_archive, sidecar=newer_sidecar, current=output, succeeds=True)
    run(current=output)
    equal_archive, equal_sidecar, _ = assets("1.1.0", contents="changed archive")
    run(version="1.1.0", archive=equal_archive, sidecar=equal_sidecar, current=output)

    malformed_cask = root / "invalid.rb"
    malformed_cask.write_text('cask "traynook" do\n  version :latest\nend\n')
    run(current=malformed_cask)

    # Compare numeric components so 1.10.0 upgrades 1.9.0.
    for version in ["1.9.0", "1.10.0"]:
        next_archive, next_sidecar, _ = assets(version)
        run(version=version, archive=next_archive, sidecar=next_sidecar, current=output, succeeds=True)

print("Homebrew cask passed: verified assets, stable versions, Ruby syntax, upgrades, and error preservation.")
PY
