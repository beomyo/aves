import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:aves/image_providers/region_provider.dart';
import 'package:aves/image_providers/thumbnail_provider.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/ref/mime_types.dart';
import 'package:aves/services/common/cloud_registry.dart';
import 'package:aves/services/common/service_policy.dart';
import 'package:aves/services/common/services.dart';
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
  static Future<ui.Codec> decodeBounded(Uint8List bytes, ImageDecoderCallback decode, int maxDim) async {
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

  // largest side to decode a thumbnail at, for a tile of the given extent
  static int thumbnailMaxDim(double extent) {
    final devicePixelRatio = ui.PlatformDispatcher.instance.views.firstOrNull?.devicePixelRatio ?? 1.0;
    final requested = extent > 0 ? (extent * devicePixelRatio).round() : 256;
    // cap the thumbnail size so a huge mosaic tile cannot decode a huge bitmap
    return requested.clamp(1, _maxThumbnailDim);
  }

  Future<ui.Codec> loadThumbnail(
    ThumbnailProviderKey request,
    ImageDecoderCallback? decode,
    Object? taskKey,
    int? priority,
  ) {
    final extent = request.extent;
    final maxDim = thumbnailMaxDim(extent);
    return servicePolicy.call(
      () async {
        final bytes = await bytesFor(request.uri);
        return decodeBounded(bytes, decoderFor(decode), maxDim);
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
        return decodeBounded(bytes, decode, maxDim);
      },
      priority: ServiceCallPriority.normal,
    );
  }

  // the framework provides a decoder for sized thumbnails; fall back to
  // `instantiateImageCodec` when it is missing
  static ImageDecoderCallback decoderFor(ImageDecoderCallback? decode) {
    if (decode != null) return decode;
    throw UnreportedStateError('missing decoder for cloud thumbnail');
  }
}

final cloudImageLoader = CloudImageLoader();

// URIs whose video frame is being extracted (queued or running), so a tile can
// show a progress indicator instead of an empty placeholder
final ValueNotifier<Set<String>> cloudGeneratingVideoThumbnails = ValueNotifier(const {});

void _setVideoThumbnailGenerating(String uri, bool generating) {
  final current = cloudGeneratingVideoThumbnails.value;
  final next = {...current};
  final changed = generating ? next.add(uri) : next.remove(uri);
  if (changed) {
    cloudGeneratingVideoThumbnails.value = next;
  }
}

// drops the cached payload of a cloud entry (the extracted video frame and any
// downloaded image bytes), so the next request fetches it again
Future<void> evictCloudThumbnail(String uri) async {
  await cloudDiskCache.remove('${CloudAwareMediaFetchService._videoThumbnailCachePrefix}$uri');
  await cloudDiskCache.remove(uri);
}

// stores a frame captured while the user was watching the video, so the grid can
// show a thumbnail without asking the server to extract one
Future<void> saveCloudVideoThumbnail(String uri, Uint8List bytes) async {
  await cloudDiskCache.put('${CloudAwareMediaFetchService._videoThumbnailCachePrefix}$uri', bytes);
}

// drops the queued thumbnail extractions of entries the user has left, so the
// app stops generating for a folder that is no longer on screen
void abandonCloudVideoThumbnails(Iterable<String> uris) {
  final service = mediaFetchService;
  if (service is CloudAwareMediaFetchService) {
    service.abandonVideoThumbnails(uris);
  }
}

// thrown when the user left the folder an extraction belongs to
class _VideoThumbnailAbandoned implements Exception {
  const new();
}

// Decorates the platform media fetch service so that remote URIs
// (WebDAV / SMB entries) are served from the network while every other URI
// keeps using the platform implementation unchanged.
class CloudAwareMediaFetchService implements MediaFetchService {
  // remote servers can rate limit aggressive clients (AList/OpenList expose such
  // a limit), and one frame extraction costs several round trips, so the budget
  // is generous; extractions are also serialized below so the limit is shared
  // rather than multiplied
  static const _videoThumbnailTimeout = Duration(seconds: 45);
  static const _videoThumbnailCooldown = Duration(seconds: 60);
  // a timeout is usually a slow/rate limited server rather than a file that
  // cannot be thumbnailed, so retry it much sooner
  static const _videoThumbnailTimeoutCooldown = Duration(seconds: 20);
  // extracted frames live in `cloudDiskCache`, so they survive a restart
  static const _videoThumbnailCachePrefix = 'video-thumb:';

  final MediaFetchService _delegate;
  final Map<String, DateTime> _videoThumbCooldown = {};

  // how many extractions may hit the server at once; deliberately low by
  // default, because parallel requests only multiply latency on a rate limited
  // server. The limit is read on every acquire so the setting applies at once.
  int _videoThumbnailRunning = 0;
  final Queue<Completer<void>> _videoThumbnailWaiters = Queue();

  // generation per entry, bumped when the user leaves the folder it belongs to,
  // so queued extractions of that folder are dropped
  final Map<String, int> _abandonedVideoGeneration = {};

  new(this._delegate);

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
      if (MimeTypes.isVideo(request.mimeType)) {
        return _getCloudVideoThumbnail(
          decoded: decoded,
          request: request,
          decode: decode,
          taskKey: taskKey,
          priority: priority,
        );
      }
      return cloudImageLoader.loadThumbnail(request, decode, taskKey, priority);
    }
    return _delegate.getThumbnail(decoded: decoded, request: request, decode: decode, taskKey: taskKey, priority: priority);
  }

  @override
  Future<Uint8List> getThumbnailBytes({
    required bool decoded,
    required ThumbnailProviderKey request,
    String? uriOverride,
    Map<String, String>? httpHeaders,
    double? previewFraction,
    Object? taskKey,
    int? priority,
  }) {
    return _delegate.getThumbnailBytes(
      decoded: decoded,
      request: request,
      uriOverride: uriOverride,
      httpHeaders: httpHeaders,
      previewFraction: previewFraction,
      taskKey: taskKey,
      priority: priority,
    );
  }

  @override
  Future<int?> getVideoDuration(String uri) => _delegate.getVideoDuration(uri);

  // remote videos are extracted as a frame by the platform, which needs the
  // playable URL and the auth headers of the owning server. The extracted frame
  // is cached on disk so that a restart does not fetch it again, and libmpv is
  // used as a fallback for containers the platform cannot decode.

  // abandons the queued extractions of entries the user has left. Nothing is
  // cancelled mid-flight (a platform call cannot be aborted), but the rest of
  // the queue is dropped instead of hitting the server.
  void abandonVideoThumbnails(Iterable<String> uris) {
    for (final uri in uris) {
      _abandonedVideoGeneration[uri] = (_abandonedVideoGeneration[uri] ?? 0) + 1;
    }
    if (_abandonedVideoGeneration.length > 4000) {
      _abandonedVideoGeneration.clear();
    }
  }

  int _generationOf(String uri) => _abandonedVideoGeneration[uri] ?? 0;

  void _throwIfAbandoned(int generation, String uri) {
    if (generation != _generationOf(uri)) {
      throw const _VideoThumbnailAbandoned();
    }
  }

  Future<void> _acquireVideoThumbnailSlot() async {
    if (_videoThumbnailRunning < settings.cloudThumbnailConcurrency) {
      _videoThumbnailRunning++;
      return;
    }
    final completer = Completer<void>();
    _videoThumbnailWaiters.add(completer);
    // the releaser increments the counter on our behalf
    await completer.future;
  }

  void _releaseVideoThumbnailSlot() {
    _videoThumbnailRunning--;
    final limit = settings.cloudThumbnailConcurrency;
    while (_videoThumbnailWaiters.isNotEmpty && _videoThumbnailRunning < limit) {
      _videoThumbnailRunning++;
      _videoThumbnailWaiters.removeFirst().complete();
    }
  }

  Future<ui.Codec> _getCloudVideoThumbnail({
    required bool decoded,
    required ThumbnailProviderKey request,
    ImageDecoderCallback? decode,
    Object? taskKey,
    int? priority,
  }) async {
    final uri = request.uri;
    final decoder = CloudImageLoader.decoderFor(decode);
    final maxDim = CloudImageLoader.thumbnailMaxDim(request.extent);
    final cacheKey = '$_videoThumbnailCachePrefix$uri';
    final cached = await cloudDiskCache.get(cacheKey);
    if (cached != null) {
      try {
        return await CloudImageLoader.decodeBounded(cached, decoder, maxDim);
      } catch (_) {
        // drop a corrupt entry so the next attempt extracts a fresh frame
        unawaited(cloudDiskCache.remove(cacheKey));
      }
    }

    // automatic extraction is the expensive, server-hitting part, so it can be
    // turned off; a frame already known (captured while watching, or cached
    // from an earlier extraction) is still served
    if (!settings.cloudVideoThumbnails) {
      throw const CloudException('automatic video thumbnails are disabled');
    }

    final cooldownUntil = _videoThumbCooldown[uri];
    if (cooldownUntil != null && DateTime.now().isBefore(cooldownUntil)) {
      throw const CloudException('video thumbnail temporarily unavailable');
    }

    final generation = _generationOf(uri);
    final started = DateTime.now();
    _setVideoThumbnailGenerating(uri, true);
    try {
      final source = await cloudRegistry.playbackSource(uri);
      final headers = source.headers.isEmpty ? null : source.headers;
      final previewFraction = settings.cloudVideoThumbnailPercent / 100;
      // the budget covers the extraction itself, not the wait for a free slot, so
      // a queue of slow tiles is not reported as a failure
      late final Uint8List bytes;
      await _acquireVideoThumbnailSlot();
      try {
        _throwIfAbandoned(generation, uri);
        bytes = await _delegate
            .getThumbnailBytes(
              decoded: decoded,
              request: request,
              uriOverride: source.url,
              httpHeaders: headers,
              previewFraction: previewFraction,
              taskKey: taskKey,
              priority: priority ?? ServiceCallPriority.getVideoThumbnail,
            )
            .timeout(_videoThumbnailTimeout);
      } finally {
        _releaseVideoThumbnailSlot();
      }
      if (bytes.isNotEmpty) {
        final codec = await CloudImageLoader.decodeBounded(bytes, decoder, maxDim);
        // only cache a frame that decoded, so a bad entry cannot wedge the tile
        unawaited(cloudDiskCache.put(cacheKey, bytes));
        unawaited(_recordVideoDuration(uri, source.url));
        _logVideoThumbnail(uri, started, 'extracted', extra: 'bytes=${bytes.length}');
        return codec;
      }

      // the platform could not extract a frame from this container: let libmpv try
      _throwIfAbandoned(generation, uri);
      final descriptor = await videoMetadataFetcher
          .getThumbnailDescriptor(
            uri: source.url,
            mimeType: request.mimeType,
            targetExtentDip: request.extent,
            methods: request.videoThumbnailMethods ?? [],
            httpHeaders: headers,
            previewFraction: settings.cloudVideoThumbnailPercent / 100,
          )
          .timeout(_videoThumbnailTimeout);
      final codec = await descriptor?.instantiateCodec(
        targetWidth: descriptor.width,
        targetHeight: descriptor.height,
      );
      if (codec == null) {
        throw const CloudException('failed to extract a video frame');
      }
      _logVideoThumbnail(uri, started, 'fallback');
      return codec;
    } catch (error) {
      if (error is _VideoThumbnailAbandoned) {
        // the folder was left before this extraction started: not its fault
        _logVideoThumbnail(uri, started, 'abandoned');
        rethrow;
      }
      // a task paused while the tile scrolled away never completes, so the
      // timeout above fires without the file being at fault: do not back it off
      final isTimeout = error is TimeoutException;
      final pausedDuringWait = isTimeout && taskKey != null && servicePolicy.isPaused(taskKey);
      if (!pausedDuringWait) {
        _videoThumbCooldown[uri] = DateTime.now().add(isTimeout ? _videoThumbnailTimeoutCooldown : _videoThumbnailCooldown);
      }
      _logVideoThumbnail(uri, started, 'failed', extra: 'reason=${error.runtimeType} timeout=$isTimeout paused=$pausedDuringWait message=$error');
      rethrow;
    } finally {
      _setVideoThumbnailGenerating(uri, false);
    }
  }

  static void _logVideoThumbnail(String uri, DateTime started, String outcome, {String? extra}) {
    final elapsedMs = DateTime.now().difference(started).inMilliseconds;
    debugPrint('[cloud-video-thumb] $outcome uri=$uri elapsedMs=$elapsedMs${extra == null ? '' : ' $extra'}');
  }

  // the platform probes the duration while extracting the frame; persist it so
  // the tile can show it, and so it survives a restart
  Future<void> _recordVideoDuration(String uri, String probedUri) async {
    try {
      final durationMillis = await _delegate.getVideoDuration(probedUri);
      if (durationMillis != null && durationMillis > 0) {
        settings.setCloudVideoDuration(uri, durationMillis);
      }
    } catch (_) {
      // best effort only
    }
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
