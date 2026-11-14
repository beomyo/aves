import 'dart:math' as math;

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/images.dart';
import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/thumbnail/image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

class CloudViewerPage extends StatefulWidget {
  static const routeName = '/cloud/viewer';

  final List<AvesEntry> entries;
  final int initialIndex;

  const new({
    super.key,
    required this.entries,
    required this.initialIndex,
  });

  @override
  State<CloudViewerPage> createState() => _CloudViewerPageState();
}

class _CloudViewerPageState extends State<CloudViewerPage> {
  static const double _stripHeight = 76;
  static const double _stripWidth = 68;
  static const double _barWidth = 48;

  late final int _initialIndex;
  late final PageController _pageController;
  late final ValueNotifier<int> _indexNotifier;
  final GlobalKey<_ContinuousStripViewState> _continuousKey = GlobalKey();

  // paging is blocked while the user pinches or has zoomed in, so trying to
  // zoom never flips to the neighbouring image
  final ValueNotifier<bool> _blockPaging = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _initialIndex = widget.initialIndex.clamp(0, widget.entries.isEmpty ? 0 : widget.entries.length - 1);
    _pageController = PageController(initialPage: _initialIndex);
    _indexNotifier = ValueNotifier(_initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _indexNotifier.dispose();
    _blockPaging.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    if (index < 0 || index >= widget.entries.length) return;
    if (settings.cloudViewerLayoutMode == 'continuous') {
      _continuousKey.currentState?.scrollToIndex(index);
    } else {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(index);
      }
    }
  }

  void _openViewerSettings(BuildContext context) {
    final l10n = context.l10n;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xF0181818),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final mode = settings.cloudViewerLayoutMode;
          final showStrip = settings.cloudViewerThumbnails;
          final stripPos = settings.cloudViewerThumbnailsPosition;
          final showBar = settings.cloudViewerProgressBar;
          final barPos = settings.cloudViewerProgressBarPosition;

          Widget buildPosChips({required String current, required ValueChanged<String> onSelected}) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ChoiceChip(
                  label: Text(l10n.cloudViewerPositionBottom),
                  selected: current == 'bottom',
                  onSelected: (selected) {
                    if (selected) onSelected('bottom');
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text(l10n.cloudViewerPositionLeft),
                  selected: current == 'left',
                  onSelected: (selected) {
                    if (selected) onSelected('left');
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text(l10n.cloudViewerPositionRight),
                  selected: current == 'right',
                  onSelected: (selected) {
                    if (selected) onSelected('right');
                  },
                ),
              ],
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        l10n.cloudViewerSettings,
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.maybePop(context),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white24),
                  // Browsing mode
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.cloudViewerMode, style: const TextStyle(color: Colors.white)),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          ChoiceChip(
                            label: Text(l10n.cloudViewerModePaged),
                            selected: mode == 'paged',
                            onSelected: (selected) {
                              if (selected) {
                                settings.cloudViewerLayoutMode = 'paged';
                                setSheetState(() {});
                                setState(() {});
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  if (_pageController.hasClients) {
                                    _pageController.jumpToPage(_indexNotifier.value);
                                  }
                                });
                              }
                            },
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: Text(l10n.cloudViewerModeContinuous),
                            selected: mode == 'continuous',
                            onSelected: (selected) {
                              if (selected) {
                                settings.cloudViewerLayoutMode = 'continuous';
                                setSheetState(() {});
                                setState(() {});
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(color: Colors.white24),
                  // Thumbnail strip
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.cloudViewerThumbnails, style: const TextStyle(color: Colors.white)),
                    value: showStrip,
                    onChanged: (v) {
                      settings.cloudViewerThumbnails = v;
                      setSheetState(() {});
                      setState(() {});
                    },
                  ),
                  if (showStrip)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Text('${l10n.cloudViewerPosition}: ', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                          buildPosChips(
                            current: stripPos,
                            onSelected: (pos) {
                              settings.cloudViewerThumbnailsPosition = pos;
                              setSheetState(() {});
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  const Divider(color: Colors.white24),
                  // Progress bar
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.cloudViewerProgressBar, style: const TextStyle(color: Colors.white)),
                    value: showBar,
                    onChanged: (v) {
                      settings.cloudViewerProgressBar = v;
                      setSheetState(() {});
                      setState(() {});
                    },
                  ),
                  if (showBar)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Text('${l10n.cloudViewerPosition}: ', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                          buildPosChips(
                            current: barPos,
                            onSelected: (pos) {
                              settings.cloudViewerProgressBarPosition = pos;
                              setSheetState(() {});
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    if (entries.isEmpty) {
      return const AvesScaffold(backgroundColor: Colors.black);
    }
    final showStrip = settings.cloudViewerThumbnails;
    final stripPos = settings.cloudViewerThumbnailsPosition;
    final showProgressBar = settings.cloudViewerProgressBar && entries.length > 1;
    final barPos = settings.cloudViewerProgressBarPosition;
    final layoutMode = settings.cloudViewerLayoutMode;

    final hasBottom = (showProgressBar && barPos == 'bottom') || (showStrip && stripPos == 'bottom');
    final hasLeft = (showProgressBar && barPos == 'left') || (showStrip && stripPos == 'left');
    final hasRight = (showProgressBar && barPos == 'right') || (showStrip && stripPos == 'right');

    final topInset = MediaQuery.paddingOf(context).top + 52;
    final bottomInset = MediaQuery.paddingOf(context).bottom + (hasBottom ? _stripHeight : 0);

    return AvesScaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (layoutMode == 'continuous')
            _ContinuousStripView(
              key: _continuousKey,
              entries: entries,
              indexNotifier: _indexNotifier,
              initialIndex: _indexNotifier.value,
              onBlockPaging: (value) => _blockPaging.value = value,
            )
          else
            ValueListenableBuilder<bool>(
              valueListenable: _blockPaging,
              builder: (context, blocked, child) => PageView.builder(
                controller: _pageController,
                physics: blocked ? const NeverScrollableScrollPhysics() : const _ViewerPageScrollPhysics(),
                onPageChanged: (index) {
                  _indexNotifier.value = index;
                  _blockPaging.value = false;
                },
                itemCount: entries.length,
                itemBuilder: (context, index) => _RemoteImagePage(
                  entry: entries[index],
                  onBlockPaging: (value) => _blockPaging.value = value,
                ),
              ),
            ),
          // Top app bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  const Spacer(),
                  ValueListenableBuilder<int>(
                    valueListenable: _indexNotifier,
                    builder: (context, index, child) => Text(
                      '${index + 1} / ${entries.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.cloudViewerSettings,
                    color: Colors.white,
                    icon: const Icon(Icons.tune),
                    onPressed: () => _openViewerSettings(context),
                  ),
                ],
              ),
            ),
          ),
          // Left overlay
          if (hasLeft)
            Positioned(
              left: 0,
              top: topInset,
              bottom: bottomInset,
              child: Container(
                padding: EdgeInsets.only(left: MediaQuery.paddingOf(context).left),
                color: const Color(0xCC000000),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showProgressBar && barPos == 'left')
                      SizedBox(
                        width: _barWidth,
                        child: _ImageProgressBar(
                          count: entries.length,
                          index: _indexNotifier,
                          onIndexChanged: _goTo,
                          axis: Axis.vertical,
                        ),
                      ),
                    if (showStrip && stripPos == 'left')
                      SizedBox(
                        width: _stripWidth,
                        child: _ThumbnailStrip(
                          entries: entries,
                          index: _indexNotifier,
                          onTap: _goTo,
                          axis: Axis.vertical,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          // Right overlay
          if (hasRight)
            Positioned(
              right: 0,
              top: topInset,
              bottom: bottomInset,
              child: Container(
                padding: EdgeInsets.only(right: MediaQuery.paddingOf(context).right),
                color: const Color(0xCC000000),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showStrip && stripPos == 'right')
                      SizedBox(
                        width: _stripWidth,
                        child: _ThumbnailStrip(
                          entries: entries,
                          index: _indexNotifier,
                          onTap: _goTo,
                          axis: Axis.vertical,
                        ),
                      ),
                    if (showProgressBar && barPos == 'right')
                      SizedBox(
                        width: _barWidth,
                        child: _ImageProgressBar(
                          count: entries.length,
                          index: _indexNotifier,
                          onIndexChanged: _goTo,
                          axis: Axis.vertical,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          // Bottom overlay
          if (hasBottom)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
                color: const Color(0xCC000000),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showProgressBar && barPos == 'bottom')
                      _ImageProgressBar(
                        count: entries.length,
                        index: _indexNotifier,
                        onIndexChanged: _goTo,
                        axis: Axis.horizontal,
                      ),
                    if (showStrip && stripPos == 'bottom')
                      SizedBox(
                        height: _stripHeight,
                        child: _ThumbnailStrip(
                          entries: entries,
                          index: _indexNotifier,
                          onTap: _goTo,
                          axis: Axis.horizontal,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// continuous horizontal strip view that places all images side by side seamlessly with zoom support
class _ContinuousStripView extends StatefulWidget {
  final List<AvesEntry> entries;
  final ValueNotifier<int> indexNotifier;
  final int initialIndex;
  final ValueChanged<bool> onBlockPaging;

  const new({
    super.key,
    required this.entries,
    required this.indexNotifier,
    required this.initialIndex,
    required this.onBlockPaging,
  });

  @override
  State<_ContinuousStripView> createState() => _ContinuousStripViewState();
}

class _ContinuousStripViewState extends State<_ContinuousStripView> with SingleTickerProviderStateMixin {
  static const double _doubleTapScale = 2.5;

  late final ScrollController _scrollController;
  final TransformationController _transformationController = TransformationController();
  late final AnimationController _zoomAnimation;
  late final CurvedAnimation _zoomCurve;
  Matrix4Tween? _zoomTween;
  Offset? _doubleTapPosition;
  bool _zoomed = false;
  bool _multiTouch = false;
  int _pointers = 0;
  bool _isProgrammaticScroll = false;
  final Map<String, double> _aspects = {};

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _zoomAnimation = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    _zoomCurve = CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOutCubic)..addListener(_onZoomTick);
    _transformationController.addListener(_onTransformChanged);
    widget.indexNotifier.addListener(_onExternalIndexChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.initialIndex > 0) {
        scrollToIndex(widget.initialIndex, animate: false);
      }
    });
  }

  @override
  void dispose() {
    if (_zoomed || _multiTouch) {
      final notify = widget.onBlockPaging;
      WidgetsBinding.instance.addPostFrameCallback((_) => notify(false));
    }
    widget.indexNotifier.removeListener(_onExternalIndexChanged);
    _scrollController.dispose();
    _zoomCurve
      ..removeListener(_onZoomTick)
      ..dispose();
    _zoomAnimation.dispose();
    _transformationController.removeListener(_onTransformChanged);
    _transformationController.dispose();
    super.dispose();
  }

  double _aspectOf(AvesEntry entry) {
    final cached = _aspects[entry.uri];
    if (cached != null) return cached;
    if (entry.width > 0 && entry.height > 0) {
      return (entry.width / entry.height).clamp(0.2, 5.0);
    }
    final dim = settings.cloudImageDimensions(entry.uri);
    if (dim != null && dim.$1 > 0 && dim.$2 > 0) {
      return (dim.$1 / dim.$2).clamp(0.2, 5.0);
    }
    return (entry.isVideo ? 16 / 9 : 1.0);
  }

  void _onImageInfo(AvesEntry entry, ImageInfo info) {
    final w = info.image.width;
    final h = info.image.height;
    if (w > 0 && h > 0) {
      entry.width = w;
      entry.height = h;
      settings.setCloudImageDimensions(entry.uri, w, h);
      final aspect = (w / h).clamp(0.2, 5.0);
      if (_aspects[entry.uri] != aspect) {
        _aspects[entry.uri] = aspect;
        if (mounted) setState(() {});
      }
    }
  }

  void _onZoomTick() {
    final tween = _zoomTween;
    if (tween != null) {
      _transformationController.value = tween.evaluate(_zoomCurve);
    }
  }

  void _onTransformChanged() {
    final zoomed = _transformationController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      if (mounted) {
        setState(() => _zoomed = zoomed);
      } else {
        _zoomed = zoomed;
      }
      _notify();
    }
  }

  void _setMultiTouch(bool value) {
    if (value == _multiTouch) return;
    _multiTouch = value;
    _notify();
  }

  void _notify() => widget.onBlockPaging(_zoomed || _multiTouch);

  void _onPointerDown(PointerDownEvent event) {
    _pointers++;
    if (_pointers >= 2) _setMultiTouch(true);
  }

  void _onPointerUp(PointerEvent event) {
    _pointers = math.max(0, _pointers - 1);
    if (_pointers < 2) _setMultiTouch(false);
  }

  void _handleDoubleTap() {
    final target = _zoomed ? Matrix4.identity() : _zoomMatrix(_doubleTapPosition ?? Offset.zero, _doubleTapScale);
    _zoomTween = Matrix4Tween(begin: _transformationController.value.clone(), end: target);
    _zoomAnimation.forward(from: 0);
  }

  Matrix4 _zoomMatrix(Offset focal, double scale) {
    final size = context.size ?? Size.zero;
    final maxX = math.max(0.0, size.width * (scale - 1));
    final maxY = math.max(0.0, size.height * (scale - 1));
    final tx = (-focal.dx * (scale - 1)).clamp(-maxX, 0.0);
    final ty = (-focal.dy * (scale - 1)).clamp(-maxY, 0.0);
    return Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _onExternalIndexChanged() {
    if (_isProgrammaticScroll) return;
    scrollToIndex(widget.indexNotifier.value);
  }

  void scrollToIndex(int index, {bool animate = true}) {
    if (!_scrollController.hasClients || index < 0 || index >= widget.entries.length) return;
    final viewportHeight = MediaQuery.sizeOf(context).height;
    double offset = 0;
    for (var i = 0; i < index; i++) {
      offset += viewportHeight * _aspectOf(widget.entries[i]);
    }
    final target = offset.clamp(0.0, _scrollController.position.maxScrollExtent);
    _isProgrammaticScroll = true;
    if (animate) {
      _scrollController.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut).then((_) {
        _isProgrammaticScroll = false;
      });
    } else {
      _scrollController.jumpTo(target);
      _isProgrammaticScroll = false;
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (_isProgrammaticScroll) return false;
    if (notification is ScrollUpdateNotification) {
      final viewportHeight = MediaQuery.sizeOf(context).height;
      final viewportWidth = MediaQuery.sizeOf(context).width;
      final center = _scrollController.offset + viewportWidth / 2;
      double accumulated = 0;
      int centerIndex = 0;
      for (var i = 0; i < widget.entries.length; i++) {
        final w = viewportHeight * _aspectOf(widget.entries[i]);
        if (center < accumulated + w || i == widget.entries.length - 1) {
          centerIndex = i;
          break;
        }
        accumulated += w;
      }
      if (widget.indexNotifier.value != centerIndex) {
        _isProgrammaticScroll = true;
        widget.indexNotifier.value = centerIndex;
        _isProgrammaticScroll = false;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
        onDoubleTap: _handleDoubleTap,
        child: InteractiveViewer(
          transformationController: _transformationController,
          panEnabled: _zoomed,
          minScale: 1.0,
          maxScale: 6.0,
          onInteractionStart: (details) => _setMultiTouch(details.pointerCount >= 2),
          onInteractionUpdate: (details) => _setMultiTouch(details.pointerCount >= 2),
          onInteractionEnd: (details) => _setMultiTouch(false),
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: ListView.builder(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
              physics: _zoomed ? const NeverScrollableScrollPhysics() : const ClampingScrollPhysics(),
              itemCount: widget.entries.length,
              itemBuilder: (context, index) {
                final entry = widget.entries[index];
                final aspect = _aspectOf(entry);
                final itemWidth = math.max(48.0, viewportHeight * aspect);
                return SizedBox(
                  height: viewportHeight,
                  width: itemWidth,
                  child: _StripTile(
                    entry: entry,
                    onImageInfo: (info) => _onImageInfo(entry, info),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _StripTile extends StatefulWidget {
  final AvesEntry entry;
  final ValueChanged<ImageInfo>? onImageInfo;

  const new({required this.entry, this.onImageInfo});

  @override
  State<_StripTile> createState() => _StripTileState();
}

class _StripTileState extends State<_StripTile> {
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant _StripTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.uri != widget.entry.uri) {
      _unsubscribe();
      _subscribe();
    }
  }

  void _subscribe() {
    if (widget.onImageInfo == null) return;
    final provider = widget.entry.getFullImage();
    _stream = provider.resolve(ImageConfiguration.empty);
    _listener = ImageStreamListener((info, _) {
      widget.onImageInfo?.call(info);
    });
    _stream?.addListener(_listener!);
  }

  void _unsubscribe() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: widget.entry.bestCachedThumbnail,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, error, stack) => const SizedBox.shrink(),
        ),
        Image(
          image: widget.entry.getFullImage(),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) {
              return child;
            }
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 180),
              child: child,
            );
          },
          errorBuilder: (context, error, stack) => const Center(
            child: Icon(AIcons.error, color: Colors.white54, size: 48),
          ),
        ),
      ],
    );
  }
}

// paging that needs a longer, more deliberate drag than the default, which
// avoids changing image when the user meant to pinch
class _ViewerPageScrollPhysics extends PageScrollPhysics {
  const new({super.parent});

  @override
  _ViewerPageScrollPhysics applyTo(ScrollPhysics? ancestor) => _ViewerPageScrollPhysics(parent: buildParent(ancestor));

  @override
  double get dragStartDistanceMotionThreshold => 48;
}

class _RemoteImagePage extends StatefulWidget {
  final AvesEntry entry;
  final ValueChanged<bool> onBlockPaging;

  const new({required this.entry, required this.onBlockPaging});

  @override
  State<_RemoteImagePage> createState() => _RemoteImagePageState();
}

class _RemoteImagePageState extends State<_RemoteImagePage> with SingleTickerProviderStateMixin {
  static const double _doubleTapScale = 2.5;

  final TransformationController _transformationController = TransformationController();
  late final AnimationController _zoomAnimation;
  late final CurvedAnimation _zoomCurve;
  Matrix4Tween? _zoomTween;
  Offset? _doubleTapPosition;
  bool _zoomed = false;
  bool _multiTouch = false;
  int _pointers = 0;

  @override
  void initState() {
    super.initState();
    _zoomAnimation = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    _zoomCurve = CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOutCubic)..addListener(_onZoomTick);
    _transformationController.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    if (_zoomed || _multiTouch) {
      final notify = widget.onBlockPaging;
      WidgetsBinding.instance.addPostFrameCallback((_) => notify(false));
    }
    _zoomCurve
      ..removeListener(_onZoomTick)
      ..dispose();
    _zoomAnimation.dispose();
    _transformationController.removeListener(_onTransformChanged);
    _transformationController.dispose();
    super.dispose();
  }

  void _onZoomTick() {
    final tween = _zoomTween;
    if (tween != null) {
      _transformationController.value = tween.evaluate(_zoomCurve);
    }
  }

  void _onTransformChanged() {
    final zoomed = _transformationController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      if (mounted) {
        setState(() {
          _zoomed = zoomed;
        });
      } else {
        _zoomed = zoomed;
      }
      _notify();
    }
  }

  void _setMultiTouch(bool value) {
    if (value == _multiTouch) return;
    _multiTouch = value;
    _notify();
  }

  void _notify() => widget.onBlockPaging(_zoomed || _multiTouch);

  void _onPointerDown(PointerDownEvent event) {
    _pointers++;
    if (_pointers >= 2) _setMultiTouch(true);
  }

  void _onPointerUp(PointerEvent event) {
    _pointers = math.max(0, _pointers - 1);
    if (_pointers < 2) _setMultiTouch(false);
  }

  void _handleDoubleTap() {
    final target = _zoomed ? Matrix4.identity() : _zoomMatrix(_doubleTapPosition ?? Offset.zero, _doubleTapScale);
    _zoomTween = Matrix4Tween(begin: _transformationController.value.clone(), end: target);
    _zoomAnimation.forward(from: 0);
  }

  Matrix4 _zoomMatrix(Offset focal, double scale) {
    final size = context.size ?? Size.zero;
    final maxX = math.max(0.0, size.width * (scale - 1));
    final maxY = math.max(0.0, size.height * (scale - 1));
    final tx = (-focal.dx * (scale - 1)).clamp(-maxX, 0.0);
    final ty = (-focal.dy * (scale - 1)).clamp(-maxY, 0.0);
    return Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
        onDoubleTap: _handleDoubleTap,
        child: InteractiveViewer(
          transformationController: _transformationController,
          panEnabled: _zoomed,
          minScale: 1,
          maxScale: 6,
          onInteractionStart: (details) => _setMultiTouch(details.pointerCount >= 2),
          onInteractionUpdate: (details) => _setMultiTouch(details.pointerCount >= 2),
          onInteractionEnd: (details) => _setMultiTouch(false),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image(
                image: widget.entry.bestCachedThumbnail,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (context, error, stack) => const SizedBox.shrink(),
              ),
              Image(
                image: widget.entry.getFullImage(),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded) return child;
                  return AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 180),
                    child: child,
                  );
                },
                errorBuilder: (context, error, stack) => const Center(
                  child: Icon(
                    AIcons.error,
                    color: Colors.white54,
                    size: 48,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// strip of thumbnails used to jump quickly between nearby images (supports horizontal or vertical axis)
class _ThumbnailStrip extends StatefulWidget {
  final List<AvesEntry> entries;
  final ValueNotifier<int> index;
  final ValueChanged<int> onTap;
  final Axis axis;

  const new({
    required this.entries,
    required this.index,
    required this.onTap,
    this.axis = Axis.horizontal,
  });

  @override
  State<_ThumbnailStrip> createState() => _ThumbnailStripState();
}

class _ThumbnailStripState extends State<_ThumbnailStrip> {
  static const double _thumbSize = 52;
  static const double _itemExtent = 56;

  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _notCancellable = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    widget.index.addListener(_center);
    WidgetsBinding.instance.addPostFrameCallback((_) => _center());
  }

  @override
  void dispose() {
    widget.index.removeListener(_center);
    _scrollController.dispose();
    _notCancellable.dispose();
    super.dispose();
  }

  void _center() {
    if (!_scrollController.hasClients) return;
    final viewport = _scrollController.position.viewportDimension;
    final target = (widget.index.value * _itemExtent - (viewport - _itemExtent) / 2).clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final isVertical = widget.axis == Axis.vertical;
    return ListView.builder(
      controller: _scrollController,
      scrollDirection: widget.axis,
      padding: EdgeInsets.symmetric(
        horizontal: isVertical ? 4 : 8,
        vertical: isVertical ? 8 : 4,
      ),
      itemCount: widget.entries.length,
      itemBuilder: (context, index) => ValueListenableBuilder<int>(
        valueListenable: widget.index,
        builder: (context, current, child) => GestureDetector(
          onTap: () => widget.onTap(index),
          child: Container(
            width: _thumbSize,
            height: _thumbSize,
            margin: EdgeInsets.symmetric(
              horizontal: isVertical ? 4 : 2,
              vertical: isVertical ? 2 : 10,
            ),
            decoration: BoxDecoration(
              border: Border.all(color: index == current ? Colors.white : Colors.white24, width: index == current ? 2 : 1),
            ),
            child: ThumbnailImage(
              entry: widget.entries[index],
              extent: _thumbSize,
              devicePixelRatio: dpr,
              fit: BoxFit.cover,
              cancellableNotifier: _notCancellable,
            ),
          ),
        ),
      ),
    );
  }
}

class _ImageProgressBar extends StatefulWidget {
  final int count;
  final ValueListenable<int> index;
  final ValueChanged<int> onIndexChanged;
  final Axis axis;

  const new({
    required this.count,
    required this.index,
    required this.onIndexChanged,
    this.axis = Axis.horizontal,
  });

  @override
  State<_ImageProgressBar> createState() => _ImageProgressBarState();
}

class _ImageProgressBarState extends State<_ImageProgressBar> {
  static const _textStyle = TextStyle(
    color: Colors.white70,
    fontSize: 12,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  int? _dragIndex;

  @override
  Widget build(BuildContext context) {
    if (widget.count <= 1) return const SizedBox.shrink();

    final isVertical = widget.axis == Axis.vertical;

    return ValueListenableBuilder<int>(
      valueListenable: widget.index,
      builder: (context, index, child) {
        final current = (_dragIndex ?? index).clamp(0, widget.count - 1);
        final max = (widget.count - 1).toDouble();

        final sliderTheme = SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            tickMarkShape: SliderTickMarkShape.noTickMark,
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white24,
            thumbColor: Colors.white,
            overlayColor: Colors.white24,
          ),
          child: Slider(
            value: current.toDouble().clamp(0.0, max),
            min: 0,
            max: max,
            divisions: widget.count - 1,
            onChanged: (v) {
              final target = v.round().clamp(0, widget.count - 1);
              if (target != _dragIndex) {
                setState(() => _dragIndex = target);
                widget.onIndexChanged(target);
              }
            },
            onChangeEnd: (v) {
              final target = v.round().clamp(0, widget.count - 1);
              widget.onIndexChanged(target);
              setState(() => _dragIndex = null);
            },
          ),
        );

        if (isVertical) {
          return Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text('${current + 1}\n/\n${widget.count}', style: _textStyle, textAlign: TextAlign.center),
              ),
              Expanded(
                child: RotatedBox(
                  quarterTurns: 1,
                  child: sliderTheme,
                ),
              ),
              const SizedBox(height: 8),
            ],
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(child: sliderTheme),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text('${current + 1}/${widget.count}', style: _textStyle),
              ),
            ],
          ),
        );
      },
    );
  }
}
