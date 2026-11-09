#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

python3 - "$root/Scripts/update-feed.py" <<'PY'
import base64
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

script = Path(sys.argv[1])
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
with tempfile.TemporaryDirectory(prefix="traynook-update-feed-") as directory:
    root = Path(directory)
    helper = root / "crypto.swift"
    helper.write_text('''import CryptoKit
import Foundation
let args = CommandLine.arguments
if args[1] == "generate" {
    let key = Curve25519.Signing.PrivateKey()
    let root = URL(fileURLWithPath: args[2])
    try key.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("private"), atomically: true, encoding: .utf8)
    try key.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("public"), atomically: true, encoding: .utf8)
} else {
    precondition(args[1] == "--ed-key-file" && args[3] == "-p")
    let encoded = try String(contentsOfFile: args[2], encoding: .utf8)
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: encoded)!)
    let archive = ProcessInfo.processInfo.environment["TRAYNOOK_TEST_SIGN_OLD"] ?? args[4]
    print(try key.signature(for: Data(contentsOf: URL(fileURLWithPath: archive))).base64EncodedString())
}
''')
    signer = root / "signer"
    signer.write_text('''#!/bin/bash
if [[ "${TRAYNOOK_TEST_SIGNER_FAIL:-}" == 1 ]]; then
    echo 'fixture-private-key-must-never-be-shown'
    echo 'fixture-private-key-must-never-be-shown' >&2
    exit 1
fi
exec swift -module-cache-path "$TRAYNOOK_TEST_MODULE_CACHE" "$TRAYNOOK_TEST_CRYPTO_HELPER" "$@"
''')
    signer.chmod(0o755)
    environment = os.environ.copy()
    environment.update(TRAYNOOK_TEST_MODULE_CACHE=str(root / "ModuleCache"),
                       TRAYNOOK_TEST_CRYPTO_HELPER=str(helper))
    for name in ("TRAYNOOK_TEST_SIGN_OLD", "TRAYNOOK_TEST_SIGNER_FAIL"):
        environment.pop(name, None)
    subprocess.run(["swift", "-module-cache-path", str(root / "ModuleCache"), str(helper), "generate", str(root)],
                   env=environment, capture_output=True, text=True, check=True)
    (root / "private").chmod(0o600)
    environment.update(TRAYNOOK_UPDATE_PRIVATE_KEY_FILE=str(root / "private"),
                       TRAYNOOK_UPDATE_PUBLIC_KEY=(root / "public").read_text())
    archive = root / "TrayNook-1.2.3.zip"
    archive.write_bytes(b"final notarized and stapled archive fixture")
    notes = root / "CHANGELOG.md"
    notes.write_text('# Release notes\n\nFixed <menus> & "updates"; kept plain text.\n')
    output = root / "appcast.xml"

    def run(*, version="1.2.3", build="42", extra=None, success=True):
        output.unlink(missing_ok=True)
        result = subprocess.run([sys.executable, str(script), str(archive), version, build,
                                 "--signer", str(signer), "--notes", str(notes), "--output", str(output)],
                                env={**environment, **(extra or {})}, capture_output=True, text=True)
        assert (result.returncode == 0) == success, (result.stdout, result.stderr)
        assert output.exists() == success
        assert "fixture-private-key-must-never-be-shown" not in result.stdout + result.stderr
        return result

    digest = hashlib.sha256(archive.read_bytes()).digest()
    run()
    assert hashlib.sha256(archive.read_bytes()).digest() == digest, "Signed archive was modified"
    item = ET.parse(output).find("./channel/item")
    assert item.find(f"{{{namespace}}}version").text == "42"
    assert item.find(f"{{{namespace}}}shortVersionString").text == "1.2.3"
    assert item.find(f"{{{namespace}}}minimumSystemVersion").text == "13.0"
    assert item.find("description").text == notes.read_text().strip()
    assert item.find("description").get(f"{{{namespace}}}format") == "plain-text"
    enclosure = item.find("enclosure").attrib
    assert enclosure["url"] == "https://github.com/TrayNook/traynook/releases/download/v1.2.3/TrayNook-1.2.3.zip"
    assert enclosure["length"] == str(archive.stat().st_size)
    assert enclosure[f"{{{namespace}}}version"] == "42"
    assert len(base64.b64decode(enclosure[f"{{{namespace}}}edSignature"], validate=True)) == 64
    old = root / "original.zip"
    old.write_bytes(archive.read_bytes())
    archive.write_bytes(b"tampered archive")
    run(extra={"TRAYNOOK_TEST_SIGN_OLD": str(old)}, success=False)
    run(extra={"TRAYNOOK_UPDATE_PUBLIC_KEY": base64.b64encode(bytes(32)).decode()}, success=False)
    run(extra={"TRAYNOOK_TEST_SIGNER_FAIL": "1"}, success=False)
    run(extra={"TRAYNOOK_UPDATE_PRIVATE_KEY_FILE": ""}, success=False)
    run(extra={"TRAYNOOK_UPDATE_PUBLIC_KEY": "invalid"}, success=False)
    for version in ("1.2.3-beta.1", "01.2.3", "1.2.3/escape"):
        run(version=version, success=False)
    for build in ("0", "01", "not-a-build"):
        run(build=build, success=False)
    archive.write_bytes(b"")
    run(success=False)

print("Update feed passed: Ed25519 verification, XML metadata/escaping, stable-only URLs, tampering, key mismatch, and private diagnostic suppression.")
PY
