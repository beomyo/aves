import 'dart:async';
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
  });

  // fraction of the duration used as the preview thumbnail timestamp: starting
  // slightly after the beginning skips the black/logo frames many videos open with
  static const double previewTimeFraction = .01;

  // use same strategy on flutter and platform sides
  Duration getPreviewThumbnailTime(Duration duration) {
    if (duration <= Duration.zero) {
      return Duration.zero;
    }
    return Duration(milliseconds: (duration.inMilliseconds * previewTimeFraction).round());
  }
}
