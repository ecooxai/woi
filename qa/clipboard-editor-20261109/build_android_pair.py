#!/usr/bin/env python3
"""Build one frozen main/AndroidTest release pair; never install or change a phone."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('label')
    args = parser.parse_args()
    if not re.fullmatch(r'candidate[0-9]+(?:-[a-z0-9]+)*', args.label):
        raise SystemExit('Use a unique safe candidate label')
    base = Path('qa/clipboard-editor-20261109')
    snapshot = base / f'{args.label}-source-snapshot.json'
    output = base / f'{args.label}-android-matched-pair.json'
    release_log = base / f'{args.label}-android-build.log'
    test_log = base / f'{args.label}-android-test-build.log'
    destinations = {
        'main': base / f'android-{args.label}.apk',
        'test': base / f'android-{args.label}-test.apk',
        'main_r8_mapping': base / f'android-{args.label}-main-r8-mapping.txt',
        'test_r8_mapping': base / f'android-{args.label}-test-r8-mapping.txt',
    }
    for path in [output, release_log, test_log, *destinations.values()]:
        if path.exists() or path.is_symlink():
            raise SystemExit(f'Refusing to replace existing artifact: {path}')
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
    flutter = Path(properties['flutter.sdk']) / 'bin/flutter'
    release_command = [str(flutter), 'build', 'apk', '--release', '--flavor', 'arm64', '--target-platform', 'android-arm64']
    test_command = ['./gradlew', '-PwoiTestBuildType=release', '-Ptarget-platform=android-arm64', ':app:assembleArm64ReleaseAndroidTest']
    builds = {'release': {'started_utc': now(), 'command': release_command}, 'release_log': str(release_log), 'test_log': str(test_log)}
    with release_log.open('x') as log:
        release = subprocess.run(release_command, cwd='app', stdout=log, stderr=subprocess.STDOUT)
    builds['release'].update(exit_code=release.returncode, finished_utc=now())
    sources = {
        'main': Path('app/build/app/outputs/flutter-apk/app-arm64-release.apk'),
        'test': Path('app/build/app/outputs/apk/androidTest/arm64/release/app-arm64-release-androidTest.apk'),
        'main_r8_mapping': Path('app/build/app/outputs/mapping/arm64Release/mapping.txt'),
        'test_r8_mapping': Path('app/build/app/outputs/mapping/arm64ReleaseAndroidTest/mapping.txt'),
    }
    gradle_main = Path('app/build/app/outputs/apk/arm64/release/app-arm64-release.apk')
    main_before = None
    mapping_before = None
    test_code = None
    if release.returncode == 0:
        main_before = digest(sources['main'])
        mapping_before = digest(sources['main_r8_mapping'])
        builds['release']['main_apk_sha256_before_test_build'] = main_before
        builds['release']['main_r8_mapping_sha256_before_test_build'] = mapping_before
        # No pub, Flutter test/analyze, or other registrant mutation between these builds.
        builds['test'] = {'started_utc': now(), 'command': test_command}
        with test_log.open('x') as log:
            test = subprocess.run(test_command, cwd='app/android', stdout=log, stderr=subprocess.STDOUT)
        test_code = test.returncode
        builds['test'].update(exit_code=test_code, finished_utc=now())
    after = verify()
    matched = release.returncode == 0 and test_code == 0 and after['matched']
    main_unchanged = main_before is not None and digest(sources['main']) == main_before
    main_matches = main_unchanged and digest(gradle_main) == main_before
    mapping_unchanged = mapping_before is not None and digest(sources['main_r8_mapping']) == mapping_before
    result = {'created_utc': now(), 'source_manifest_path': str(snapshot),
              'source_manifest_sha256': expected['source_manifest_sha256'],
              'production_manifest_sha256': expected['production_manifest_sha256'],
              'source_verification': after, 'main_unchanged_during_android_test_build': main_unchanged,
              'flutter_main_matches_gradle_main': main_matches, 'main_mapping_unchanged_during_android_test_build': mapping_unchanged, 'builds': builds,
              'physical_device_validation': 'Not installed or run; MI8 ADB transport unavailable. Candidate2 is the last verified installation.',
              'promotion': 'Not performed by this build helper.'}
    if matched and main_unchanged and main_matches and mapping_unchanged:
        artifacts = {}
        for key, source in sources.items():
            target = destinations[key]
            with source.open('rb') as src, target.open('xb') as dst:
                shutil.copyfileobj(src, dst)
            target.chmod(target.stat().st_mode & ~0o222)
            if digest(source) != digest(target):
                raise RuntimeError(f'Copied artifact hash mismatch: {target}')
            artifacts[key] = {'path': str(target), 'sha256': digest(target), 'bytes': target.stat().st_size}
        result['artifacts'] = artifacts
        result['matched_pair'] = True
    else:
        result['matched_pair'] = False
    with output.open('x') as out:
        json.dump(result, out, indent=2); out.write('\n')
    print(json.dumps(result))
    raise SystemExit(0 if result['matched_pair'] else (release.returncode or test_code or 2))


if __name__ == '__main__':
    main()
