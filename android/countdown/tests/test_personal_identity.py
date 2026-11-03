"""Identity persistence and actual native/manifest relocation contracts; no device."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from personal_identity import (LEGACY_PACKAGE, PROVIDER_PACKAGE, resolve_identity,
                               load_package, patch_native_path, native_hash,
                               relocate_manifest, relocate_smali, validate_package, certificate_sha1)


class PersonalIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def key(self):
        path = self.root / '.local/debug.keystore'
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(b'test fixture only, not a signing key')
        return path

    def report(self, package):
        output = self.root / 'output'
        output.mkdir(exist_ok=True)
        (output/'Application-info.txt').write_text('Package: '+package+'\nSHA1: fixture\n','utf8')
        (output/'build-result.json').write_text(json.dumps({'package':package}),'utf8')

    def test_new_folders_differ_and_rebuild_keeps_identity(self):
        one = resolve_identity(self.root)
        other = self.root/'another'; other.mkdir()
        two = resolve_identity(other)
        self.assertNotEqual(one, two)
        self.assertEqual(len(one), 21)
        self.assertNotEqual(one, LEGACY_PACKAGE)
        self.assertEqual(one, resolve_identity(self.root))
        self.key()
        self.assertEqual(one, resolve_identity(self.root))
        self.assertEqual(one, load_package(self.root))

    def test_custom_package_persists_and_conflict_does_not_overwrite(self):
        package = resolve_identity(self.root, 'com.test.rider')
        before = (self.root/'personal.properties').read_bytes()
        self.assertEqual(package, 'com.test.rider')
        with self.assertRaises(ValueError):
            resolve_identity(self.root, 'com.test.other')
        self.assertEqual(before, (self.root/'personal.properties').read_bytes())

    def test_old_fixed_build_keeps_package_and_key(self):
        key = self.key(); before = key.read_bytes()
        self.assertEqual(resolve_identity(self.root), LEGACY_PACKAGE)
        self.assertEqual(before, key.read_bytes())

    def test_previous_report_recovers_identity(self):
        self.key(); self.report('com.test.previous')
        self.assertEqual(resolve_identity(self.root), 'com.test.previous')

    def test_missing_established_key_stops(self):
        package = resolve_identity(self.root)
        key = self.key(); resolve_identity(self.root); key.unlink()
        with self.assertRaisesRegex(ValueError, 'Signing key is missing'):
            resolve_identity(self.root)
        self.assertEqual(package, load_package(self.root))

    def test_missing_key_with_existing_reports_stops(self):
        self.report(LEGACY_PACKAGE)
        with self.assertRaisesRegex(ValueError, 'signing key missing'):
            resolve_identity(self.root)
        self.assertFalse((self.root/'personal.properties').exists())

    def test_conflicting_reports_stop(self):
        self.key(); self.report(LEGACY_PACKAGE)
        (self.root/'output/build-result.json').write_text('{"package":"com.test.other"}', 'utf8')
        with self.assertRaisesRegex(ValueError, 'disagree'):
            resolve_identity(self.root)

    def test_saved_identity_does_not_silently_replace_previous_package(self):
        resolve_identity(self.root, 'com.test.first')
        self.key(); self.report('com.test.second')
        with self.assertRaisesRegex(ValueError, 'differs'):
            resolve_identity(self.root)

    def test_invalid_and_overlong_packages_rejected(self):
        for package in ('', 'single', 'com.1bad', 'com.bad-name', 'com.中文',
                        'com.autonavi.amapauto', 'com.autonavi.minimap',
                        'com.motonav.u'+'a'*32, 'com.test.abc\n'):
            with self.subTest(package=package), self.assertRaises(ValueError):
                validate_package(package)

    def test_native_path_keeps_binary_offsets_and_terminates_short_names(self):
        old = ('/data/data/'+PROVIDER_PACKAGE).encode()+b'\0'
        data = b'ELF_PREFIX\0'+old+b'NEXT_STRING\0TAIL'
        for package in ('com.mn.u0123456789abc', 'com.a.b', LEGACY_PACKAGE):
            patched = patch_native_path(data, package)
            self.assertEqual(len(data), len(patched))
            self.assertEqual(data.index(b'NEXT_STRING'), patched.index(b'NEXT_STRING'))
            self.assertIn(('/data/data/'+package).encode()+b'\0', patched)
            self.assertNotIn(old, patched)
            self.assertEqual(native_hash(data, package), hashlib.sha256(patched).hexdigest())

    def test_unknown_or_duplicate_native_paths_rejected(self):
        old = ('/data/data/'+PROVIDER_PACKAGE).encode()
        for data in (old, old+b'/suffix\0', (old+b'\0')*2, b'unknown'):
            with self.subTest(data=data), self.assertRaises(ValueError):
                patch_native_path(data, 'com.test.new')

    def test_certificate_output_accepts_windows_and_unix_newlines(self):
        sha1 = 'ABCDEF0123' * 4
        for newline in ('\n', '\r\n'):
            report = 'Signer #1 certificate SHA-1 digest: ' + sha1 + newline + 'Other information' + newline
            self.assertEqual(certificate_sha1(report, sha1.lower()), sha1.lower())

    def test_missing_or_replaced_certificate_is_rejected(self):
        with self.assertRaises(ValueError):
            certificate_sha1('Signer #1 certificate SHA-1 digest: bad\r\n')
        with self.assertRaisesRegex(ValueError, 'changed'):
            certificate_sha1('Signer #1 certificate SHA-1 digest: '+'a'*40+'\r\n', 'b'*40)

    def test_manifest_relocates_authorities_permissions_and_tasks_only(self):
        android = '{http://schemas.android.com/apk/res/android}'
        tree = ET.fromstring('''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.autonavi.amapauto">
          <permission android:name="com.motonav.app.fresh.permission.CAR_GUIDANCE"/>
          <uses-permission android:name="com.autonavi.amapauto.PERMISSION"/>
          <uses-permission android:name="android.permission.INTERNET"/>
          <application android:name="com.autonavi.amapauto.AutoApplication">
            <activity android:name="com.autonavi.amapauto.MainMapActivity" android:taskAffinity="com.autonavi.amapauto.motonav"/>
            <provider android:name="com.autonavi.amapauto.provider.Test" android:authorities="com.autonavi.amapauto.provider.Test" android:readPermission="com.autonavi.amapauto.PERMISSION"/>
          </application></manifest>''')
        relocate_manifest(tree, 'com.test.new')
        self.assertEqual(tree.get('package'), 'com.test.new')
        self.assertEqual(tree.find('permission').get(android+'name'), 'com.test.new.permission.CAR_GUIDANCE')
        self.assertEqual(tree.find('application').get(android+'name'), 'com.autonavi.amapauto.AutoApplication')
        activity = tree.find('application/activity')
        self.assertEqual(activity.get(android+'name'), 'com.autonavi.amapauto.MainMapActivity')
        self.assertEqual(activity.get(android+'taskAffinity'), 'com.test.new.motonav')
        provider = tree.find('application/provider')
        self.assertEqual(provider.get(android+'authorities'), 'com.test.new.provider.Test')
        self.assertEqual(provider.get(android+'readPermission'), 'com.test.new.PERMISSION')
        self.assertEqual(tree.findall('uses-permission')[1].get(android+'name'), 'android.permission.INTERNET')

    def test_smali_keeps_implementation_and_jni_class_names(self):
        text = '''Lcom/autonavi/amapauto/MainMapActivity;
"com.autonavi.amapauto"
"com.autonavi.amapauto.provider.Test"
"content://com.autonavi.amapauto.provider.Test"
"com.autonavi.amapauto.MainMapActivity"'''
        value = relocate_smali(text, 'com.test.new')
        self.assertIn('Lcom/autonavi/amapauto/MainMapActivity;', value)
        self.assertIn('"com.autonavi.amapauto.MainMapActivity"', value)
        self.assertIn('"com.test.new"', value)
        self.assertIn('"com.test.new.provider.Test"', value)
        self.assertIn('"content://com.test.new.provider.Test"', value)


if __name__ == '__main__':
    unittest.main(verbosity=2)
