import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/images.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:material_ui/material_ui.dart';

class WebDavViewerPage extends StatefulWidget {
  static const routeName = '/webdav/viewer';

  final List<AvesEntry> entries;
  final int initialIndex;

  const new({
    super.key,
    required this.entries,
    required this.initialIndex,
  });

  @override
  State<WebDavViewerPage> createState() => _WebDavViewerPageState();
}

class _WebDavViewerPageState extends State<WebDavViewerPage> {
  late final int _initialIndex;
  late final PageController _pageController;
  late final ValueNotifier<int> _indexNotifier;

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    if (entries.isEmpty) {
      return const AvesScaffold(backgroundColor: Colors.black);
    }

    return AvesScaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            onPageChanged: (index) => _indexNotifier.value = index,
            itemCount: entries.length,
            itemBuilder: (context, index) => _RemoteImagePage(entry: entries[index]),
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
                    builder: (context, index, child) => Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text(
                        '${index + 1} / ${entries.length}',
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                      ),
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

class _RemoteImagePage extends StatefulWidget {
  final AvesEntry entry;

  const new({required this.entry});

  @override
  State<_RemoteImagePage> createState() => _RemoteImagePageState();
}

class _RemoteImagePageState extends State<_RemoteImagePage> {
  final TransformationController _transformationController = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transformationController.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _transformationController.removeListener(_onTransformChanged);
    _transformationController.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final zoomed = _transformationController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      setState(() => _zoomed = zoomed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _transformationController,
      // allow horizontal page swiping while not zoomed, panning while zoomed
      panEnabled: _zoomed,
      minScale: 1,
      maxScale: 6,
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
