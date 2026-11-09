#!/usr/bin/env python3
"""Generate TrayNook's latest or versioned Homebrew cask from verified release assets."""

import argparse
import hashlib
from pathlib import Path
import re
import tempfile


STABLE_VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


def render_cask(version: str, checksum: str, *, versioned: bool = False) -> str:
    token = f"traynook@{version}" if versioned else "traynook"
    conflict = "traynook" if versioned else f"traynook@{version}"
    pinned_caveat = "\n    To keep this release, turn off update checks and downloads in TrayNook settings." if versioned else ""
    return f'''cask "{token}" do
  version "{version}"
  sha256 "{checksum}"

  url "https://github.com/TrayNook/traynook/releases/download/v#{{version}}/TrayNook-#{{version}}.zip"
  name "TrayNook"
  desc "Menu bar organizer"
  homepage "https://github.com/TrayNook/traynook"

  auto_updates true
  conflicts_with cask: "{conflict}"
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
    To switch releases, uninstall the installed TrayNook cask first.{pinned_caveat}
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

    rendered = render_cask(args.version, checksum, versioned=args.versioned)
    token = f"traynook@{args.version}" if args.versioned else "traynook"
    existing = [args.current_cask] if args.current_cask is not None else []
    if args.versioned:
        existing.append(args.output)
    for path in existing:
        if not path.exists():
            continue
        current = path.read_bytes().decode("utf-8")
        if not current.startswith(f'cask "{token}" do\n'):
            raise ValueError(f"Existing cask must have the token {token}.")
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
        if args.versioned and current != rendered:
            raise ValueError("Refusing to change an existing versioned cask.")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=args.output.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
        try:
            temporary.write(rendered)
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
    parser.add_argument("--versioned", action="store_true", help="Generate the immutable traynook@VERSION cask.")
    args = parser.parse_args()
    try:
        generate(args)
    except (OSError, UnicodeError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
