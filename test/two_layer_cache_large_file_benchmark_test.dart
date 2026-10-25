import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxshare/file/manifest_cache.dart';
import 'package:fluxshare/file/manifest_service.dart';
import 'package:fluxshare/file/session_manifest_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('800 MB file: measure first hashing vs session cache hit vs persistent cache hit', () async {
    final tempDir = await Directory.systemTemp.createTemp('fluxshare_800mb_bench_');
    final cacheDir = Directory('${tempDir.path}/manifest_cache');
    await cacheDir.create(recursive: true);

    ManifestCache.instance.setCustomCacheDir(cacheDir);
    ManifestCache.instance.clearMemoryCache();

    final sessionCache = SessionManifestCache();

    final testFile = File('${tempDir.path}/large_movie_800mb.mp4');
    final raf = await testFile.open(mode: FileMode.write);
    const int targetSize = 800 * 1024 * 1024; // 800 MB
    await raf.truncate(targetSize);
    // Write distinct head and tail
    await raf.setPosition(0);
    await raf.writeFrom(List.filled(4096, 0x41));
    await raf.setPosition(targetSize - 4096);
    await raf.writeFrom(List.filled(4096, 0x5A));
    await raf.flush();
    await raf.close();

    expect(await testFile.length(), targetSize);

    // 1. First hashing pass
    bool hashingStarted1 = false;
    final sw1 = Stopwatch()..start();
    final manifest1 = await ManifestService.generateManifest(
      testFile,
      identifier: 'content://media/external/video/media/9999',
      sessionCache: sessionCache,
      onHashingStarted: () => hashingStarted1 = true,
    );
    sw1.stop();

    expect(hashingStarted1, isTrue);
    expect(manifest1.fileSize, targetSize);
    expect(manifest1.chunks.isNotEmpty, isTrue);
    final firstHashingMs = sw1.elapsedMilliseconds;

    // 2. Reselection within active session (Session Cache Hit)
    bool hashingStarted2 = false;
    final sw2 = Stopwatch()..start();
    final manifest2 = await ManifestService.generateManifest(
      testFile,
      identifier: 'content://media/external/video/media/9999',
      sessionCache: sessionCache,
      onHashingStarted: () => hashingStarted2 = true,
    );
    sw2.stop();

    expect(hashingStarted2, isFalse, reason: 'Session cache hit must NOT start hashing');
    expect(manifest2.fileSha256, manifest1.fileSha256);
    expect(manifest2.chunks.length, manifest1.chunks.length);
    final sessionHitMs = sw2.elapsedMilliseconds;

    // Verify speedup: session hit takes < 100ms compared to first hashing
    expect(sw2.elapsedMilliseconds, lessThan(100), reason: 'Session cache hit should be virtually instantaneous');

    // 3. New session / app restart (Persistent Cache Hit)
    final newSessionCache = SessionManifestCache(); // fresh session
    ManifestCache.instance.clearMemoryCache(); // simulate fresh app process
    bool hashingStarted3 = false;
    final sw3 = Stopwatch()..start();
    final manifest3 = await ManifestService.generateManifest(
      testFile,
      identifier: 'content://media/external/video/media/9999',
      sessionCache: newSessionCache,
      onHashingStarted: () => hashingStarted3 = true,
    );
    sw3.stop();

    expect(hashingStarted3, isFalse, reason: 'Persistent cache hit must NOT start hashing');
    expect(manifest3.fileSha256, manifest1.fileSha256);
    final persistentHitMs = sw3.elapsedMilliseconds;
    expect(sw3.elapsedMilliseconds, lessThan(200), reason: 'Persistent cache hit should be fast');

    // 4. In-place modification should miss cache and rehash
    final modRaf = await testFile.open(mode: FileMode.write);
    await modRaf.setPosition(100);
    await modRaf.writeFrom(List.filled(100, 0xFF));
    await modRaf.flush();
    await modRaf.close();

    bool hashingStarted4 = false;
    final manifest4 = await ManifestService.generateManifest(
      testFile,
      identifier: 'content://media/external/video/media/9999',
      sessionCache: newSessionCache,
      onHashingStarted: () => hashingStarted4 = true,
    );
    expect(hashingStarted4, isTrue, reason: 'Modified file must trigger rehashing');
    expect(manifest4.fileSha256, isNot(equals(manifest1.fileSha256)));

    // Cleanup
    await ManifestCache.instance.clear();
    await tempDir.delete(recursive: true);

    expect(firstHashingMs, greaterThan(0));
    expect(sessionHitMs, lessThan(firstHashingMs));
    expect(persistentHitMs, lessThan(firstHashingMs));
  }, timeout: const Timeout(Duration(seconds: 120)));
}
