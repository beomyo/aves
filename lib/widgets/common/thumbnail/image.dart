import 'dart:async';
import 'dart:math';

import 'package:aves/image_providers/thumbnail_provider.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/images.dart';
import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/settings/enums/entry_background.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/widgets/common/basic/insets.dart';
import 'package:aves/widgets/common/fx/checkered_decoration.dart';
import 'package:aves/widgets/common/fx/transition_image.dart';
import 'package:aves/widgets/common/grid/sections/mosaic/section_layout_builder.dart';
import 'package:aves/widgets/common/providers/media_query_data_provider.dart';
import 'package:aves/widgets/common/thumbnail/error.dart';
import 'package:aves_model/aves_model.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

class const ThumbnailImage({
  super.key,
  required final AvesEntry entry,
  required final double extent,
  required final double devicePixelRatio,
  final bool progressive = true,
  final bool isMosaic = false,
  final BoxFit? fit,
  final bool showLoadingBackground = true,
  final ValueNotifier<bool>? cancellableNotifier,
  final Object? heroTag,
  final HeroPlaceholderBuilder? heroPlaceholderBuilder,
  // rendered instead of the default error thumbnail (e.g. a video placeholder)
  final Widget? errorPlaceholder,
  // called with the loaded image info (e.g. to record the real aspect ratio)
  final ValueChanged<ImageInfo>? onImageInfo,
  // when not empty, a failed thumbnail is retried after each delay (in order)
  // instead of showing the error placeholder after the first failure
  final List<Duration> retryDelays = const [],
  // a spinner while the thumbnail is loading. Remote thumbnails can take
  // seconds, and a plain background gives no feedback at all
  final bool showLoadingIndicator = false,
  // once this widget is on screen, its queued request jumps to the front of
  // the queue. Without it, images the user scrolled past and came back to wait
  // behind every thumbnail requested in the meantime
  final bool prioritizeOnVisible = false,
}) extends StatefulWidget {
  @override
  State<ThumbnailImage> createState() => _ThumbnailImageState();

  static Color computeLoadingBackgroundColor(int hashCode, Brightness brightness) {
    var rgb = 0x30 + hashCode % 0x20;
    if (brightness == Brightness.light) {
      rgb = 0xFF - rgb;
    }
    return Color.fromARGB(0xFF, rgb, rgb, rgb);
  }
}

class _ThumbnailImageState extends State<ThumbnailImage> {
  final _providers = <_ConditionalImageProvider>[];
  _ProviderStream? _currentProviderStream;
  ImageInfo? _lastImageInfo;
  Object? _lastException;
  late final ImageStreamListener _streamListener;
  int _retryAttempt = 0;
  Timer? _retryTimer;
  ImageProvider? _failedProvider;
  // captured from `build`, so the post frame visibility check does not need an
  // inherited widget lookup outside of it
  Size? _viewportSize;

  AvesEntry get entry => widget.entry;

  double get extent => widget.extent;

  bool get isMosaic => widget.isMosaic;

  @override
  void initState() {
    super.initState();
    _streamListener = ImageStreamListener(_onImageLoad, onError: _onError);
    _registerWidget(widget);
    if (widget.prioritizeOnVisible) _schedulePrioritize();
  }

  // the widget may be built ahead of the viewport (scroll cache extent), so
  // ask after layout whether it is actually on screen
  void _schedulePrioritize() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _viewportSize;
      final box = context.findRenderObject();
      if (size == null || box is! RenderBox || !box.hasSize || !box.attached) return;
      final origin = box.localToGlobal(Offset.zero);
      final visible = origin.dy < size.height && origin.dy + box.size.height > 0 && origin.dx < size.width && origin.dx + box.size.width > 0;
      if (!visible) return;
      mediaFetchService.prioritizeThumbnail(entry.getThumbnail(extent: extent).key);
    });
  }

  @override
  void didUpdateWidget(covariant ThumbnailImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry != entry) {
      _unregisterWidget(oldWidget);
      _registerWidget(widget);
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _unregisterWidget(widget);
    super.dispose();
  }

  void _registerWidget(ThumbnailImage widget) {
    final visualChangeNotifier = widget.entry.visualChangeNotifier;
    if (!visualChangeNotifier.isDisposed) {
      visualChangeNotifier.addListener(_onVisualChanged);
    }
    _resetRetry();
    _initProvider();
  }

  void _unregisterWidget(ThumbnailImage widget) {
    widget.entry.visualChangeNotifier.removeListener(_onVisualChanged);
    _retryTimer?.cancel();
    _retryTimer = null;
    _pauseProvider();
    _currentProviderStream?.stopListening();
    _currentProviderStream = null;
    _replaceImage(null);
  }

  void _resetRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempt = 0;
    _failedProvider = null;
  }

  void _initProvider() {
    if (!entry.isDecodingSupported) return;

    _lastException = null;
    _providers.clear();

    final highQuality = entry.getThumbnail(extent: extent);
    ThumbnailProvider? lowQuality;
    if (widget.progressive && !entry.isSvg) {
      if (entry.isVideo) {
        // previously fetched thumbnail
        final cached = entry.bestCachedThumbnail;
        final lowQualityExtent = cached.key.extent;
        if (lowQualityExtent > 0 && lowQualityExtent != extent) {
          lowQuality = cached;
        }
      } else {
        // default platform thumbnail
        lowQuality = entry.getThumbnail();
      }
    }
    _providers.addAll([
      if (lowQuality != null)
        _ConditionalImageProvider(
          lowQuality,
        ),
      _ConditionalImageProvider(
        highQuality,
        _needSizedProvider,
      ),
    ]);
    _loadNextProvider();
  }

  void _loadNextProvider([ImageInfo? imageInfo]) {
    final nextIndex = _currentProviderStream == null ? 0 : (_providers.indexOf(_currentProviderStream!.provider) + 1);
    if (nextIndex < _providers.length) {
      final provider = _providers[nextIndex];
      if (provider.predicate?.call(imageInfo) ?? true) {
        _currentProviderStream?.stopListening();
        _currentProviderStream = _ProviderStream(provider, _streamListener);
        _currentProviderStream!.startListening();
      }
    }
  }

  void _onImageLoad(ImageInfo imageInfo, bool synchronousCall) {
    _resetRetry();
    _replaceImage(imageInfo);
    widget.onImageInfo?.call(imageInfo);
    _loadNextProvider(imageInfo);
  }

  void _replaceImage(ImageInfo? imageInfo) {
    _lastImageInfo?.dispose();
    _lastImageInfo = imageInfo;
    if (imageInfo != null) {
      setState(() {});
    }
  }

  void _onError(Object exception, StackTrace? stackTrace) {
    if (!mounted) return;
    // a failed low-quality pass (e.g. a cached video frame that was evicted
    // from disk) must not hide the tile before the higher-quality provider ran
    final nextIndex = _currentProviderStream == null ? 0 : (_providers.indexOf(_currentProviderStream!.provider) + 1);
    if (nextIndex < _providers.length) {
      _loadNextProvider();
      return;
    }
    if (_retryAttempt < widget.retryDelays.length) {
      final delay = widget.retryDelays[_retryAttempt++];
      _failedProvider = _currentProviderStream?.provider.provider;
      _retryTimer?.cancel();
      _retryTimer = Timer(delay, _retry);
      // wait in the loading state (with a spinner) instead of the error state
      setState(() => _lastException = null);
      return;
    }
    setState(() => _lastException = exception);
  }

  Future<void> _retry() async {
    _retryTimer = null;
    if (!mounted) return;
    final failed = _failedProvider;
    _failedProvider = null;
    if (failed != null) {
      try {
        // drop the failed entry, otherwise resolving the same key replays the
        // error immediately
        await failed.evict();
      } catch (_) {
        // best effort
      }
    }
    if (!mounted) return;
    _initProvider();
    setState(() {});
  }

  bool _needSizedProvider(ImageInfo? currentImageInfo) {
    if (currentImageInfo == null) return true;
    final currentImage = currentImageInfo.image;
    final sizedThreshold = extent * widget.devicePixelRatio;
    return sizedThreshold > min(currentImage.width, currentImage.height);
  }

  // pauses the request of a tile that is going away (disposed, or its entry
  // changed). This matters when leaving a folder: queued remote thumbnails of
  // the old folder would otherwise compete with the next folder's listing, and
  // on a rate limited server that is a long delay. A re-created provider with
  // the same key resumes the paused task, so scrolling back is unaffected.
  //
  // This must stay synchronous: pausing asynchronously (after awaiting the
  // provider key) could land *after* the next tile resolved the same key,
  // leaving the request paused with nobody left to resume it, i.e. a tile
  // waiting for its thumbnail forever.
  void _pauseProvider() {
    final provider = _currentProviderStream?.provider.provider;
    if (provider is ThumbnailProvider) {
      mediaFetchService.cancelThumbnail(provider.key);
    }
  }

  Color? _loadingBackgroundColor;

  Color loadingBackgroundColor(BuildContext context) {
    _loadingBackgroundColor ??= ThumbnailImage.computeLoadingBackgroundColor(entry.uri.hashCode, Theme.of(context).brightness);
    return _loadingBackgroundColor!;
  }

  @override
  Widget build(BuildContext context) {
    final animate = context.select<Settings, bool>((v) => v.animate);
    _viewportSize = MediaQuery.sizeOf(context);
    if (!entry.isDecodingSupported || _lastException != null) {
      return widget.errorPlaceholder ?? _buildError(context, animate);
    }

    // use `RawImage` instead of `Image`, using `ImageInfo` to check dimensions
    // and have more control when chaining image providers

    final thumbnailHeight = extent;
    final double thumbnailWidth;
    if (isMosaic) {
      thumbnailWidth =
          thumbnailHeight *
          entry.displayAspectRatio.clamp(
            MosaicSectionLayoutBuilder.minThumbnailAspectRatio,
            MosaicSectionLayoutBuilder.maxThumbnailAspectRatio,
          );
    } else {
      thumbnailWidth = extent;
    }
    final canHaveAlpha = entry.canHaveAlpha;

    final fit = widget.fit ?? (entry.isSvg ? BoxFit.contain : BoxFit.cover);
    final imageInfo = _lastImageInfo;
    Widget image = imageInfo == null
        ? SizedBox(
            width: thumbnailWidth,
            height: thumbnailHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  color: widget.showLoadingBackground ? loadingBackgroundColor(context) : Colors.transparent,
                ),
                // a delayed retry is pending, or the thumbnail is still on its
                // way: keep showing progress instead of a silent black tile
                if (_retryTimer != null || widget.showLoadingIndicator)
                  const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          )
        : Selector<Settings, EntryBackground>(
            selector: (context, s) => s.imageBackground,
            builder: (context, background, child) {
              // avoid background color filter or layer when the entry cannot be transparent
              final backgroundColor = canHaveAlpha && background.isColor ? background.color : null;

              if (canHaveAlpha && background == EntryBackground.checkered) {
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final availableSize = constraints.biggest;
                    final fitSize = applyBoxFit(fit, entry.displaySize, availableSize).destination;
                    final offset = (fitSize / 2 - availableSize / 2) as Offset;
                    final child = CustomPaint(
                      painter: CheckeredPainter(checkSize: extent / 8, offset: offset),
                      child: RawImage(
                        image: imageInfo.image,
                        debugImageLabel: imageInfo.debugLabel,
                        width: fitSize.width,
                        height: fitSize.height,
                        scale: imageInfo.scale,
                        fit: BoxFit.cover,
                      ),
                    );
                    // the thumbnail is centered for correct decoration sizing
                    // when constraints are tight during hero animation
                    return constraints.isTight ? Center(child: child) : child;
                  },
                );
              }

              return RawImage(
                image: imageInfo.image,
                debugImageLabel: imageInfo.debugLabel,
                width: thumbnailWidth,
                height: thumbnailHeight,
                scale: imageInfo.scale,
                color: backgroundColor,
                colorBlendMode: BlendMode.dstOver,
                fit: fit,
              );
            },
          );

    final heroTag = widget.heroTag;
    if (animate && heroTag != null) {
      final background = settings.imageBackground;
      final backgroundColor = background.isColor ? background.color : null;
      image = Hero(
        tag: heroTag,
        flightShuttleBuilder: (flightContext, animation, flightDirection, fromHeroContext, toHeroContext) {
          // as of Flutter v3.27.0-0.1.pre, the flight `animation` is incorrect when diverting a pop:
          // - diverting a push (t = 0 -> 1) with a pop (t = 1 -> 0) works as expected (t = 0 -> [0,1] -> 0)
          // - diverting a pop (t = 1 -> 0) with a push (t = 0 -> 1) finishes the pop (t = 1 -> [0,1] -> 0) instead of diverting (t = 1 -> [0,1] -> 1)
          Widget child = TransitionImage(
            image: entry.bestCachedThumbnail,
            animation: animation,
            thumbnailFit: BoxFit.cover,
            viewerFit: BoxFit.contain,
            background: backgroundColor,
          );
          if (!settings.viewerUseCutout) {
            child = SafeCutoutArea(
              animation: animation,
              child: child,
            );
          }
          return child;
        },
        placeholderBuilder: widget.heroPlaceholderBuilder,
        transitionOnUserGestures: true,
        child: image,
      );
    }

    return image;
  }

  Widget _buildError(BuildContext context, bool animate) {
    Widget child = ErrorThumbnail(
      entry: entry,
      extent: extent,
    );

    final heroTag = widget.heroTag;
    if (animate && heroTag != null) {
      child = Hero(
        tag: heroTag,
        flightShuttleBuilder: (flightContext, animation, flightDirection, fromHeroContext, toHeroContext) {
          return MediaQueryDataProvider(
            child: DefaultTextStyle(
              style: DefaultTextStyle.of(toHeroContext).style,
              child: toHeroContext.widget,
            ),
          );
        },
        transitionOnUserGestures: true,
        child: child,
      );
    }

    return child;
  }

  // when the entry image itself changed (e.g. after rotation)
  void _onVisualChanged() async {
    // rebuild to refresh the thumbnails
    _resetRetry();
    _pauseProvider();
    _initProvider();
    setState(() {});
  }
}

class const _ConditionalImageProvider(
  final ImageProvider provider, [
  final bool Function(ImageInfo?)? predicate,
]);

class _ProviderStream(
  final _ConditionalImageProvider provider,
  final ImageStreamListener listener,
) {
  final ImageStream _stream = provider.provider.resolve(ImageConfiguration.empty);

  void startListening() => _stream.addListener(listener);

  void stopListening() => _stream.removeListener(listener);
}
