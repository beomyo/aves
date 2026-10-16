import 'dart:io';

import 'package:aves/services/common/services.dart';
import 'package:flutter/foundation.dart';

// simple LRU disk cache for downloaded cloud payloads (WebDAV / SMB),
// keyed by URL via a stable FNV-1a hash
class CloudDiskCache {
  static const int _maxBytes = 256 << 20; // 256 MiB
  static const int _fnvOffset = 0x811c9dc5;
  static const int _fnvPrime = 0x01000193;

  Directory? _dir;

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
      await file.writeAsBytes(bytes, flush: true);
      await _evict();
    } catch (error) {
      debugPrint('cloud cache write failed for $url error=$error');
    }
  }

  Future<void> remove(String url) async {
    try {
      final file = await _fileFor(url);
      if (await file.exists()) {
        await file.delete();
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
        final stat = await entity.stat();
        entries.add((entity, stat));
        total += stat.size;
      }
      if (total <= _maxBytes) return;
      entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (file, stat) in entries) {
        if (total <= _maxBytes) break;
        await file.delete();
        total -= stat.size;
      }
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
    } catch (error) {
      debugPrint('cloud cache clear failed error=$error');
    }
  }
}

final cloudDiskCache = CloudDiskCache();
