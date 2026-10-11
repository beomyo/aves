import 'dart:async';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
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
  late final AvesVideoController _controller;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _controller = videoControllerFactory.buildController(
      widget.entry,
      playbackStateHandler: DatabasePlaybackStateHandler(),
      settings: settings,
    );
    _controller.play();
    _scheduleHideControls();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.dispose();
    super.dispose();
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
    final title = widget.entry.sourceTitle ?? widget.entry.bestTitle ?? '';
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
          child: Center(
            child: VideoView(entry: widget.entry, controller: _controller),
          ),
        ),
      ),
      bottomNavigationBar: _showControls ? _buildControls() : null,
    );
  }

  Widget _buildControls() {
    return Material(
      color: Colors.black,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: StreamBuilder<int>(
                stream: _controller.positionStream,
                builder: (context, snapshot) {
                  final position = snapshot.data ?? 0;
                  final duration = _controller.duration;
                  return Slider(
                    value: duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0,
                    onChanged: duration > 0 ? (v) => _controller.seekTo((v * duration).round()) : null,
                  );
                },
              ),
            ),
            StreamBuilder<PlaybackStatus>(
              stream: _controller.statusStream,
              builder: (context, snapshot) {
                final playing = _controller.isPlaying;
                return IconButton(
                  iconSize: 36,
                  color: Colors.white,
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  onPressed: () {
                    if (playing) {
                      _controller.pause();
                    } else {
                      _controller.play();
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
