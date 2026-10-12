import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/images.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/thumbnail/image.dart';
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

  late final int _initialIndex;
  late final PageController _pageController;
  late final ValueNotifier<int> _indexNotifier;

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
    _pageController.jumpToPage(index);
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    if (entries.isEmpty) {
      return const AvesScaffold(backgroundColor: Colors.black);
    }
    final showStrip = settings.cloudViewerThumbnails;

    return AvesScaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: _blockPaging,
            builder: (context, blocked, child) => PageView.builder(
              controller: _pageController,
              // a deliberate drag is required to change page, and paging is
              // disabled altogether while zooming
              physics: blocked ? const NeverScrollableScrollPhysics() : const _ViewerPageScrollPhysics(),
              onPageChanged: (index) {
                _indexNotifier.value = index;
                // the page that just went off screen may have left paging blocked
                _blockPaging.value = false;
              },
              itemCount: entries.length,
              itemBuilder: (context, index) => _RemoteImagePage(
                entry: entries[index],
                onBlockPaging: (value) => _blockPaging.value = value,
              ),
            ),
          ),
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
                    tooltip: context.l10n.cloudViewerThumbnails,
                    color: Colors.white,
                    icon: Icon(showStrip ? Icons.view_carousel : Icons.view_carousel_outlined),
                    onPressed: () => setState(() => settings.cloudViewerThumbnails = !showStrip),
                  ),
                ],
              ),
            ),
          ),
          if (showStrip)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                height: _stripHeight + MediaQuery.paddingOf(context).bottom,
                padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
                color: const Color(0xCC000000),
                child: _ThumbnailStrip(entries: entries, index: _indexNotifier, onTap: _goTo),
              ),
            ),
        ],
      ),
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
  double get dragStartDistanceMotionThreshold => 24;
}

class _RemoteImagePage extends StatefulWidget {
  final AvesEntry entry;
  final ValueChanged<bool> onBlockPaging;

  const new({required this.entry, required this.onBlockPaging});

  @override
  State<_RemoteImagePage> createState() => _RemoteImagePageState();
}

class _RemoteImagePageState extends State<_RemoteImagePage> {
  final TransformationController _transformationController = TransformationController();
  bool _zoomed = false;
  bool _multiTouch = false;

  @override
  void initState() {
    super.initState();
    _transformationController.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    // never leave paging blocked behind us; deferred because this runs during
    // the parent's build when the pager swaps pages
    if (_zoomed || _multiTouch) {
      final notify = widget.onBlockPaging;
      WidgetsBinding.instance.addPostFrameCallback((_) => notify(false));
    }
    _transformationController.removeListener(_onTransformChanged);
    _transformationController.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final zoomed = _transformationController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      _zoomed = zoomed;
      _notify();
    }
  }

  void _setMultiTouch(bool value) {
    if (value == _multiTouch) return;
    _multiTouch = value;
    _notify();
  }

  void _notify() => widget.onBlockPaging(_zoomed || _multiTouch);

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _transformationController,
      // allow horizontal page swiping while not zoomed, panning while zoomed
      panEnabled: _zoomed,
      minScale: 1,
      maxScale: 6,
      onInteractionStart: (details) => _setMultiTouch(details.pointerCount >= 2),
      onInteractionUpdate: (details) => _setMultiTouch(details.pointerCount >= 2),
      onInteractionEnd: (details) => _setMultiTouch(false),
      child: Center(
        child: Image(
          image: widget.entry.getFullImage(),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) return child;
            return frame == null ? const Center(child: CircularProgressIndicator()) : child;
          },
          errorBuilder: (context, error, stack) => const Center(
            child: Icon(
              AIcons.error,
              color: Colors.white54,
              size: 48,
            ),
          ),
        ),
      ),
    );
  }
}

// horizontal strip of thumbnails used to jump quickly between nearby images
class _ThumbnailStrip extends StatefulWidget {
  final List<AvesEntry> entries;
  final ValueNotifier<int> index;
  final ValueChanged<int> onTap;

  const new({required this.entries, required this.index, required this.onTap});

  @override
  State<_ThumbnailStrip> createState() => _ThumbnailStripState();
}

class _ThumbnailStripState extends State<_ThumbnailStrip> {
  static const double _thumbSize = 52;
  static const double _itemExtent = 56;

  final ScrollController _scrollController = ScrollController();
  // the strip never cancels its own thumbnail loads
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
    return ListView.builder(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: widget.entries.length,
      itemBuilder: (context, index) => ValueListenableBuilder<int>(
        valueListenable: widget.index,
        builder: (context, current, child) => GestureDetector(
          onTap: () => widget.onTap(index),
          child: Container(
            width: _thumbSize,
            height: _thumbSize,
            margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
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
