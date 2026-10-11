import 'dart:async';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/viewer/video/db_playback_state_handler.dart';
import 'package:aves/widgets/viewer/visual/video/video_view.dart';
import 'package:aves_video/aves_video.dart';
import 'package:material_ui/material_ui.dart';

// Minimal video player for remote (WebDAV) entries, reusing Aves' video stack.
// The mpv backend opens `entry.uri` directly, so an http(s) URL plays as is.
class WebDavVideoPage extends StatefulWidget {
  static const routeName = '/webdav/video';

  final AvesEntry entry;

  const new({super.key, required this.entry});

  @override
  State<WebDavVideoPage> createState() => _WebDavVideoPageState();
}

class _WebDavVideoPageState extends State<WebDavVideoPage> {
  AvesVideoController? _controller;
  StreamSubscription<PlaybackStatus>? _statusSub;
  PlaybackStatus _status = PlaybackStatus.idle;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _createController();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _statusSub?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  void _createController() {
    _statusSub?.cancel();
    final controller = videoControllerFactory.buildController(
      widget.entry,
      playbackStateHandler: DatabasePlaybackStateHandler(),
      settings: settings,
    );
    _controller = controller;
    _status = PlaybackStatus.idle;
    _statusSub = controller.statusStream.listen((status) {
      if (mounted) setState(() => _status = status);
    });
    // the player opens the media paused, so wait until it is ready to start
    controller.untilReady.then((_) {
      if (mounted && identical(_controller, controller)) controller.play();
    });
    _scheduleHideControls();
  }

  Future<void> _retry() async {
    final old = _controller;
    setState(_createController);
    await old?.dispose();
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
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
    final l10n = context.l10n;
    final title = widget.entry.sourceTitle ?? widget.entry.bestTitle ?? '';
    final controller = _controller;
    final hasError = _status == PlaybackStatus.error;
    final ready = controller?.isReady ?? false;

    return AvesScaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            children: [
              if (controller != null) Center(child: VideoView(entry: widget.entry, controller: controller)),
              if (!ready && !hasError) const Center(child: CircularProgressIndicator()),
              if (hasError)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(l10n.webdavVideoError, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          onPressed: _retry,
                          child: Text(l10n.webdavRefresh),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _showControls && controller != null ? _buildControls(controller) : null,
    );
  }

  Widget _buildControls(AvesVideoController controller) {
    return Material(
      color: Colors.black,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: StreamBuilder<int>(
                stream: controller.positionStream,
                builder: (context, snapshot) {
                  final position = snapshot.data ?? 0;
                  final duration = controller.duration;
                  return Slider(
                    value: duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0,
                    onChanged: duration > 0 ? (v) => controller.seekTo((v * duration).round()) : null,
                  );
                },
              ),
            ),
            StreamBuilder<PlaybackStatus>(
              stream: controller.statusStream,
              builder: (context, snapshot) {
                final playing = controller.isPlaying;
                return IconButton(
                  iconSize: 36,
                  color: Colors.white,
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  onPressed: () {
                    if (playing) {
                      controller.pause();
                    } else {
                      controller.play();
                    }
                    _scheduleHideControls();
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
