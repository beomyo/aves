import 'package:aves_model/aves_model.dart';
import 'package:aves_video/aves_video.dart';
import 'package:aves_video_vlc/aves_video_vlc.dart';

class VlcVideoControllerFactory implements AvesVideoControllerFactory {
  @override
  void init() {
    // the platform plugin self-registers, nothing to initialize eagerly
  }

  @override
  AvesVideoController buildController(
    AvesEntryBase entry, {
    required PlaybackStateHandler playbackStateHandler,
    required VideoSettings settings,
  }) => VlcVideoController(
    entry,
    playbackStateHandler: playbackStateHandler,
    settings: settings,
  );
}
