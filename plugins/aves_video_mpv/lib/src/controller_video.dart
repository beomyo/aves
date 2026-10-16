import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aves_model/aves_model.dart';
import 'package:aves_utils/aves_utils.dart';
import 'package:aves_video/aves_video.dart';
import 'package:aves_video_mpv/aves_video_mpv.dart';
import 'package:aves_video_mpv/src/tracks.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

class MpvVideoController(
  super.entry, {
  required super.playbackStateHandler,
  required super.settings,
  // position to seek to when the media is first opened (resume)
  final int startMillis = 0,
}) extends AvesVideoController {
  late Player _mkPlayer;
  late PlaybackStatus _status;
  bool _firstFrameRendered = false, _abRepeatSeeking = false;
  final ValueNotifier<VideoController?> _mkControllerNotifier = ValueNotifier(null);
  final List<StreamSubscription> _subscriptions = [];
  final StreamController<PlaybackStatus> _statusStreamController = StreamController.broadcast();
  final StreamController<VideoEvent> _eventStreamController = StreamController.broadcast();
  final StreamController<String?> _timedTextStreamController = StreamController.broadcast();
  final AChangeNotifier _completedNotifier = AChangeNotifier();
  final List<SubtitleTrack> _externalSubtitleTracks = [];

  static final _pContext = p.Context();

  static final protocolWhitelist = [
    ...const PlayerConfiguration().protocolWhitelist,
    // Android `content` URIs are considered unsafe by default,
    // as they are transferred via a custom `fd` protocol
    'fd',
  ];

  @override
  double get minSpeed => .25;

  @override
  double get maxSpeed => 4;

  @override
  final ValueNotifier<bool> canCaptureFrameNotifier = ValueNotifier(true);

  @override
  final ValueNotifier<bool> canMuteNotifier = ValueNotifier(true);

  @override
  final ValueNotifier<bool> canSetSpeedNotifier = ValueNotifier(true);

  @override
  final ValueNotifier<bool> canSelectTrackNotifier = ValueNotifier(false);

  @override
  final ValueNotifier<double?> sarNotifier = ValueNotifier(null);

  this {
    _status = .idle;
    _statusStreamController.add(_status);

    _mkPlayer = Player(
      configuration: PlayerConfiguration(
        title: entry.bestTitle ?? entry.uri,
        libass: false,
        logLevel: .warn,
        protocolWhitelist: protocolWhitelist,
      ),
    );
    _initController();
    _init();

    _startListening();
  }

  @override
  Future<void> dispose() async {
    _stopListening();
    _stopTrackFetchTimer();
    await _statusStreamController.close();
    await _timedTextStreamController.close();
    await _mkPlayer.dispose();

    final _mkController = _mkControllerNotifier.value;
    _mkControllerNotifier.dispose();
    _mkController?.dispose();

    _completedNotifier.dispose();
    canCaptureFrameNotifier.dispose();
    canMuteNotifier.dispose();
    canSetSpeedNotifier.dispose();
    canSelectTrackNotifier.dispose();
    sarNotifier.dispose();

    await super.dispose();
  }

  void _startListening() {
    _subscriptions.add(statusStream.listen((v) => _status = v));

    final playerStream = _mkPlayer.stream;
    _subscriptions.add(
      playerStream.completed.listen((completed) {
        if (completed) {
          _statusStreamController.add(.completed);
          _completedNotifier.notify();

          // the player incorrectly loop for some videos
          // even when the playlist mode is configured not to loop
          // so we explicitly stop on completion
          final shouldStop = _mkPlayer.platform?.state.playlistMode == .none;
          if (shouldStop) {
            pause();
          }
        }
      }),
    );
    _subscriptions.add(
      playerStream.playing.listen((playing) {
        if (status == .idle) return;
        _statusStreamController.add(playing ? .playing : .paused);
      }),
    );
    _subscriptions.add(
      playerStream.position.listen((v) {
        final abRepeat = abRepeatNotifier.value;
        if (abRepeat != null && status == .playing) {
          final start = abRepeat.start;
          final end = abRepeat.end;
          if (start != null && end != null) {
            if (_toCaptureTime(v.inMilliseconds) < end) {
              _abRepeatSeeking = false;
            } else if (!_abRepeatSeeking) {
              _abRepeatSeeking = true;
              _mkPlayer.seek(Duration(milliseconds: _toPlaybackTime(start)));
            }
          }
        }

        if (!_abRepeatSeeking && isSlowMotion) {
          final targetSpeed = getSlowMotionTargetSpeed(
            currentPosition: currentPosition,
            duration: duration,
          );
          if (speed != targetSpeed) {
            setSpeed(targetSpeed);
          }
        }
      }),
    );
    _subscriptions.add(playerStream.subtitle.listen((v) => _timedTextStreamController.add(v.isEmpty ? null : v[0])));
    _subscriptions.add(playerStream.videoParams.listen((v) => sarNotifier.value = v.par));
    _subscriptions.add(playerStream.log.listen(_onPlayerLog));
    _subscriptions.add(playerStream.error.listen(_onPlayerError));

    final settingsStream = settings.updateStream;
    _subscriptions.add(settingsStream.where((event) => event.key == SettingKeys.videoHardwareAccelerationKey).listen((_) => _initController()));
    _subscriptions.add(settingsStream.where((event) => event.key == SettingKeys.videoLoopModeKey).listen((_) => _applyLoop()));

    final path = entry.path;
    if (path != null) {
      final videoBasename = _pContext.basenameWithoutExtension(path);
      // list subtitle files in the same directory
      // some files may be visible to the app (e.g. SRT) while others may not (e.g. SUB, VTT)
      _subscriptions.add(
        File(path).parent.list().where((v) => v is File && _isSubtitle(v.path)).listen((v) {
          final subtitleBasename = _pContext.basename(v.path);
          if (subtitleBasename.startsWith(videoBasename)) {
            _externalSubtitleTracks.add(
              SubtitleTrack.uri(
                v.uri.toString(),
                title: 'File ${subtitleBasename.substring(videoBasename.length)}',
              ),
            );
            _externalSubtitleTracks.sort((a, b) => a.title!.compareTo(b.title!));
          }
        }),
      );
    }
  }

  void _stopListening() {
    _subscriptions
      ..forEach((sub) => sub.cancel())
      ..clear();
  }

  Future<void> _updateSlowMotionFactor() async {
    final playbackFps = _videoTracks.firstOrNull?.fps;
    slowMotionFactor = await MpvVideoMetadataFetcher.computeSlowMotionFactor(_mkPlayer, playbackFps);
    canSetSpeedNotifier.value = !isSlowMotion;
  }

  Future<void> _applyLoop() => enableLoop(settings.videoLoopMode.shouldLoop(entry));

  Future<void> _init({int? resumeMillis}) async {
    final playing = _mkPlayer.state.playing;
    final start = resumeMillis ?? startMillis;

    // Audio quality is better with `audiotrack` than `opensles` (the default).
    // Calling `setAudioDevice` does not seem to work.
    // As of 2025/01/13, directly setting audio output via property works for some files but not all,
    // and switching from a supported file to an unsupported file crashes:
    // cf https://github.com/media-kit/media-kit/issues/1061

    await _applyLoop();

    // some remote sources carry credentials in the URL (e.g. WebDAV):
    // hand them to the player as an Authorization header, which mpv forwards,
    // instead of relying on the URL userinfo (not supported by every protocol)
    var mediaUri = entry.uri;
    final httpHeaders = <String, String>{};
    final parsedUri = Uri.tryParse(mediaUri);
    if (parsedUri != null && parsedUri.userInfo.isNotEmpty) {
      final parts = parsedUri.userInfo.split(':');
      final user = Uri.decodeComponent(parts.first);
      final password = parts.length > 1 ? Uri.decodeComponent(parts.sublist(1).join(':')) : '';
      httpHeaders['Authorization'] = 'Basic ${base64Encode(utf8.encode('$user:$password'))}';
      mediaUri = parsedUri.replace(userInfo: '').toString();
    }

    // network streams: favour a fast start over deep buffering
    if (parsedUri != null && (parsedUri.scheme == 'http' || parsedUri.scheme == 'https')) {
      final platform = _mkPlayer.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('cache', 'yes');
        // `media_kit` enables the on-disk demuxer cache by default, which makes
        // every network read hit the filesystem too; keep it in memory instead
        await platform.setProperty('cache-on-disk', 'no');
        // do not wait for the cache to fill before starting/resuming
        await platform.setProperty('cache-pause-initial', 'no');
        // bound how far ahead we buffer so the first frame is not delayed
        await platform.setProperty('cache-secs', '10');
        await platform.setProperty('demuxer-readahead-secs', '2');
        await platform.setProperty('demuxer-max-bytes', '${64 * 1024 * 1024}');
        // `libavformat` probes the container before the first frame is decoded;
        // the container headers are enough for the formats we stream, so bound
        // the probe (defaults are much larger and mostly waste time on network)
        await platform.setProperty('demuxer-lavf-analyzeduration', '1');
        await platform.setProperty('demuxer-lavf-probesize', '${1024 * 1024}');
        // read the stream in larger chunks to cut down on round trips
        await platform.setProperty('stream-buffer-size', '${2 * 1024 * 1024}');
        // report network stalls sooner than mpv's default instead of blocking
        await platform.setProperty('network-timeout', '10');
        // recover from transient drops instead of restarting the stream
        await platform.setProperty('stream-lavf-o', 'reconnect=1,reconnect_on_network_error=1');
      }
    }

    // seek while loading (mpv's `start` option) instead of after the first
    // frame: a post-ready seek on a network stream is slow (mpv must know the
    // duration first) and gets undone by the surface attach re-seek in
    // `media_kit_video`
    await _mkPlayer.open(
      Media(
        mediaUri,
        httpHeaders: httpHeaders.isEmpty ? null : httpHeaders,
        start: start > 0 ? Duration(milliseconds: start) : null,
      ),
      play: playing,
    );
    await _mkPlayer.setSubtitleTrack(SubtitleTrack.no());

    _fetchTracks();
    _statusStreamController.add(_mkPlayer.state.playing ? .playing : .paused);
  }

  void _initController() {
    _firstFrameRendered = false;

    final oldController = _mkControllerNotifier.value;
    final newController =
        VideoController(
            _mkPlayer,
            configuration: _toControllerConfiguration(settings.videoHardwareAcceleration),
          )
          ..waitUntilFirstFrameRendered.then((v) {
            _updateSlowMotionFactor();
            _firstFrameRendered = true;
            _statusStreamController.add(_status);
          });
    _mkControllerNotifier.value = newController;
    oldController?.dispose();
  }

  static VideoControllerConfiguration _toControllerConfiguration(VideoHardwareAcceleration hardwareAcceleration) {
    String hwdec;
    switch (hardwareAcceleration) {
      case .disabled:
        hwdec = 'no';
      case .enabled:
        hwdec = 'auto-safe';
      case .forced:
        // https://mpv.io/manual/stable/#options-hwdec says:
        // mediacodec is not safe. It forces RGB conversion (not with -copy) and
        // how well it handles non-standard colorspaces is not known.
        // In the rare cases where 10-bit is supported the bit depth of the output will be reduced to 8.
        hwdec = 'mediacodec'; // seems similar with 'mediacodec-copy'
    }
    // as of `media_kit_video` v2.0.1, the following properties are set internally:
    // - 'gpu-context': 'android',
    // - 'hwdec-codecs': 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1',
    return VideoControllerConfiguration(
      vo: 'gpu', // 'gpu-next' / 'mediacodec_embed' are not usable as of `media_kit_video` v2.0.1, `media_kit_libs_android_video` v1.3.8
      hwdec: hwdec, // default: 'auto-safe'
      enableHardwareAcceleration: hardwareAcceleration != .disabled,
      androidAttachSurfaceAfterVideoParameters: true,
    );
  }

  @override
  void onVisualChanged() => _init(resumeMillis: currentPosition);

  void _onPlayerLog(PlayerLog log) {
    debugPrint('libmpv log: $log');
    if (log.prefix == 'cplayer' && log.level == 'warn' && log.text == 'Audio device underrun detected.') {
      _eventStreamController.add(LagEvent());
    }
  }

  void _onPlayerError(String error) {
    debugPrint('libmpv error: $error');
  }

  @override
  Future<void> enableLoop(bool enabled) => _mkPlayer.setPlaylistMode(enabled ? .single : .none);

  @override
  Future<void> play() async {
    await untilReady;
    await _mkPlayer.play();
  }

  @override
  Future<void> pause() => _mkPlayer.pause();

  @override
  Future<void> seekTo(int targetMillis) async {
    if (!isReady) {
      await untilReady;
      // When the player gets ready, it can play from the beginning right away,
      // but trying to seek then just plays from the start.
      // There is no state or hook identifying readiness to seek on start,
      // and `PlayerConfiguration.ready` hook is useless.
      await Future.delayed(const Duration(milliseconds: 500));
    }
    targetMillis = abRepeatNotifier.value?.clamp(targetMillis) ?? targetMillis;
    await _mkPlayer.seek(Duration(milliseconds: _toPlaybackTime(targetMillis)));
  }

  @override
  Future<void> skipFrames(int frameCount) async {
    final platform = _mkPlayer.platform;
    if (platform is NativePlayer) {
      if (frameCount > 0) {
        await platform.command(['frame-step']);
      } else if (frameCount < 0) {
        await platform.command(['frame-back-step']);
      }
    } else {
      throw Exception('Platform player ${platform.runtimeType} does not support frame stepping');
    }
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
  Stream<double> get volumeStream => _mkPlayer.stream.volume;

  @override
  Stream<double> get speedStream => _mkPlayer.stream.rate.map((v) => v / slowMotionFactor);

  @override
  bool get isReady {
    switch (_status) {
      case .error:
      case .idle:
      case .initialized:
        return false;
      case .paused:
      case .playing:
      case .completed:
        return _firstFrameRendered;
    }
  }

  int _toCaptureTime(int videoTime) {
    return (videoTime / slowMotionFactor).round();
  }

  int _toPlaybackTime(int videoTime) {
    return videoTime * slowMotionFactor;
  }

  @override
  int get duration => _toCaptureTime(_mkPlayer.state.duration.inMilliseconds);

  @override
  int get currentPosition => _toCaptureTime(_mkPlayer.state.position.inMilliseconds);

  @override
  Stream<int> get positionStream => _mkPlayer.stream.position.map((pos) => _toCaptureTime(pos.inMilliseconds));

  @override
  Stream<String?> get timedTextStream => _timedTextStreamController.stream;

  @override
  bool get isMuted => _mkPlayer.state.volume == 0;

  @override
  Future<void> mute(bool muted) => _mkPlayer.setVolume(muted ? 0 : 100);

  @override
  double get speed => _mkPlayer.state.rate / slowMotionFactor;

  @override
  Future<void> setSpeed(double speed) => _mkPlayer.setRate(speed * slowMotionFactor);

  @override
  Future<Uint8List?> captureFrame() {
    // TODO TLAD rotate screenshot according to video rotation
    return _mkPlayer.screenshot();
  }

  @override
  Widget buildPlayerWidget(BuildContext context) {
    return ValueListenableBuilder<double?>(
      valueListenable: sarNotifier,
      builder: (context, sar, child) {
        // `entry.displayAspectRatio` falls back to 1 when the entry size is
        // unknown (e.g. remote entries), which would force a square viewport.
        // In that case let the player derive the aspect ratio from the video.
        final displaySize = entry.displaySize;
        final hasKnownSize = displaySize.width > 0 && displaySize.height > 0;
        if (hasKnownSize && sar == null) return const SizedBox();
        final aspectRatio = hasKnownSize ? entry.displayAspectRatio * sar! : null;

        return ValueListenableBuilder<VideoController?>(
          valueListenable: _mkControllerNotifier,
          builder: (context, controller, child) {
            if (controller == null) return const SizedBox();
            return Video(
              controller: controller,
              fill: Colors.transparent,
              aspectRatio: aspectRatio,
              controls: NoVideoControls,
              wakelock: false,
              subtitleViewConfiguration: const SubtitleViewConfiguration(
                visible: false,
              ),
            );
          },
        );
      },
    );
  }

  // tracks

  // `auto` and `no` are the first 2 tracks in the player state track lists
  static const int fakeTrackCount = 2;

  Tracks get _tracks => _mkPlayer.state.tracks;

  List<VideoTrack> get _videoTracks => _tracks.video.skip(fakeTrackCount).toList();

  List<AudioTrack> get _audioTracks => _tracks.audio.skip(fakeTrackCount).toList();

  List<SubtitleTrack> get _subtitleTracks {
    final externalTitles = _externalSubtitleTracks.map((v) => v.title).toSet();
    return [
      ..._tracks.subtitle.skip(fakeTrackCount).where((v) => !externalTitles.contains(v.title)),
      ..._externalSubtitleTracks,
    ];
  }

  @override
  List<MediaTrackSummary> get tracks {
    return {
      ..._videoTracks.mapIndexed((i, v) => v.toAves(i)),
      ..._audioTracks.mapIndexed((i, v) => v.toAves(i)),
      ..._subtitleTracks.mapIndexed((i, v) => v.toAves(i)),
    }.toList();
  }

  Timer? _trackFetchTimer;

  void _stopTrackFetchTimer() {
    _trackFetchTimer?.cancel();
    _trackFetchTimer = null;
  }

  void _fetchTracks() {
    _stopTrackFetchTimer();
    _trackFetchTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (status != .error) {
        if (_videoTracks.isEmpty && _audioTracks.isEmpty) return;

        final videoTrackCount = _videoTracks.length;
        final audioTrackCount = _audioTracks.length;
        final textTrackCount = _subtitleTracks.length;
        canSelectTrackNotifier.value = videoTrackCount > 1 || audioTrackCount > 1 || textTrackCount > 0;
      }
      _stopTrackFetchTimer();
    });
  }

  @override
  Future<MediaTrackSummary?> getSelectedTrack(MediaTrackType type) async {
    final track = _mkPlayer.state.track;
    switch (type) {
      case .video:
        final video = track.video;
        if (video != VideoTrack.no()) {
          final index = video == VideoTrack.auto() ? 0 : _videoTracks.indexOf(video);
          return video.toAves(index);
        }
      case .audio:
        final audio = track.audio;
        if (audio != AudioTrack.no()) {
          final index = audio == AudioTrack.auto() ? 0 : _audioTracks.indexOf(audio);
          return audio.toAves(index);
        }
      case .text:
        final subtitle = track.subtitle;
        if (subtitle != SubtitleTrack.no()) {
          final index = subtitle == SubtitleTrack.auto() ? 0 : _subtitleTracks.indexOf(subtitle);
          return subtitle.toAves(index);
        }
    }
    return null;
  }

  @override
  Future<void> selectTrack(MediaTrackType type, MediaTrackSummary? selected) async {
    final current = await getSelectedTrack(type);
    if (current == selected) return;

    if (selected != null) {
      final newIndex = selected.index;
      if (newIndex != null) {
        // select track
        switch (type) {
          case .video:
            await _mkPlayer.setVideoTrack(_videoTracks[selected.index ?? 0]);
            break;
          case .audio:
            await _mkPlayer.setAudioTrack(_audioTracks[selected.index ?? 0]);
            break;
          case .text:
            await _mkPlayer.setSubtitleTrack(_subtitleTracks[selected.index ?? 0]);
            break;
        }
      }
    } else if (current != null) {
      // deselect track
      switch (type) {
        case .video:
          await _mkPlayer.setVideoTrack(VideoTrack.no());
          break;
        case .audio:
          await _mkPlayer.setAudioTrack(AudioTrack.no());
          break;
        case .text:
          await _mkPlayer.setSubtitleTrack(SubtitleTrack.no());
          break;
      }
    }
  }

  static const Set<String> _subtitleExtensions = {'.srt', '.sub', '.vtt'};

  static bool _isSubtitle(String path) => _subtitleExtensions.contains(_pContext.extension(path));
}
