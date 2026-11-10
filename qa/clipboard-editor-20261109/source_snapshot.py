#!/usr/bin/env python3
"""Record/verify source inputs for local QA candidates; never include ignored data."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def current() -> dict:
    paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', 'app']).split(b'\0')
    files = {
        str(path): sha(path.read_bytes())
        for name in sorted(set(paths)) if name
        for path in [Path(name.decode())] if path.is_file()
    }
    production = {name: value for name, value in files.items() if not name.startswith(('app/test/', 'app/integration_test/', 'app/android/app/src/androidTest/', 'app/android/app/src/test/'))}
    return {
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'branch': subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip(),
        'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        'tracked_diff_sha256': sha(subprocess.check_output(['git', 'diff', '--binary', '--no-ext-diff'])),
        'source_manifest_sha256': sha(json.dumps(files, sort_keys=True).encode()),
        'production_manifest_sha256': sha(json.dumps(production, sort_keys=True).encode()),
        'source_files': files,
        'production_files': production,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['snapshot', 'verify'])
    parser.add_argument('path', type=Path)
    parser.add_argument('--archive', action='store_true')
    args = parser.parse_args()
    data = current()
    if args.operation == 'verify':
        saved = json.loads(args.path.read_text())
        changed = sorted(name for name in set(saved['source_files']) | set(data['source_files']) if saved['source_files'].get(name) != data['source_files'].get(name))
        print(json.dumps({'matched': not changed, 'changed_paths': changed, 'source_manifest_sha256': data['source_manifest_sha256'], 'production_manifest_sha256': data['production_manifest_sha256']}))
        raise SystemExit(bool(changed))
    with args.path.open('x') as output:
        json.dump(data, output, indent=2)
        output.write('\n')
    if args.archive:
        archive = args.path.with_suffix('.tar.gz')
        assert not archive.exists(), 'Do not replace an existing source archive'
        with tarfile.open(archive, 'w:gz') as output:
            for name in data['source_files']:
                output.add(name, arcname=name, recursive=False)
        print(json.dumps({'archive': str(archive), 'bytes': archive.stat().st_size, 'sha256': sha(archive.read_bytes())}))
    print(json.dumps({key: value for key, value in data.items() if not isinstance(value, dict)}))
    print(json.dumps({'source_file_count': len(data['source_files']), 'production_file_count': len(data['production_files'])}))


if __name__ == '__main__':
    main()
