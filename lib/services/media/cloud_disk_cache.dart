import 'dart:io';
import 'dart:math' as math;

import 'package:aves/services/common/services.dart';
import 'package:flutter/foundation.dart';

// simple LRU disk cache for downloaded cloud payloads (WebDAV / SMB),
// keyed by URL via a stable FNV-1a hash
class CloudDiskCache {
  static const int _maxBytes = 256 << 20; // 256 MiB
  // trim below the limit so the directory is not rescanned on every write
  static const int _evictTargetBytes = 204 << 20; // 192 MiB
  static const int _fnvOffset = 0x811c9dc5;
  static const int _fnvPrime = 0x01000193;

  Directory? _dir;
  // rough total of the cached files, so a write does not have to list and stat
  // the whole directory (which used to happen once per downloaded image)
  int? _totalBytes;

  Future<Directory> _cacheDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    final root = await storageService.getExternalCacheDirectory();
    final dir = Directory('$root/cloud');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  static String _key(String url) {
    var hash = _fnvOffset;
    for (final codeUnit in url.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * _fnvPrime) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Future<File> _fileFor(String url) async {
    final dir = await _cacheDir();
    return File('${dir.path}/${_key(url)}');
  }

  Future<int> _scanTotal(Directory dir) async {
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      try {
        total += (await entity.stat()).size;
      } catch (_) {
        // a file removed while scanning
      }
    }
    return total;
  }

  Future<Uint8List?> get(String url) async {
    try {
      final file = await _fileFor(url);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      // touch for LRU
      await file.setLastModified(DateTime.now());
      return bytes;
    } catch (error) {
      debugPrint('cloud cache read failed for $url error=$error');
      return null;
    }
  }

  Future<void> put(String url, Uint8List bytes) async {
    try {
      final file = await _fileFor(url);
      _totalBytes ??= await _scanTotal(await _cacheDir());
      final stat = await file.stat();
      final previous = stat.type == FileSystemEntityType.notFound ? 0 : stat.size;
      await file.writeAsBytes(bytes, flush: true);
      _totalBytes = (_totalBytes ?? 0) - previous + bytes.length;
      if (_totalBytes! > _maxBytes) {
        await _evict();
      }
    } catch (error) {
      debugPrint('cloud cache write failed for $url error=$error');
    }
  }

  Future<void> remove(String url) async {
    try {
      final file = await _fileFor(url);
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return;
      await file.delete();
      final total = _totalBytes;
      if (total != null) {
        _totalBytes = math.max(0, total - stat.size);
      }
    } catch (error) {
      debugPrint('cloud cache remove failed for $url error=$error');
    }
  }

  Future<void> _evict() async {
    try {
      final dir = await _cacheDir();
      final entries = <(File, FileStat)>[];
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          entries.add((entity, stat));
          total += stat.size;
        } catch (_) {
          // removed while scanning
        }
      }
      _totalBytes = total;
      if (total <= _maxBytes) return;
      entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (file, stat) in entries) {
        if (total <= _evictTargetBytes) break;
        try {
          await file.delete();
          total -= stat.size;
        } catch (_) {
          // already gone
        }
      }
      _totalBytes = total;
    } catch (error) {
      debugPrint('cloud cache eviction failed error=$error');
    }
  }

  Future<void> clear() async {
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _dir = null;
      _totalBytes = 0;
    } catch (error) {
      debugPrint('cloud cache clear failed error=$error');
    }
  }
}

final cloudDiskCache = CloudDiskCache();
