import 'dart:async';
import 'dart:ui' as ui;

import 'package:aves/model/entry/entry.dart';
import 'package:aves/services/common/cloud_registry.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/services/media/cloud_disk_cache.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves_model/aves_model.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

// Extracting a frame from a remote video is expensive (it spins up a background
// mpv session per video), so generation is limited to a couple of concurrent
// tasks and results are cached in memory and on disk.
class CloudVideoThumbnailLoader {
  static const int _maxConcurrent = 2;
  static const double _minExtent = 96;
  static const double _maxExtent = 480;

  final Map<String, Uint8List> _memory = {};
  final Set<String> _failed = {};
  final Map<String, Future<Uint8List?>> _inflight = {};
  int _active = 0;
  final List<Completer<void>> _waiters = [];

  Future<Uint8List?> load(String uri, String mimeType, double extent) {
    final cached = _memory[uri];
    if (cached != null) return Future.value(cached);
    if (_failed.contains(uri)) return Future.value(null);
    final existing = _inflight[uri];
    if (existing != null) return existing;
    final future = _run(uri, mimeType, extent).then((bytes) {
      if (bytes == null) {
        _failed.add(uri);
      } else {
        _memory[uri] = bytes;
      }
      return bytes;
    }).whenComplete(() => _inflight.remove(uri));
    _inflight[uri] = future;
    return future;
  }

  Future<Uint8List?> _run(String uri, String mimeType, double extent) async {
    final cacheKey = '$uri#vthumb';
    final disk = await cloudDiskCache.get(cacheKey);
    if (disk != null) {
      _memory[uri] = disk;
      return disk;
    }
    await _acquire();
    try {
      final bytes = await _generate(uri, mimeType, extent.clamp(_minExtent, _maxExtent));
      if (bytes != null) {
        await cloudDiskCache.put(cacheKey, bytes);
      }
      return bytes;
    } catch (error) {
      debugPrint('cloud video thumbnail failed uri=$uri error=$error');
      return null;
    } finally {
      _release();
    }
  }

  Future<Uint8List?> _generate(String uri, String mimeType, double extent) async {
    // the video backend streams the media itself, so hand it a playable URL
    final playable = await cloudRegistry.playbackUrl(uri);
    final descriptor = await videoMetadataFetcher.getThumbnailDescriptor(
      uri: playable,
      mimeType: mimeType,
      targetExtentDip: extent,
      methods: const [VideoThumbnailMethod.preview, VideoThumbnailMethod.first],
    );
    if (descriptor == null) return null;
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await descriptor.instantiateCodec(targetWidth: descriptor.width, targetHeight: descriptor.height);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor.dispose();
    }
  }

  Future<void> _acquire() async {
    while (_active >= _maxConcurrent) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _active++;
  }

  void _release() {
    _active--;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }
}

final cloudVideoThumbnailLoader = CloudVideoThumbnailLoader();

// video tile content: a real frame when one could be extracted, otherwise a
// dark placeholder with a play badge; optionally shows a watch progress bar
class CloudVideoThumbnail extends StatefulWidget {
  final AvesEntry entry;
  final double extent;
  final double devicePixelRatio;
  final ValueNotifier<bool> cancellableNotifier;
  final double? progress;

  const new({
    super.key,
    required this.entry,
    required this.extent,
    required this.devicePixelRatio,
    required this.cancellableNotifier,
    this.progress,
  });

  @override
  State<CloudVideoThumbnail> createState() => _CloudVideoThumbnailState();
}

class _CloudVideoThumbnailState extends State<CloudVideoThumbnail> {
  Uint8List? _bytes;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    widget.cancellableNotifier.addListener(_onScrollChanged);
    _maybeLoad();
  }

  @override
  void didUpdateWidget(covariant CloudVideoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.uri != widget.entry.uri) {
      setState(() {
        _bytes = null;
        _requested = false;
      });
      _maybeLoad();
    }
  }

  @override
  void dispose() {
    widget.cancellableNotifier.removeListener(_onScrollChanged);
    super.dispose();
  }

  void _onScrollChanged() {
    if (!widget.cancellableNotifier.value) _maybeLoad();
  }

  void _maybeLoad() {
    // defer the (expensive) frame extraction while the user is scrolling
    if (_requested || widget.cancellableNotifier.value) return;
    _requested = true;
    cloudVideoThumbnailLoader.load(widget.entry.uri, widget.entry.mimeType, widget.extent).then((bytes) {
      if (!mounted) return;
      if (bytes != null) setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final progress = widget.progress;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bytes != null)
          Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
        else
          const ColoredBox(color: Color(0x33000000)),
        const Center(
          child: DecoratedBox(
            decoration: BoxDecoration(color: Color(0x66000000), shape: BoxShape.circle),
            child: Padding(
              padding: EdgeInsets.all(6),
              child: Icon(AIcons.play, color: Colors.white, size: 20),
            ),
          ),
        ),
        if (progress != null && progress > 0)
          Align(
            alignment: Alignment.bottomCenter,
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Colors.redAccent),
            ),
          ),
      ],
    );
  }
}
