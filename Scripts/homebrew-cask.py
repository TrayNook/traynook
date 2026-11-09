#!/usr/bin/env python3
"""Generate TrayNook's stable Homebrew cask from verified release assets."""

import argparse
import hashlib
from pathlib import Path
import re
import tempfile


STABLE_VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


def render_cask(version: str, checksum: str) -> str:
    return f'''cask "traynook" do
  version "{version}"
  sha256 "{checksum}"

  url "https://github.com/TrayNook/traynook/releases/download/v#{{version}}/TrayNook-#{{version}}.zip"
  name "TrayNook"
  desc "Menu bar organizer"
  homepage "https://github.com/TrayNook/traynook"

  auto_updates true
  depends_on macos: :ventura

  app "TrayNook.app"

  uninstall quit: "io.github.mahenzon.TrayNook"

  zap trash: [
    "~/Library/Application Support/io.github.mahenzon.TrayNook",
    "~/Library/Preferences/io.github.mahenzon.TrayNook.plist",
  ]

  caveats <<~EOS
    macOS may require approval in Privacy & Security before the first launch.
    Turn off Launch at Login in TrayNook settings before uninstalling.
  EOS
end
'''


def generate(args: argparse.Namespace) -> None:
    if not re.fullmatch(STABLE_VERSION, args.version):
        raise ValueError("Version must be stable MAJOR.MINOR.PATCH with no leading zeros.")
    archive_name = f"TrayNook-{args.version}.zip"
    if args.archive.name != archive_name:
        raise ValueError(f"Archive must be named {archive_name}.")
    sidecar = args.checksum.read_bytes().decode("ascii")
    match = re.fullmatch(r"([0-9a-f]{64})  " + re.escape(archive_name) + r"\n?", sidecar)
    if match is None:
        raise ValueError(f"Checksum must contain one SHA-256 digest and the filename {archive_name}.")
    checksum = match.group(1)
    digest = hashlib.sha256()
    with args.archive.open("rb") as archive:
        for chunk in iter(lambda: archive.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != checksum:
        raise ValueError("Archive SHA-256 does not match the checksum file.")

    if args.current_cask is not None and args.current_cask.exists():
        current = args.current_cask.read_text(encoding="utf-8")
        current_version = re.search(r'^  version "(' + STABLE_VERSION + r')"$', current, re.MULTILINE)
        current_checksum = re.search(r'^  sha256 "([0-9a-f]{64})"$', current, re.MULTILINE)
        if current_version is None or current_checksum is None:
            raise ValueError("Existing cask must have a stable version and an exact SHA-256.")
        version = tuple(map(int, args.version.split(".")))
        previous = tuple(map(int, current_version.group(1).split(".")))
        if version < previous:
            raise ValueError("Refusing to downgrade the Homebrew cask.")
        if version == previous and checksum != current_checksum.group(1):
            raise ValueError("Refusing to change the archive checksum for an existing version.")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=args.output.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
        try:
            temporary.write(render_cask(args.version, checksum))
            temporary.close()
            temporary_path.replace(args.output)
        finally:
            temporary_path.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--checksum", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--current-cask", type=Path)
    args = parser.parse_args()
    try:
        generate(args)
    except (OSError, UnicodeError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
