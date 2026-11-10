#!/usr/bin/env python3
"""Run the one authorized final Flutter suite against an existing source freeze."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('label')
    args = parser.parse_args()
    if not re.fullmatch(r'candidate[0-9]+(?:-[a-z0-9]+)*', args.label):
        raise SystemExit('Use a unique safe candidate label')
    base = Path('qa/clipboard-editor-20261109')
    snapshot = base / f'{args.label}-source-snapshot.json'
    log = base / f'{args.label}-full-suite.log'
    output = base / f'{args.label}-full-suite-result.json'
    for path in [log, output]:
        if path.exists() or path.is_symlink():
            raise SystemExit(f'Refusing to replace an existing gate: {path}')
    expected = json.loads(snapshot.read_text())
    spec = importlib.util.spec_from_file_location('woi_source_snapshot', base / 'source_snapshot.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    def verify():
        current = mod.current()
        changed = sorted(name for name in set(expected['source_files']) | set(current['source_files'])
                         if expected['source_files'].get(name) != current['source_files'].get(name))
        return {'matched': not changed, 'changed_paths': changed,
                'source_manifest_sha256': current['source_manifest_sha256'],
                'production_manifest_sha256': current['production_manifest_sha256']}
    before = verify()
    if not before['matched']:
        raise SystemExit(json.dumps(before))
    properties = dict(line.split('=', 1) for line in Path('app/android/local.properties').read_text().splitlines() if '=' in line)
    command = [str(Path(properties['flutter.sdk']) / 'bin/flutter'), 'test', '--reporter', 'expanded']
    started = datetime.now(timezone.utc).isoformat()
    with log.open('x') as stream:
        completed = subprocess.run(command, cwd='app', stdout=stream, stderr=subprocess.STDOUT)
    after = verify()
    lines = log.read_text(errors='replace').splitlines()
    finals = [line for line in lines if 'All tests passed!' in line or 'Some tests failed.' in line]
    final_line = finals[-1] if finals else None
    counts = None
    if final_line:
        matched = re.search(r'\+(\d+)(?:\s+~(\d+))?(?:\s+-(\d+))?', final_line)
        if matched:
            counts = {'passed': int(matched.group(1)), 'skipped': int(matched.group(2) or 0), 'failed': int(matched.group(3) or 0)}
    skipped = []
    skipped_tests = []
    last_test = None
    for line in lines:
        if 'app/test/' in line and '.dart:' in line:
            last_test = line
        if line.strip().startswith('Skip:') or re.search(r'\[(?:skip|skipped)\]|^\s*Skipped:', line, re.IGNORECASE):
            skipped.append(line)
            skipped_tests.append({'reporter_test_line': last_test, 'reason': line.strip()})
    result = {'started_utc': started, 'finished_utc': datetime.now(timezone.utc).isoformat(),
              'exit_code': completed.returncode, 'command': command, 'log': str(log),
              'source_manifest_path': str(snapshot), 'source_manifest_sha256': expected['source_manifest_sha256'],
              'production_manifest_sha256': expected['production_manifest_sha256'],
              'source_verification': after, 'reporter_summary': final_line, 'counts': counts,
              'skipped_reporter_lines': skipped, 'skipped_tests': skipped_tests,
              'scope': 'Full default Flutter test directory suite on this exact frozen app source; no Android device or instrumentation execution.',
              'passed': completed.returncode == 0 and after['matched'] and final_line is not None and 'All tests passed!' in final_line}
    with output.open('x') as stream:
        json.dump(result, stream, indent=2); stream.write('\n')
    print(json.dumps({key: value for key, value in result.items() if key not in ('skipped_reporter_lines', 'skipped_tests')}))
    if not result['passed']:
        print('\n'.join(lines[-40:]))
    raise SystemExit(0 if result['passed'] else (completed.returncode or 2))


if __name__ == '__main__':
    main()
