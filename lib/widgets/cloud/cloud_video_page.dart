import 'dart:async';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/theme/format.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/viewer/video/db_playback_state_handler.dart';
import 'package:aves/widgets/viewer/visual/video/video_view.dart';
import 'package:aves_video/aves_video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

// Full screen video player for remote (WebDAV / SMB) entries, reusing Aves'
// video stack. The mpv backend opens `entry.uri`, which is either an
// authenticated URL or the loopback SMB bridge.
class CloudVideoPage extends StatefulWidget {
  static const routeName = '/cloud/video';
  static const List<double> _speeds = [0.5, 0.75, 1, 1.25, 1.5, 2];

  final AvesEntry entry;

  // stable URL used as the key for the playback position
  final String? storageUri;

  const new({super.key, required this.entry, this.storageUri});

  @override
  State<CloudVideoPage> createState() => _CloudVideoPageState();
}

class _CloudVideoPageState extends State<CloudVideoPage> {
  AvesVideoController? _controller;
  StreamSubscription<PlaybackStatus>? _statusSub;
  StreamSubscription<int>? _positionSub;
  final ValueNotifier<int> _position = ValueNotifier(0);
  final TransformationController _transformationController = TransformationController();
  PlaybackStatus _status = PlaybackStatus.idle;
  bool _showControls = true;
  bool _keepScreenOn = false;
  bool _zoomed = false;
  bool _landscape = false;
  Timer? _hideTimer;
  Timer? _progressTimer;

  String get _storageUri => widget.storageUri ?? widget.entry.uri;

  @override
  void initState() {
    super.initState();
    _transformationController.addListener(_onTransformChanged);
    _createController();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    _saveProgress();
    _transformationController.removeListener(_onTransformChanged);
    _transformationController.dispose();
    _statusSub?.cancel();
    _positionSub?.cancel();
    _position.dispose();
    _setKeepScreenOn(false);
    _controller?.dispose();
    // restore the default (unspecified) orientation
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  void _onTransformChanged() {
    final zoomed = _transformationController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  // remember where we stopped, so the video can resume later
  void _saveProgress() {
    final controller = _controller;
    if (controller == null) return;
    final duration = controller.duration;
    final position = controller.currentPosition;
    if (duration <= 0 || position <= 0) return;
    // clear the resume point once the video is (almost) over
    settings.setCloudVideoProgress(_storageUri, position >= duration - 2000 ? 0 : position, duration);
  }

  void _toggleOrientation() {
    setState(() => _landscape = !_landscape);
    SystemChrome.setPreferredOrientations(
      _landscape ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : const [DeviceOrientation.portraitUp],
    );
    _scheduleHideControls();
  }

  void _createController() {
    _statusSub?.cancel();
    _positionSub?.cancel();
    final controller = videoControllerFactory.buildController(
      widget.entry,
      playbackStateHandler: DatabasePlaybackStateHandler(),
      settings: settings,
    );
    _controller = controller;
    _status = PlaybackStatus.idle;
    _statusSub = controller.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _status = status);
      _setKeepScreenOn(status == PlaybackStatus.playing);
      if (status == PlaybackStatus.playing) _scheduleHideControls();
    });
    _positionSub = controller.positionStream.listen((position) {
      if (mounted) _position.value = position;
    });
    // the player opens the media paused, so wait until it is ready to resume
    // where we stopped (if anywhere) and start
    final resume = settings.cloudVideoPosition(_storageUri) ?? 0;
    controller.untilReady.then((_) async {
      if (!mounted || !identical(_controller, controller)) return;
      final duration = controller.duration;
      if (resume > 0 && (duration <= 0 || resume < duration - 2000)) {
        await controller.seekTo(resume);
      }
      if (mounted && identical(_controller, controller)) unawaited(controller.play());
    });
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
    _scheduleHideControls();
  }

  Future<void> _retry() async {
    final old = _controller;
    setState(_createController);
    await old?.dispose();
  }

  Future<void> _setKeepScreenOn(bool on) async {
    if (_keepScreenOn == on) return;
    _keepScreenOn = on;
    if (on) {
      await windowService.keepScreenOn(true);
    } else {
      await windowService.keepScreenOn(false);
    }
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    if (!(_controller?.isPlaying ?? false)) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHideControls();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final hasError = _status == PlaybackStatus.error;
    final ready = controller?.isReady ?? false;

    return AvesScaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null)
            Positioned.fill(
              child: GestureDetector(
                // tap toggles the controls, while two fingers pinch to zoom
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                child: InteractiveViewer(
                  transformationController: _transformationController,
                  minScale: 1,
                  maxScale: 5,
                  panEnabled: _zoomed,
                  child: Center(child: VideoView(entry: widget.entry, controller: controller)),
                ),
              ),
            ),
          if (controller != null && ready && !controller.isPlaying && _showControls)
            Center(
              child: IconButton(
                iconSize: 72,
                color: Colors.white70,
                icon: const Icon(AIcons.play),
                onPressed: () {
                  controller.play();
                  _scheduleHideControls();
                },
              ),
            ),
          if (!ready && !hasError) const Center(child: CircularProgressIndicator()),
          if (hasError)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(context.l10n.webdavVideoError, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                    const SizedBox(height: 16),
                    OutlinedButton(onPressed: _retry, child: Text(context.l10n.webdavRefresh)),
                  ],
                ),
              ),
            ),
          if (controller != null) _buildTopBar(context, controller),
          if (controller != null) _buildBottomBar(context, controller),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, AvesVideoController controller) {
    final title = widget.entry.sourceTitle ?? widget.entry.bestTitle ?? '';
    final duration = controller.duration;
    final subtitle = duration > 0 ? formatFriendlyDuration(Duration(milliseconds: duration)) : null;
    return Align(
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        opacity: _showControls ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !_showControls,
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 4, bottom: 24),
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black87, Colors.transparent]),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  color: Colors.white,
                  onPressed: () => Navigator.maybePop(context),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16)),
                      if (subtitle != null) Text(subtitle, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: _landscape ? context.l10n.webdavOrientationPortrait : context.l10n.webdavOrientationLandscape,
                  icon: Icon(_landscape ? Icons.stay_current_portrait : Icons.stay_current_landscape),
                  color: Colors.white,
                  onPressed: _toggleOrientation,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context, AvesVideoController controller) {
    final playing = controller.isPlaying;
    final muted = controller.isMuted;
    final speed = controller.speed;
    return Align(
      alignment: Alignment.bottomCenter,
      child: AnimatedOpacity(
        opacity: _showControls ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !_showControls,
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.only(top: 24, bottom: MediaQuery.paddingOf(context).bottom + 8),
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent]),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SeekBar(controller: controller, position: _position),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(AIcons.replay10),
                      onPressed: () => _seekBy(controller, -10),
                    ),
                    IconButton(
                      iconSize: 44,
                      color: Colors.white,
                      icon: Icon(playing ? AIcons.pause : AIcons.play),
                      onPressed: () {
                        if (playing) {
                          controller.pause();
                        } else {
                          controller.play();
                          _scheduleHideControls();
                        }
                      },
                    ),
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(AIcons.skip10),
                      onPressed: () => _seekBy(controller, 10),
                    ),
                    IconButton(
                      color: Colors.white,
                      icon: Icon(muted ? AIcons.mute : AIcons.unmute),
                      onPressed: () => controller.mute(!muted),
                    ),
                    PopupMenuButton<double>(
                      tooltip: '',
                      itemBuilder: (context) => [
                        for (final s in CloudVideoPage._speeds) PopupMenuItem(value: s, child: Text(_formatSpeed(s))),
                      ],
                      onSelected: (v) => controller.setSpeed(v),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_formatSpeed(speed), style: const TextStyle(color: Colors.white, fontSize: 14)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _seekBy(AvesVideoController controller, int seconds) {
    final duration = controller.duration;
    final target = (controller.currentPosition + seconds * 1000).clamp(0, duration);
    controller.seekTo(target);
    _scheduleHideControls();
  }

  static String _formatSpeed(double speed) => '${speed == speed.roundToDouble() ? speed.toStringAsFixed(1) : speed}x';
}

class _SeekBar extends StatefulWidget {
  final AvesVideoController controller;
  final ValueListenable<int> position;

  const new({required this.controller, required this.position});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  static const _timeStyle = TextStyle(color: Colors.white70, fontSize: 12);
  int? _dragPosition;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.position,
      builder: (context, position, child) {
        final duration = widget.controller.duration;
        final current = (_dragPosition ?? position).clamp(0, duration <= 0 ? 1 : duration);
        return Row(
          children: [
            SizedBox(width: 56, child: Text(formatFriendlyDuration(Duration(milliseconds: current)), textAlign: TextAlign.center, style: _timeStyle)),
            Expanded(
              child: Slider(
                value: duration > 0 ? (current / duration).clamp(0.0, 1.0) : 0.0,
                onChanged: duration > 0
                    ? (v) => setState(() => _dragPosition = (v * duration).round())
                    : null,
                onChangeEnd: duration > 0
                    ? (v) {
                        widget.controller.seekTo((v * duration).round());
                        setState(() => _dragPosition = null);
                      }
                    : null,
              ),
            ),
            SizedBox(width: 56, child: Text(formatFriendlyDuration(Duration(milliseconds: duration)), textAlign: TextAlign.center, style: _timeStyle)),
          ],
        );
      },
    );
  }
}
