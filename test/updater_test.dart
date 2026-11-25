import 'package:flutter_test/flutter_test.dart';
import 'package:noxo/update/updater.dart';

Map<String, Object?> release({
  String tag = 'build-12',
  String name = 'noxo-windows.zip',
  String url = 'https://github.com/antoine28boel/noxo/releases/download/build-12/noxo-windows.zip',
  String? digest,
}) => {
  'tag_name': tag,
  'assets': [
    {'name': 'notes.txt', 'browser_download_url': 'https://example.com/notes.txt'},
    {'name': name, 'browser_download_url': url, 'digest': digest},
  ],
};

void main() {
  group('parseRelease', () {
    test('offers a newer build', () {
      final u = parseRelease(release(digest: 'sha256:ABCDEF'), 11)!;
      expect(u.build, 12);
      expect(u.url.path, endsWith('/build-12/noxo-windows.zip'));
      expect(u.sha256, 'abcdef');
    });

    test('ignores the same or an older build', () {
      expect(parseRelease(release(), 12), isNull);
      expect(parseRelease(release(), 40), isNull);
    });

    test('works without a digest', () {
      expect(parseRelease(release(), 1)!.sha256, isNull);
    });

    test('refuses a download from anywhere else', () {
      expect(parseRelease(release(url: 'https://example.com/noxo-windows.zip'), 1), isNull);
      expect(
        parseRelease(
          release(url: 'http://github.com/antoine28boel/noxo/releases/download/x.zip'),
          1,
        ),
        isNull,
      );
    });

    test('ignores anything that is not one of our releases', () {
      expect(parseRelease(release(tag: 'v1.0'), 1), isNull);
      expect(parseRelease(release(name: 'other.zip'), 1), isNull);
      expect(parseRelease({'tag_name': 'build-12'}, 1), isNull);
      expect(parseRelease('nope', 1), isNull);
      expect(parseRelease(null, 1), isNull);
    });
  });

  group('parseCertutilHash', () {
    const hash = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';

    test('reads the hash line', () {
      const out =
          'SHA256 hash of C:\\tmp\\noxo-windows.zip:\r\n$hash\r\n'
          'CertUtil: -hashfile command completed successfully.\r\n';
      expect(parseCertutilHash(out), hash);
    });

    test('accepts spaced, upper-case output', () {
      final spaced = hash.toUpperCase().replaceAllMapped(RegExp('..'), (m) => '${m[0]} ');
      expect(parseCertutilHash('header\n$spaced\nfooter'), hash);
    });

    test('returns null when there is no hash', () {
      expect(parseCertutilHash('CertUtil: -hashfile command FAILED'), isNull);
    });
  });

  group('parseInstallArgs', () {
    test('reads the installer command line', () {
      final r = parseInstallArgs(['--noxo-install', r'C:\Noxo', '4242'])!;
      expect(r.target, r'C:\Noxo');
      expect(r.oldPid, 4242);
    });

    test('a normal start is not an install', () {
      expect(parseInstallArgs([]), isNull);
      expect(parseInstallArgs(['--noxo-install', r'C:\Noxo']), isNull);
      expect(parseInstallArgs(['--noxo-install', r'C:\Noxo', 'abc']), isNull);
      expect(parseInstallArgs(['--other', r'C:\Noxo', '1']), isNull);
    });
  });

  test('copyOrder copies noxo.exe last', () {
    expect(copyOrder(['noxo.exe', r'data\app.so', 'flutter_windows.dll', r'data\icudtl.dat']), [
      r'data\app.so',
      r'data\icudtl.dat',
      'flutter_windows.dll',
      'noxo.exe',
    ]);
  });
}
