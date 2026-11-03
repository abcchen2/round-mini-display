"""Persistent local identity shared by the complete countdown build stages."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import secrets

ROOT = Path(__file__).resolve().parent
LEGACY_PACKAGE = 'com.motonav.app.fresh'
PROVIDER_PACKAGE = 'com.autonavi.amapauto'
MAX_PACKAGE_LENGTH = len(PROVIDER_PACKAGE)


def validate_package(value):
    # libhsl contains an in-place native data-directory string. Never grow it,
    # truncate the requested package, or rename JNI implementation classes.
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+', value):
        raise ValueError('Invalid Android package name: ' + value)
    if len(value) > MAX_PACKAGE_LENGTH:
        raise ValueError('Countdown package must be at most 21 ASCII characters (native path limit).')
    if value in (PROVIDER_PACKAGE, 'com.autonavi.minimap'):
        raise ValueError('Do not use an official AMap package name.')
    return value


def read_properties(path):
    result = {}
    if path.exists():
        for line in path.read_text('utf-8-sig').splitlines():
            line = line.strip()
            if not line or line.startswith(('#', '!')):
                continue
            key, sep, value = line.partition('=')
            if not sep or key.strip() in result:
                raise ValueError('Invalid or duplicate local identity property: ' + str(path))
            result[key.strip()] = value.strip()
    return result


def save_properties(path, values):
    path.write_text(''.join(f'{k}={v}\n' for k, v in values.items()), 'utf8')


def recorded_package(root):
    found = set()
    report = root / 'output/build-result.json'
    if report.exists():
        value = json.loads(report.read_text('utf-8-sig')).get('package')
        if not value:
            raise ValueError('Existing build-result.json has no package; restore the identity backup.')
        found.add(validate_package(value))
    info = root / 'output/Application-info.txt'
    if info.exists():
        match = re.search(r'^Package:\s*(\S+)\s*$', info.read_text('utf-8-sig'), re.M)
        if not match:
            raise ValueError('Existing Application-info.txt has no package; restore the identity backup.')
        found.add(validate_package(match[1]))
    if len(found) > 1:
        raise ValueError('Existing build reports disagree about the package; restore the correct backup.')
    return next(iter(found), None)


def resolve_identity(root=ROOT, requested=None):
    root = Path(root)
    requested = validate_package(requested) if requested else None
    path = root / 'personal.properties'
    key = root / '.local/debug.keystore'
    props = read_properties(path)
    previous = recorded_package(root)
    if path.exists():
        package = validate_package(props.get('personalApplicationId', ''))
        if previous and previous != package:
            raise ValueError('Saved identity differs from the previous APK. Restore the matching backup.')
        if props.get('signingEstablished') == 'true' and not key.is_file():
            raise ValueError('Signing key is missing. Restore .local/debug.keystore; do not generate a replacement.')
    else:
        if previous and not key.is_file():
            raise ValueError('Previous APK found but signing key missing. Restore .local/debug.keystore.')
        # Old builds had a fixed package and no personal.properties. Retain that
        # identity when their local signing key is present, including after clean.
        package = previous or (LEGACY_PACKAGE if key.is_file() else requested)
        package = package or ('com.mn.u' + secrets.token_hex(7)[:13])
        props = {'personalApplicationId': validate_package(package),
                 'signingEstablished': 'true' if key.is_file() else 'false'}
    if requested and requested != package:
        raise ValueError('Package already saved as ' + package + '. Use a separate clean source folder for another app.')
    if key.is_file():
        props['signingEstablished'] = 'true'
    save_properties(path, props)
    return package


def load_package(root=ROOT):
    props = read_properties(Path(root) / 'personal.properties')
    return validate_package(props.get('personalApplicationId', ''))


def patch_native_path(data, package):
    package = validate_package(package)
    old = ('/data/data/' + PROVIDER_PACKAGE).encode('ascii')
    needle = old + b'\0'
    if data.count(needle) != 1:
        raise ValueError('Unsupported libhsl data-directory string; expected one terminated path.')
    new = ('/data/data/' + package).encode('ascii')
    return data.replace(needle, new + b'\0' * (len(needle) - len(new)))


def native_hash(data, package):
    return hashlib.sha256(patch_native_path(data, package)).hexdigest()


def certificate_sha1(report, expected=None):
    match = re.search(r'^Signer #1 certificate SHA-1 digest: ([0-9a-fA-F]{40})[ \t\r]*$', report, re.M)
    if not match:
        raise ValueError('Final APK certificate SHA1 is missing.')
    value = match[1].lower()
    if expected and expected.lower() != value:
        raise ValueError('Signing certificate changed. Restore the previous .local/debug.keystore.')
    return value


def relocate_smali(text, package):
    package = validate_package(package)
    return (text.replace('"' + PROVIDER_PACKAGE + '"', '"' + package + '"')
            .replace('"' + PROVIDER_PACKAGE + '.provider.', '"' + package + '.provider.')
            .replace('"content://' + PROVIDER_PACKAGE + '.provider.', '"content://' + package + '.provider.'))


def relocate_manifest(tree, package):
    package = validate_package(package)
    android = '{http://schemas.android.com/apk/res/android}'
    tree.set('package', package)
    for node in tree.iter():
        for attr, value in list(node.attrib.items()):
            if attr in [android + x for x in ('authorities', 'permission', 'readPermission', 'writePermission', 'taskAffinity')] or (
                    node.tag in ('permission', 'uses-permission') and attr == android + 'name'):
                for prefix in (PROVIDER_PACKAGE, LEGACY_PACKAGE):
                    if value == prefix or value.startswith(prefix + '.'):
                        value = package + value[len(prefix):]
                if value == 'com.yuminaga.motonav.permission.CAR_GUIDANCE':
                    value = package + '.permission.CAR_GUIDANCE'
                node.set(attr, value)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--application-id', help='Optional first-build package, maximum 21 characters.')
    args = parser.parse_args()
    try:
        print('Package: ' + resolve_identity(requested=args.application_id))
    except (ValueError, OSError) as error:
        parser.error(str(error))
