import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:aves/image_providers/region_provider.dart';
import 'package:aves/image_providers/thumbnail_provider.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/services/common/cloud_registry.dart';
import 'package:aves/services/common/service_policy.dart';
import 'package:aves/services/media/cloud_client.dart';
import 'package:aves/services/media/cloud_disk_cache.dart';
import 'package:aves/services/media/media_fetch_service.dart';
import 'package:aves_report/aves_report.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

bool isCloudUri(String uri) => uri.startsWith('http://') || uri.startsWith('https://') || uri.startsWith('smb://');

class CloudImageLoader {
  // hard caps on the decoded dimensions: remote files can be enormous, and
  // decoding several of them at native resolution is what used to OOM
  static const int _maxThumbnailDim = 1024;
  static const int _minFullImageDim = 1024;
  static const int _maxFullImageDim = 3072;

  final Map<String, double> _aspectCache = {};

  Future<Uint8List> bytesFor(String url) async {
    final cached = await cloudDiskCache.get(url);
    if (cached != null) return cached;

    final client = cloudRegistry.clientForUrl(url);
    if (client == null) {
      throw CloudException('no cloud service configured for $url');
    }
    final bytes = await client.getBytes(url);
    if (bytes.isNotEmpty) {
      await cloudDiskCache.put(url, bytes);
    }
    return bytes;
  }

  // decodes while bounding the longest side to `maxDim` (never upscaling),
  // so memory stays proportional to the tile/screen size instead of the file
  static Future<ui.Codec> _decodeBounded(Uint8List bytes, ImageDecoderCallback decode, int maxDim) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(
      buffer,
      getTargetSize: (intrinsicWidth, intrinsicHeight) {
        final longest = math.max(intrinsicWidth, intrinsicHeight);
        if (longest <= maxDim || longest == 0) {
          return const ui.TargetImageSize();
        }
        final scale = maxDim / longest;
        return ui.TargetImageSize(
          width: math.max(1, (intrinsicWidth * scale).round()),
          height: math.max(1, (intrinsicHeight * scale).round()),
        );
      },
    );
  }

  // aspect ratio (width / height) parsed from the image header,
  // downloading at most the leading bytes of the file
  Future<double?> probeAspect(String url) async {
    final cached = _aspectCache[url];
    if (cached != null) return cached;

    final client = cloudRegistry.clientForUrl(url);
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
    final requested = extent > 0 ? (extent * devicePixelRatio).round() : 256;
    // cap the thumbnail size so a huge mosaic tile cannot decode a huge bitmap
    final maxDim = requested.clamp(1, _maxThumbnailDim);
    return servicePolicy.call(
      () async {
        final bytes = await bytesFor(request.uri);
        return _decodeBounded(bytes, _decoderFor(decode), maxDim);
      },
      priority: priority ?? (extent == 0 ? ServiceCallPriority.getFastThumbnail : ServiceCallPriority.getSizedThumbnail),
      key: taskKey,
    );
  }

  Future<ui.Codec> loadFullImage(
    ImageRequest request,
    ImageDecoderCallback decode,
  ) {
    final view = ui.PlatformDispatcher.instance.views.firstOrNull;
    // decode at roughly the screen size, allowing a little zoom headroom,
    // instead of at the file's native resolution
    final longSide = view == null ? _minFullImageDim : math.max(view.physicalSize.width, view.physicalSize.height).round();
    final maxDim = (longSide * 1.25).round().clamp(_minFullImageDim, _maxFullImageDim);
    return servicePolicy.call(
      () async {
        final bytes = await bytesFor(request.uri);
        return _decodeBounded(bytes, decode, maxDim);
      },
      priority: ServiceCallPriority.normal,
    );
  }

  // the framework provides a decoder for sized thumbnails; fall back to
  // `instantiateImageCodec` when it is missing
  static ImageDecoderCallback _decoderFor(ImageDecoderCallback? decode) {
    if (decode != null) return decode;
    throw UnreportedStateError('missing decoder for cloud thumbnail');
  }
}

final cloudImageLoader = CloudImageLoader();

// Decorates the platform media fetch service so that remote URIs
// (WebDAV / SMB entries) are served from the network while every other URI
// keeps using the platform implementation unchanged.
class CloudAwareMediaFetchService implements MediaFetchService {
  final MediaFetchService _delegate;

  const new(this._delegate);

  @override
  Future<AvesEntry?> getEntry(String uri, String? mimeType, {bool allowUnsized = false}) {
    if (isCloudUri(uri)) return Future.value(null);
    return _delegate.getEntry(uri, mimeType, allowUnsized: allowUnsized);
  }

  @override
  Future<Uint8List> getOriginalBytes(AvesEntry entry) {
    if (isCloudUri(entry.uri)) return cloudImageLoader.bytesFor(entry.uri);
    return _delegate.getOriginalBytes(entry);
  }

  @override
  Future<ui.Codec> getFullImage({
    required bool decoded,
    required ImageRequest request,
    required ImageDecoderCallback decode,
  }) {
    if (isCloudUri(request.uri)) {
      return cloudImageLoader.loadFullImage(request, decode);
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
    if (isCloudUri(request.uri)) {
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
    if (isCloudUri(request.uri)) {
      return cloudImageLoader.loadThumbnail(request, decode, taskKey, priority);
    }
    return _delegate.getThumbnail(decoded: decoded, request: request, decode: decode, taskKey: taskKey, priority: priority);
  }

  @override
  Future<void> clearDecoders() => _delegate.clearDecoders();

  @override
  Future<void> clearImageDiskCache() async {
    await _delegate.clearImageDiskCache();
    await cloudDiskCache.clear();
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
