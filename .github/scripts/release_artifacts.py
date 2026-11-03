#!/usr/bin/env python3
"""Validate a release snapshot and assemble only its four desktop packages."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

PACKAGES = {
    'Sim-Bridge-macOS-arm64': 'Sim-Bridge-macOS-arm64.zip',
    'Sim-Bridge-macOS-x86_64': 'Sim-Bridge-macOS-x86_64.zip',
    'Sim-Bridge-windows-x64': 'Sim-Bridge-windows-x64.zip',
    'Sim-Bridge-linux-x64': 'Sim-Bridge-linux-x64.zip',
}
# Published asset names, versioned per release: Sim-Bridge-<version>-<platform>.zip.
# The homepage and the renner.dev launcher select downloads by these names.
PUBLISHED = {
    'Sim-Bridge-macOS-arm64': 'macos-arm64.zip',
    'Sim-Bridge-macOS-x86_64': 'macos-x86_64.zip',
    'Sim-Bridge-windows-x64': 'windows-x64.zip',
    'Sim-Bridge-linux-x64': 'linux-x64.zip',
}
SHA_PATTERN = re.compile(r'[0-9a-f]{40}(?:[0-9a-f]{24})?')
TAG_PATTERN = re.compile(
    r'v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
)


def validate_tag(tag):
    match = TAG_PATTERN.fullmatch(tag)
    if not match:
        raise ValueError('Tag must be vMAJOR.MINOR.PATCH, optionally with a SemVer prerelease.')
    if match.group(1):
        for identifier in match.group(1).split('.'):
            if identifier.isdigit() and len(identifier) > 1 and identifier.startswith('0'):
                raise ValueError('Numeric prerelease identifiers cannot have leading zeros.')


def validate_sha(sha):
    if not SHA_PATTERN.fullmatch(sha):
        raise ValueError('Source must be an immutable commit SHA.')


def validate_version(args):
    validate_tag(args.tag)
    validate_sha(args.source_sha)
    versions = re.findall(
        r'^version:\s*([\'"]?)([^\s\'"]+)\1(?:\s+#.*)?\s*$',
        Path(args.pubspec).read_text(),
        re.MULTILINE,
    )
    if len(versions) != 1:
        raise ValueError('Expected exactly one top-level pubspec version.')
    version = versions[0][1].split('+', 1)[0]
    if args.tag != f'v{version}':
        raise ValueError(f'Tag {args.tag} does not match app version {version}.')
    if args.github_output:
        with Path(args.github_output).open('a') as output:
            output.write(f'tag={args.tag}\nsource_sha={args.source_sha}\n')
    print(f'Validated {args.tag} against app version at {args.source_sha}.')


def api_json(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def verify_remote_tag(args):
    validate_tag(args.tag)
    validate_sha(args.source_sha)
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository):
        raise ValueError('Expected GitHub owner/repository.')
    base = f'repos/{args.repository}/git'
    target = api_json(f'{base}/ref/tags/{args.tag}')['object']
    seen = set()
    # Peel annotated tags, including nested tag objects, without trusting a
    # movable branch name or the newest artifact from another workflow run.
    while target['type'] == 'tag':
        validate_sha(target['sha'])
        if target['sha'] in seen or len(seen) >= 16:
            raise ValueError('Tag object chain is cyclic or unexpectedly deep.')
        seen.add(target['sha'])
        target = api_json(f"{base}/tags/{target['sha']}")['object']
    if target['type'] != 'commit' or target['sha'] != args.source_sha:
        raise ValueError('Remote tag moved or does not identify the built source commit.')
    print(f'Remote tag {args.tag} still identifies {args.source_sha}.')


def assemble(args):
    validate_tag(args.tag)
    validate_sha(args.source_sha)
    artifacts = Path(args.artifacts)
    actual_artifacts = {item.name for item in artifacts.iterdir()}
    if actual_artifacts != set(PACKAGES):
        raise ValueError('Expected exactly the four desktop artifacts from this workflow run.')

    checked = []
    for artifact, filename in PACKAGES.items():
        directory = artifacts / artifact
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError(f'Invalid artifact directory: {artifact}')
        if {item.name for item in directory.iterdir()} != {filename, f'{filename}.sha256'}:
            raise ValueError(f'{artifact} must contain only its package and checksum.')
        package = directory / filename
        checksum_file = directory / f'{filename}.sha256'
        if package.is_symlink() or checksum_file.is_symlink():
            raise ValueError(f'Symlinks are not release files: {artifact}')
        if not package.is_file() or not checksum_file.is_file() or package.stat().st_size == 0:
            raise ValueError(f'Missing or empty release package: {artifact}')
        checksum = re.fullmatch(
            r'([0-9a-fA-F]{64})[ \t]+\*?' + re.escape(filename),
            checksum_file.read_text().strip(),
        )
        if checksum is None:
            raise ValueError(f'Invalid checksum format or filename: {artifact}')
        hasher = hashlib.sha256()
        with package.open('rb') as content:
            for chunk in iter(lambda: content.read(1024 * 1024), b''):
                hasher.update(chunk)
        digest = hasher.hexdigest()
        if digest != checksum.group(1).lower():
            raise ValueError(f'Checksum mismatch: {filename}')
        checked.append((package, checksum_file, digest))

    # Validate every input before creating the upload set. Refuse a preexisting
    # output directory so a rerun cannot accidentally attach leftover files.
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    version = args.tag[1:]
    published = []
    for artifact, (package, _, digest) in zip(PACKAGES, checked):
        name = f'Sim-Bridge-{version}-{PUBLISHED[artifact]}'
        shutil.copy2(package, output / name)
        published.append((name, digest))
    (output / 'SHA256SUMS.txt').write_text(''.join(
        f'{digest}  {name}\n' for name, digest in sorted(published)
    ))
    Path(args.notes).write_text(f'''Sim Bridge {args.tag} desktop development packages.

Built from tag `{args.tag}` at immutable source commit `{args.source_sha}`. All four desktop
builds, app analysis/unit/widget checks, the isolated relay suite, offline draft-data/notice
checks, and the documentation build passed before this draft was created. Packages and checksums come from this tag's workflow run.

- macOS arm64 and Intel: zipped app bundles built in CI with an ad-hoc signature. Replace them
  with Developer ID signed, notarized builds before publishing.
- Windows x64: unsigned portable zip with the executable, DLLs and Flutter data.
- Linux x64: unsigned portable zip with the executable and all bundled resources.

These packages are not store-ready releases. Native device behavior, installers, production
signing, and notarization require separate verification. Download the package for your system
and its SHA-256 checksum, or use the combined `SHA256SUMS` file. Keep Windows/Linux bundles
intact after extraction. Desktop clients require a relay and an Android SIM gateway; carrier
audio remains on Android.

This release is intentionally a **draft**. Review the packages and release notes before any
manual publication. This workflow does not publish a public release or upload to app stores.
''')
    print('Verified four packages; prepared four versioned packages and SHA256SUMS.txt.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest='command', required=True)
    version = subcommands.add_parser('validate-tag')
    version.add_argument('--pubspec', required=True)
    version.add_argument('--github-output', default=os.environ.get('GITHUB_OUTPUT'))
    version.set_defaults(handler=validate_version)
    remote = subcommands.add_parser('verify-remote-tag')
    remote.add_argument('--repository', required=True)
    remote.set_defaults(handler=verify_remote_tag)
    assets = subcommands.add_parser('assemble')
    assets.add_argument('--artifacts', required=True)
    assets.add_argument('--output', required=True)
    assets.add_argument('--notes', required=True)
    assets.set_defaults(handler=assemble)
    for command in (version, remote, assets):
        command.add_argument('--tag', required=True)
        command.add_argument('--source-sha', required=True)
    args = parser.parse_args()
    try:
        args.handler(args)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Release validation failed: {error}\n')


if __name__ == '__main__':
    main()
