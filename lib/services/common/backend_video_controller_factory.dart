import 'package:aves_model/aves_model.dart';
import 'package:aves_video/aves_video.dart';
import 'package:aves_video_mpv/aves_video_mpv.dart';
import 'package:aves_video_vlc/aves_video_vlc.dart';

// Dispatches to the playback backend selected in the settings, so the rest of
// the app keeps using a single `AvesVideoControllerFactory`.
//
// The backend is read per `buildController`, so a settings change applies to
// videos opened afterwards; an already open video keeps its backend.
class BackendVideoControllerFactory implements AvesVideoControllerFactory {
  final MpvVideoControllerFactory _mpv = MpvVideoControllerFactory();
  final VlcVideoControllerFactory _vlc = VlcVideoControllerFactory();
  bool _vlcInitialized = false;

  @override
  void init() {
    // mpv also backs the audio player and the metadata/thumbnail fetcher
    _mpv.init();
  }

  @override
  AvesVideoController buildController(
    AvesEntryBase entry, {
    required PlaybackStateHandler playbackStateHandler,
    required VideoSettings settings,
  }) {
    switch (settings.videoPlayerBackend) {
      case .mpv:
        return _mpv.buildController(entry, playbackStateHandler: playbackStateHandler, settings: settings);
      case .vlc:
        if (!_vlcInitialized) {
          _vlc.init();
          _vlcInitialized = true;
        }
        return _vlc.buildController(entry, playbackStateHandler: playbackStateHandler, settings: settings);
    }
  }
}
