import 'dart:ui' as ui;

import 'package:aves/image_providers/region_provider.dart';
import 'package:aves/image_providers/thumbnail_provider.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/services/common/service_policy.dart';
import 'package:aves/services/common/webdav_registry.dart';
import 'package:aves/services/media/media_fetch_service.dart';
import 'package:aves/services/media/webdav_client.dart';
import 'package:aves/services/media/webdav_disk_cache.dart';
import 'package:aves_report/aves_report.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

bool isRemoteUri(String uri) => uri.startsWith('http://') || uri.startsWith('https://');

class WebDavImageLoader {
  final Map<String, double> _aspectCache = {};

  Future<Uint8List> bytesFor(String url) async {
    final cached = await webDavDiskCache.get(url);
    if (cached != null) return cached;

    final client = webDavRegistry.clientForUrl(url);
    if (client == null) {
      throw WebDavException('no WebDAV server configured for $url');
    }
    final bytes = await client.getBytes(url);
    if (bytes.isNotEmpty) {
      await webDavDiskCache.put(url, bytes);
    }
    return bytes;
  }

  // aspect ratio (width / height) parsed from the image header,
  // downloading at most the leading bytes of the file
  Future<double?> probeAspect(String url) async {
    final cached = _aspectCache[url];
    if (cached != null) return cached;

    final client = webDavRegistry.clientForUrl(url);
    if (client == null) return null;

    final bytes = await client.probeBytes(url);
    if (bytes == null || bytes.isEmpty) return null;

    ui.ImageDescriptor? descriptor;
    ui.ImmutableBuffer? buffer;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width > 0 && height > 0) {
        final aspect = width / height;
        _aspectCache[url] = aspect;
        return aspect;
      }
    } catch (_) {
      // header incomplete or unsupported format
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
    return null;
  }

  Future<ui.Codec> loadThumbnail(
    ThumbnailProviderKey request,
    ImageDecoderCallback? decode,
    Object? taskKey,
    int? priority,
  ) {
    final extent = request.extent;
    final devicePixelRatio = ui.PlatformDispatcher.instance.views.firstOrNull?.devicePixelRatio ?? 1.0;
    final target = extent > 0 ? (extent * devicePixelRatio).round() : null;
    return servicePolicy.call(
      () async {
        final bytes = await bytesFor(request.uri);
        // decode at the requested size to avoid holding full-resolution
        // bitmaps for every grid tile
        return ui.instantiateImageCodec(
          bytes,
          targetWidth: target,
          targetHeight: target,
          allowUpscaling: false,
        );
      },
      priority: priority ?? (extent == 0 ? ServiceCallPriority.getFastThumbnail : ServiceCallPriority.getSizedThumbnail),
      key: taskKey,
    );
  }

  Future<ui.Codec> loadFullImage(
    ImageRequest request,
    ImageDecoderCallback decode,
  ) {
    return servicePolicy.call(
      () async {
        final bytes = await bytesFor(request.uri);
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        return decode(buffer);
      },
      priority: ServiceCallPriority.normal,
    );
  }
}

final webDavImageLoader = WebDavImageLoader();

// Decorates the platform media fetch service so that `http(s)` URIs
// (WebDAV entries) are served from the network while every other URI
// keeps using the platform implementation unchanged.
class WebDavAwareMediaFetchService implements MediaFetchService {
  final MediaFetchService _delegate;

  const new(this._delegate);

  @override
  Future<AvesEntry?> getEntry(String uri, String? mimeType, {bool allowUnsized = false}) {
    if (isRemoteUri(uri)) return Future.value(null);
    return _delegate.getEntry(uri, mimeType, allowUnsized: allowUnsized);
  }

  @override
  Future<Uint8List> getOriginalBytes(AvesEntry entry) {
    if (isRemoteUri(entry.uri)) return webDavImageLoader.bytesFor(entry.uri);
    return _delegate.getOriginalBytes(entry);
  }

  @override
  Future<ui.Codec> getFullImage({
    required bool decoded,
    required ImageRequest request,
    required ImageDecoderCallback decode,
  }) {
    if (isRemoteUri(request.uri)) {
      return webDavImageLoader.loadFullImage(request, decode);
    }
    return _delegate.getFullImage(decoded: decoded, request: request, decode: decode);
  }

  @override
  Future<ui.Codec> getRegion({
    required bool decoded,
    required RegionProviderKey request,
    required ImageDecoderCallback decode,
    Object? taskKey,
    int? priority,
  }) {
    // remote entries never use tiling (see `ExtraAvesEntryProps.useTiles`)
    if (isRemoteUri(request.uri)) {
      throw UnreportedStateError('region requests are not supported for remote entries uri=${request.uri}');
    }
    return _delegate.getRegion(decoded: decoded, request: request, decode: decode, taskKey: taskKey, priority: priority);
  }

  @override
  Future<ui.Codec> getThumbnail({
    required bool decoded,
    required ThumbnailProviderKey request,
    ImageDecoderCallback? decode,
    Object? taskKey,
    int? priority,
  }) {
    if (isRemoteUri(request.uri)) {
      return webDavImageLoader.loadThumbnail(request, decode, taskKey, priority);
    }
    return _delegate.getThumbnail(decoded: decoded, request: request, decode: decode, taskKey: taskKey, priority: priority);
  }

  @override
  Future<void> clearDecoders() => _delegate.clearDecoders();

  @override
  Future<void> clearImageDiskCache() async {
    await _delegate.clearImageDiskCache();
    await webDavDiskCache.clear();
  }

  @override
  Future<void> clearImageMemoryCache() => _delegate.clearImageMemoryCache();

  @override
  bool cancelRegion(Object taskKey) => _delegate.cancelRegion(taskKey);

  @override
  bool cancelThumbnail(Object taskKey) => _delegate.cancelThumbnail(taskKey);

  @override
  Future<T>? resumeLoading<T>(Object taskKey) => _delegate.resumeLoading<T>(taskKey);
}
