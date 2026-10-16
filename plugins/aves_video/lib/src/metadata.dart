import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:aves_model/aves_model.dart';

abstract class AvesVideoMetadataFetcher {
  void init();

  Future<Map<String, Object?>> getMetadata({required String uri, required String mimeType});

  Future<(int, int?)> computeSlowMotionFactorAndDuration({required String uri, required String mimeType});

  Future<ui.ImageDescriptor?> getThumbnailDescriptor({
    required String uri,
    required String mimeType,
    required double targetExtentDip,
    required List<VideoThumbnailMethod> methods,
    // HTTP headers the backend needs to read a remote resource (e.g. WebDAV Basic auth)
    Map<String, String>? httpHeaders,
    // fraction of the duration the preview frame is taken at (see `getPreviewThumbnailTime`)
    double? previewFraction,
  });

  // fraction of the duration used as the preview thumbnail timestamp: starting
  // slightly after the beginning skips the black/logo frames many videos open with
  static const double defaultPreviewTimeFraction = .01;
  // `fraction` alone is too early on short videos, so never pick a frame before
  // this timestamp, unless that would land past half of a very short video
  static const int previewTimeFloorMillis = 3000;
  static const double previewTimeFloorMaxFraction = .5;

  // use same strategy on flutter and platform sides
  Duration getPreviewThumbnailTime(Duration duration, {double fraction = defaultPreviewTimeFraction}) {
    final durationMillis = duration.inMilliseconds;
    if (durationMillis <= 0) {
      return Duration.zero;
    }
    final floorMillis = min(previewTimeFloorMillis, (durationMillis * previewTimeFloorMaxFraction).round());
    final timeMillis = max((durationMillis * fraction).round(), floorMillis);
    return Duration(milliseconds: min(timeMillis, durationMillis));
  }
}
