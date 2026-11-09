#!/usr/bin/env python3
"""Sign the final stable release archive and write its Sparkle appcast."""

import argparse
import base64
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERIFY_SIGNATURE = """
import CryptoKit
import Foundation
let arguments = CommandLine.arguments
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: arguments[2])!)
let signature = Data(base64Encoded: arguments[3])!
guard publicKey.isValidSignature(signature, for: archive) else { exit(1) }
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("version")
    parser.add_argument("build")
    parser.add_argument("--signer", type=Path, required=True)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", args.version):
        parser.error("The update feed requires a stable MAJOR.MINOR.PATCH version.")
    if not re.fullmatch(r"[1-9][0-9]*", args.build):
        parser.error("The update feed requires a positive numeric build.")
    if args.archive.name != f"TrayNook-{args.version}.zip" or not args.archive.is_file() or args.archive.stat().st_size == 0:
        parser.error("Expected a nonempty final TrayNook-VERSION.zip archive.")
    if args.output.resolve() in (args.archive.resolve(), args.notes.resolve()):
        parser.error("The appcast output must not replace the archive or release notes.")
    public_key = os.environ.get("TRAYNOOK_UPDATE_PUBLIC_KEY", "")
    try:
        if len(base64.b64decode(public_key, validate=True)) != 32:
            raise ValueError
    except ValueError:
        parser.error("TRAYNOOK_UPDATE_PUBLIC_KEY must encode a 32-byte Ed25519 public key.")
    private_key_file = os.environ.get("TRAYNOOK_UPDATE_PRIVATE_KEY_FILE", "")
    if not private_key_file or not Path(private_key_file).is_file():
        parser.error("TRAYNOOK_UPDATE_PRIVATE_KEY_FILE must reference an exported Sparkle private key file.")
    notes = args.notes.read_text(encoding="utf-8").strip()
    if not notes:
        parser.error("Release notes must not be empty.")

    # Sparkle can echo malformed private key data on failure; keep all signer diagnostics private.
    signed = subprocess.run([str(args.signer), "--ed-key-file", private_key_file, "-p", str(args.archive)],
                            capture_output=True, text=True)
    if signed.returncode != 0:
        sys.exit("Sparkle archive signing failed. Check the private key file and signer locally.")
    signature = signed.stdout.strip()
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError
    except ValueError:
        sys.exit("Sparkle returned an invalid archive signature.")
    # Verify against the public key embedded in the app, so mismatched release credentials fail here.
    with tempfile.TemporaryDirectory(prefix="traynook-signature-") as directory:
        verified = subprocess.run(["swift", "-module-cache-path", str(Path(directory) / "ModuleCache"),
                                   "-e", VERIFY_SIGNATURE, str(args.archive), public_key, signature],
                                  capture_output=True, text=True)
    if verified.returncode != 0:
        sys.exit("The archive signature does not verify with TRAYNOOK_UPDATE_PUBLIC_KEY.")

    ET.register_namespace("sparkle", SPARKLE)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "TrayNook Updates"
    ET.SubElement(channel, "link").text = "https://github.com/TrayNook/traynook/releases"
    ET.SubElement(channel, "description").text = "Stable TrayNook releases"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"TrayNook {args.version}"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = args.build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "13.0"
    ET.SubElement(item, "description", {f"{{{SPARKLE}}}format": "plain-text"}).text = notes
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/TrayNook/traynook/releases/download/v{args.version}/{args.archive.name}",
        "length": str(args.archive.stat().st_size),
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}version": args.build,
        f"{{{SPARKLE}}}shortVersionString": args.version,
        f"{{{SPARKLE}}}edSignature": signature,
    })
    ET.indent(rss)
    ET.ElementTree(rss).write(args.output, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError):
        sys.exit("The update feed could not be created. Check the archive, notes, signer, and output paths.")
