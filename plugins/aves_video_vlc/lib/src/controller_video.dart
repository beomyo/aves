import 'dart:async';

import 'package:aves_model/aves_model.dart';
import 'package:aves_utils/aves_utils.dart';
import 'package:aves_video/aves_video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';

// libVLC backed video controller.
//
// Unlike the mpv backend, libVLC cannot start before its platform view exists,
// so `needsWidgetToInitialize` is true: the viewer mounts the player widget
// from the start and `autoInitialize` then opens the media.
//
// Features not available through `flutter_vlc_player` are disabled through the
// `can*Notifier` flags (frame capture, track selection) or stubbed (frame
// stepping).
class VlcVideoController(
  super.entry, {
  required super.playbackStateHandler,
  required super.settings,
}) extends AvesVideoController {
  VlcPlayerController? _controller;
  late PlaybackStatus _status;
  final List<StreamSubscription> _subscriptions = [];
  final StreamController<PlaybackStatus> _statusStreamController = StreamController.broadcast();
  final StreamController<VideoEvent> _eventStreamController = StreamController.broadcast();
  final StreamController<String?> _timedTextStreamController = StreamController.broadcast();
  final StreamController<int> _positionStreamController = StreamController.broadcast();
  final StreamController<double> _volumeStreamController = StreamController.broadcast();
  final StreamController<double> _speedStreamController = StreamController.broadcast();
  final AChangeNotifier _completedNotifier = AChangeNotifier();

  int? _lastPosition;
  double? _lastVolume, _lastSpeed;
  bool _wasBuffering = false, _loopApplied = false;

  @override
  double get minSpeed => .25;

  @override
  double get maxSpeed => 4;

  @override
  final ValueNotifier<bool> canCaptureFrameNotifier = ValueNotifier(false);

  @override
  final ValueNotifier<bool> canMuteNotifier = ValueNotifier(true);

  @override
  final ValueNotifier<bool> canSetSpeedNotifier = ValueNotifier(true);

  @override
  final ValueNotifier<bool> canSelectTrackNotifier = ValueNotifier(false);

  @override
  final ValueNotifier<double?> sarNotifier = ValueNotifier(null);

  // libVLC only initializes once its player widget is mounted
  @override
  bool get needsWidgetToInitialize => true;

  this {
    _status = .idle;
    _statusStreamController.add(_status);

    _controller = VlcPlayerController.network(
      entry.uri,
      // `autoInitialize` needs the platform view, which the widget provides
      autoInitialize: true,
      autoPlay: false,
      hwAcc: _toHwAcc(settings.videoHardwareAcceleration),
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions([
          // favour a fast start over deep buffering on network sources
          VlcAdvancedOptions.networkCaching(1500),
        ]),
      ),
    )..addListener(_onValueChanged);

    _startListening();
    _applyLoop();
  }

  @override
  Future<void> dispose() async {
    _stopListening();
    _controller?.removeListener(_onValueChanged);
    await _statusStreamController.close();
    await _timedTextStreamController.close();
    await _positionStreamController.close();
    await _volumeStreamController.close();
    await _speedStreamController.close();
    try {
      await _controller?.dispose();
    } catch (_) {
      // the plugin throws if the controller was never initialized
    }
    _controller = null;

    _completedNotifier.dispose();
    canCaptureFrameNotifier.dispose();
    canMuteNotifier.dispose();
    canSetSpeedNotifier.dispose();
    canSelectTrackNotifier.dispose();
    sarNotifier.dispose();

    await super.dispose();
  }

  void _startListening() {
    final settingsStream = settings.updateStream;
    _subscriptions.add(settingsStream.where((event) => event.key == SettingKeys.videoLoopModeKey).listen((_) => _applyLoop()));
    // changing hardware acceleration requires reloading the media
    _subscriptions.add(settingsStream.where((event) => event.key == SettingKeys.videoHardwareAccelerationKey).listen((_) => onVisualChanged()));
  }

  void _stopListening() {
    _subscriptions
      ..forEach((sub) => sub.cancel())
      ..clear();
  }

  void _applyLoop() {
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      controller.setLooping(settings.videoLoopMode.shouldLoop(entry));
    }
  }

  void _onValueChanged() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;

    // looping can only be set once the media is loaded
    if (value.isInitialized && !_loopApplied) {
      _loopApplied = true;
      _applyLoop();
    }

    final status = _statusFromValue(value);
    if (status != _status) {
      _status = status;
      _statusStreamController.add(status);
      if (status == .completed) {
        _completedNotifier.notify();
      }
    }

    final position = value.position.inMilliseconds;
    if (position != _lastPosition) {
      _lastPosition = position;
      _positionStreamController.add(position);
    }
    final volume = value.volume / 100;
    if (volume != _lastVolume) {
      _lastVolume = volume;
      _volumeStreamController.add(volume);
    }
    final speed = value.playbackSpeed;
    if (speed != _lastSpeed) {
      _lastSpeed = speed;
      _speedStreamController.add(speed);
    }

    // buffering stalls are reported as events, so the viewer can shed other controllers
    final buffering = value.isBuffering;
    if (buffering && !_wasBuffering) {
      _eventStreamController.add(LagEvent());
    }
    _wasBuffering = buffering;
  }

  static PlaybackStatus _statusFromValue(VlcPlayerValue value) {
    if (value.hasError) return .error;
    if (!value.isInitialized) return .idle;
    if (value.isEnded) return .completed;
    if (value.isPlaying) return .playing;
    return .paused;
  }

  static HwAcc _toHwAcc(VideoHardwareAcceleration hardwareAcceleration) {
    switch (hardwareAcceleration) {
      case .disabled:
        return HwAcc.disabled;
      case .enabled:
        return HwAcc.decoding;
      case .forced:
        return HwAcc.full;
    }
  }

  @override
  void onVisualChanged() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final target = currentPosition;
    final wasPlaying = status == .playing;
    unawaited(
      controller
          .setMediaFromNetwork(
            entry.uri,
            autoPlay: wasPlaying,
            hwAcc: _toHwAcc(settings.videoHardwareAcceleration),
          )
          .then((_) {
            if (target > 0) seekTo(target);
          })
          .catchError((Object error) {
            debugPrint('vlc reload failed error=$error');
          }),
    );
  }

  @override
  Future<void> enableLoop(bool enabled) async {
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      await controller.setLooping(enabled);
    }
  }

  @override
  Future<void> play() async {
    await untilReady;
    await _controller?.play();
  }

  @override
  Future<void> pause() async {
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      await controller.pause();
    }
  }

  @override
  Future<void> seekTo(int targetMillis) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    targetMillis = abRepeatNotifier.value?.clamp(targetMillis) ?? targetMillis;
    await controller.seekTo(Duration(milliseconds: targetMillis));
  }

  @override
  Future<void> skipFrames(int frameCount) async {
    // not supported by the libVLC backend
  }

  @override
  Listenable get playCompletedListenable => _completedNotifier;

  @override
  PlaybackStatus get status => _status;

  @override
  Stream<PlaybackStatus> get statusStream => _statusStreamController.stream;

  @override
  Stream<VideoEvent> get eventStream => _eventStreamController.stream;

  @override
  Stream<double> get volumeStream => _volumeStreamController.stream;

  @override
  Stream<double> get speedStream => _speedStreamController.stream;

  @override
  bool get isReady => _controller?.value.isInitialized ?? false;

  @override
  int get duration => _controller?.value.duration.inMilliseconds ?? 0;

  @override
  int get currentPosition => _controller?.value.position.inMilliseconds ?? 0;

  @override
  Stream<int> get positionStream => _positionStreamController.stream;

  @override
  Stream<String?> get timedTextStream => _timedTextStreamController.stream;

  @override
  bool get isMuted => (_controller?.value.volume ?? 100) == 0;

  @override
  Future<void> mute(bool muted) async {
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      await controller.setVolume(muted ? 0 : 100);
    }
  }

  @override
  double get speed => _controller?.value.playbackSpeed ?? 1;

  @override
  Future<void> setSpeed(double speed) async {
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      await controller.setPlaybackSpeed(speed);
    }
  }

  @override
  Future<Uint8List?> captureFrame() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;
    return controller.takeSnapshot();
  }

  @override
  Widget buildPlayerWidget(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox();

    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) {
        final value = controller.value;
        // the entry size is often unknown for remote videos, so prefer the
        // dimensions libVLC reports once the media is loaded
        final double aspectRatio;
        if (value.isInitialized && value.size.width > 0 && value.size.height > 0) {
          aspectRatio = value.aspectRatio;
        } else {
          final displaySize = entry.displaySize;
          aspectRatio = displaySize.width > 0 && displaySize.height > 0 ? entry.displayAspectRatio : 1;
        }

        return VlcPlayer(
          controller: controller,
          aspectRatio: aspectRatio,
          placeholder: const SizedBox(),
        );
      },
    );
  }

  // tracks

  @override
  List<MediaTrackSummary> get tracks => const [];

  @override
  Future<MediaTrackSummary?> getSelectedTrack(MediaTrackType type) async => null;

  @override
  Future<void> selectTrack(MediaTrackType type, MediaTrackSummary? selected) async {
    // not supported by the libVLC backend (`canSelectTrackNotifier` is false)
  }
}
