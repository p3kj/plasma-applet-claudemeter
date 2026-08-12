#!/usr/bin/env python3
"""Release helpers for the Claude Meter plasmoid.

Stdlib only, no third-party dependencies. Every subcommand works on a
repository root, which defaults to the parent of this script's directory but can
be pointed elsewhere with --root (used to package an old tag from a git
worktree, where tools/ does not exist yet).

Subcommands:
  version                 print the version from metadata.json
  next <patch|minor|major|X.Y.Z>
                          print the next version without writing anything
  bump <version>          write the version into metadata.json
  unreleased              print the "## Unreleased" changelog body (read-only)
  promote <version>       rename "## Unreleased" to "## <version> - <today>"
                          and print the body
  extract <version>       print the body of an existing changelog section
  package <version> <out> build the .plasmoid archive
"""

import argparse
import datetime
import os
import re
import sys
import zipfile
from pathlib import Path

# What goes into the .plasmoid. Directories are added recursively.
PACKAGE_ENTRIES = ["metadata.json", "icon.png", "LICENSE", "contents"]
EXCLUDE_SUFFIXES = ("~", ".swp", ".swo", ".bak", ".orig", ".rej")
EXCLUDE_NAMES = {"__pycache__", ".DS_Store"}

# Fixed timestamp so the archive is byte-for-byte reproducible. zipfile cannot
# represent anything earlier than 1980.
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)

# Anchored on the opening quote so it cannot match "X-Plasma-API-Minimum-Version".
VERSION_RE = re.compile(r'"Version"\s*:\s*"([^"]*)"')
SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
UNRELEASED_RE = re.compile(r"^##\s*\[?\s*unreleased\s*\]?\s*$", re.IGNORECASE)
SECTION_RE = re.compile(r"^##\s")


def die(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


# --- metadata.json -----------------------------------------------------------


def read_version(root):
    path = root / "metadata.json"
    if not path.is_file():
        die(f"{path} not found")
    matches = VERSION_RE.findall(path.read_text(encoding="utf-8"))
    if len(matches) != 1:
        die(
            f'expected exactly one "Version" key in {path}, found {len(matches)}'
        )
    version = matches[0]
    if not SEMVER_RE.match(version):
        die(f'version "{version}" in {path} is not X.Y.Z')
    return version


def next_version(current, spec):
    major, minor, patch = (int(n) for n in SEMVER_RE.match(current).groups())
    if spec == "major":
        new = f"{major + 1}.0.0"
    elif spec == "minor":
        new = f"{major}.{minor + 1}.0"
    elif spec == "patch":
        new = f"{major}.{minor}.{patch + 1}"
    elif SEMVER_RE.match(spec):
        new = spec
    else:
        die(f'"{spec}" is not major, minor, patch or an X.Y.Z version')
    if as_tuple(new) <= as_tuple(current):
        die(f"{new} is not newer than the current version {current}")
    return new


def as_tuple(version):
    return tuple(int(n) for n in version.split("."))


def cmd_version(args):
    print(read_version(args.root))


def cmd_next(args):
    print(next_version(read_version(args.root), args.spec))


def cmd_bump(args):
    if not SEMVER_RE.match(args.version):
        die(f'"{args.version}" is not an X.Y.Z version')
    path = args.root / "metadata.json"
    text = path.read_text(encoding="utf-8")
    new_text, count = VERSION_RE.subn(f'"Version": "{args.version}"', text)
    if count != 1:
        die(f'expected exactly one "Version" key in {path}, replaced {count}')
    path.write_text(new_text, encoding="utf-8")
    print(f"metadata.json -> {args.version}", file=sys.stderr)


# --- CHANGELOG.md ------------------------------------------------------------


def read_changelog(root):
    path = root / "CHANGELOG.md"
    if not path.is_file():
        die(f"{path} not found")
    return path, path.read_text(encoding="utf-8").splitlines()


def section_bounds(lines, start):
    """Return the end index (exclusive) of the section whose heading is at start."""
    end = start + 1
    while end < len(lines) and not SECTION_RE.match(lines[end]):
        end += 1
    return end


def section_body(lines, start, end):
    body = lines[start + 1 : end]
    while body and not body[0].strip():
        body.pop(0)
    while body and not body[-1].strip():
        body.pop()
    return body


def find_unreleased(lines):
    for i, line in enumerate(lines):
        if UNRELEASED_RE.match(line):
            return i
    return None


def require_unreleased(lines, path):
    index = find_unreleased(lines)
    if index is None:
        die(
            f'no "## Unreleased" section in {path}\n'
            '       add one with: just note "what changed"'
        )
    body = section_body(lines, index, section_bounds(lines, index))
    if not body:
        die(
            f'the "## Unreleased" section in {path} is empty\n'
            '       add an entry with: just note "what changed"'
        )
    return index, body


def cmd_unreleased(args):
    path, lines = read_changelog(args.root)
    _, body = require_unreleased(lines, path)
    print("\n".join(body))


def cmd_promote(args):
    path, lines = read_changelog(args.root)
    index, body = require_unreleased(lines, path)
    today = datetime.date.today().isoformat()
    heading = f"## {args.version} - {today}"
    lines[index] = heading
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"CHANGELOG.md -> {heading}", file=sys.stderr)
    print("\n".join(body))


def cmd_extract(args):
    path, lines = read_changelog(args.root)
    pattern = re.compile(r"^##\s+\[?" + re.escape(args.version) + r"\]?(\s|$)")
    for i, line in enumerate(lines):
        if pattern.match(line):
            print("\n".join(section_body(lines, i, section_bounds(lines, i))))
            return
    die(f"no section for version {args.version} in {path}")


def cmd_note(args):
    path, lines = read_changelog(args.root)
    bullet = "- " + args.text.strip()
    index = find_unreleased(lines)
    if index is None:
        # Insert a fresh section right below the "# Changelog" title.
        at = 0
        for i, line in enumerate(lines):
            if line.startswith("# "):
                at = i + 1
                break
        while at < len(lines) and not lines[at].strip():
            at += 1
        lines[at:at] = ["## Unreleased", "", bullet, ""]
    else:
        end = section_bounds(lines, index)
        # Append after the last non-blank line of the section.
        at = end
        while at > index + 1 and not lines[at - 1].strip():
            at -= 1
        prefix = [] if at > index + 1 else [""]
        lines[at:at] = prefix + [bullet]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"CHANGELOG.md: {bullet}", file=sys.stderr)


# --- packaging ---------------------------------------------------------------


def excluded(path):
    if path.name.endswith(EXCLUDE_SUFFIXES):
        return True
    return any(part in EXCLUDE_NAMES for part in path.parts)


def package_members(root):
    """Yield (path, arcname) pairs, directories before their contents."""
    for entry in PACKAGE_ENTRIES:
        path = root / entry
        if not path.exists():
            print(f"warning: {entry} not found, skipping", file=sys.stderr)
            continue
        if path.is_file():
            yield path, entry
            continue
        for child in sorted(path.rglob("*"), key=lambda p: p.as_posix()):
            if excluded(child):
                continue
            yield child, child.relative_to(root).as_posix()
        # The directory entries themselves, so the archive listing matches what
        # the old 7z-based package.sh produced.
        yield path, entry


def cmd_package(args):
    root = args.root
    actual = read_version(root)
    if args.version != actual:
        die(f"metadata.json says {actual}, refusing to package it as {args.version}")

    out = Path(args.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()

    members = sorted(package_members(root), key=lambda m: m[1])
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for path, arcname in members:
            if path.is_dir():
                info = zipfile.ZipInfo(arcname + "/", date_time=ZIP_EPOCH)
                info.external_attr = (0o040755 << 16) | 0x10
                archive.writestr(info, b"")
                continue
            mode = 0o755 if os.access(path, os.X_OK) else 0o644
            info = zipfile.ZipInfo(arcname, date_time=ZIP_EPOCH)
            info.external_attr = (0o100000 | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())

    size = out.stat().st_size
    print(f"{out} ({size // 1024} KiB, {len(members)} entries)", file=sys.stderr)
    print(out)


# --- cli ---------------------------------------------------------------------


def main():
    default_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=default_root,
        help="repository root to operate on (default: %(default)s)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("version").set_defaults(func=cmd_version)

    p = sub.add_parser("next")
    p.add_argument("spec")
    p.set_defaults(func=cmd_next)

    p = sub.add_parser("bump")
    p.add_argument("version")
    p.set_defaults(func=cmd_bump)

    sub.add_parser("unreleased").set_defaults(func=cmd_unreleased)

    p = sub.add_parser("promote")
    p.add_argument("version")
    p.set_defaults(func=cmd_promote)

    p = sub.add_parser("extract")
    p.add_argument("version")
    p.set_defaults(func=cmd_extract)

    p = sub.add_parser("note")
    p.add_argument("text")
    p.set_defaults(func=cmd_note)

    p = sub.add_parser("package")
    p.add_argument("version")
    p.add_argument("out")
    p.set_defaults(func=cmd_package)

    args = parser.parse_args()
    args.root = args.root.resolve()
    if not args.root.is_dir():
        die(f"{args.root} is not a directory")
    args.func(args)


if __name__ == "__main__":
    main()
