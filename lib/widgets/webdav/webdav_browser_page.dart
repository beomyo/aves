import 'dart:async';
import 'dart:math' as math;

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/webdav/webdav_resource.dart';
import 'package:aves/model/source/webdav/webdav_server.dart';
import 'package:aves/ref/mime_types.dart';
import 'package:aves/services/common/webdav_registry.dart';
import 'package:aves/services/media/webdav_fetch_service.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/basic/draggable_scrollbar/scrollbar.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/behaviour/eager_scale_gesture_recognizer.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/empty.dart';
import 'package:aves/widgets/common/identity/scroll_thumb.dart';
import 'package:aves/widgets/common/thumbnail/image.dart';
import 'package:aves/widgets/navigation/drawer/app_drawer.dart';
import 'package:aves/widgets/webdav/webdav_video_page.dart';
import 'package:aves/widgets/webdav/webdav_view_options.dart';
import 'package:aves/widgets/webdav/webdav_viewer_page.dart';
import 'package:aves_model/aves_model.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

enum _LoadState { loading, ready, error }

class WebDavBrowserPage extends StatefulWidget {
  static const routeName = '/webdav/browse';
  static const double addressBarHeight = 42;

  final WebDavServer server;
  final String? initialUrl;

  const new({super.key, required this.server, this.initialUrl});

  @override
  State<WebDavBrowserPage> createState() => _WebDavBrowserPageState();
}

class _WebDavBrowserPageState extends State<WebDavBrowserPage> {
  static const int _maxProbeCount = 400;
  static const int _probeConcurrency = 4;
  static const double _mosaicSpacing = 4;

  final ValueNotifier<_LoadState> _state = ValueNotifier(_LoadState.loading);
  final ValueNotifier<String> _error = ValueNotifier('');
  final ValueNotifier<List<WebDavResource>> _folders = ValueNotifier([]);
  final ValueNotifier<List<AvesEntry>> _media = ValueNotifier([]);
  final ValueNotifier<bool> _isScrolling = ValueNotifier(false);
  final ScrollController _scrollController = ScrollController();
  final ScrollController _addressScrollController = ScrollController();

  List<String> _history = [];
  late String _currentUrl;
  Timer? _scrollTimer;
  StreamSubscription? _settingsSub;

  // scroll position per folder, to restore it when going back
  final Map<String, double> _scrollPositions = {};

  // immersive: hide the app bar while scrolling down
  bool _immersive = false;
  double _lastScrollPixels = 0;

  // pinch to resize
  double _scaleStartColumns = 3;

  // mosaic aspect ratios (uri -> width / height), filled in the background
  final Map<String, double> _aspects = {};
  Timer? _aspectFlushTimer;
  int _probeGeneration = 0;

  String get _baseUrl => widget.server.url.endsWith('/') ? widget.server.url : '${widget.server.url}/';

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.initialUrl ?? _baseUrl;
    _history = _ancestorsFor(_currentUrl);
    _scrollController.addListener(_onScroll);
    _settingsSub = settings.updateStream.where((event) => event.key == SettingKeys.webDavLayoutKey).listen((_) {
      if (settings.webDavLayout == 'mosaic') {
        _maybeProbe(_media.value, 'mosaic');
      }
    });
    _fetch();
  }

  @override
  void dispose() {
    _probeGeneration++;
    _settingsSub?.cancel();
    _scrollTimer?.cancel();
    _aspectFlushTimer?.cancel();
    _scrollController.dispose();
    _addressScrollController.dispose();
    _state.dispose();
    _error.dispose();
    _folders.dispose();
    _media.dispose();
    _isScrolling.dispose();
    super.dispose();
  }

  void _onScroll() {
    // cancel pending thumbnail loads while scrolling
    _isScrolling.value = true;
    _scrollTimer?.cancel();
    _scrollTimer = Timer(const Duration(milliseconds: 400), () {
      _isScrolling.value = false;
    });

    if (!settings.webDavImmersive) {
      if (_immersive) setState(() => _immersive = false);
      return;
    }
    if (!_scrollController.hasClients) return;

    final pixels = _scrollController.position.pixels;
    final delta = pixels - _lastScrollPixels;
    _lastScrollPixels = pixels;
    // scrolling up reveals the app bar, scrolling down hides it
    final shouldBeImmersive = delta > 0 ? (_immersive || pixels > 24) : false;
    if (shouldBeImmersive != _immersive) {
      setState(() => _immersive = shouldBeImmersive);
    }
  }

  String get _folderName {
    final crumbs = _breadcrumbs();
    return crumbs.isNotEmpty ? crumbs.last.$1 : context.l10n.webdavRoot;
  }

  List<String> _ancestorsFor(String url) {
    final base = _baseUrl;
    if (url == base || !url.startsWith(base)) return [];
    final segments = url.substring(base.length).split('/').where((s) => s.isNotEmpty).toList();
    final ancestors = <String>[base];
    var acc = base;
    for (var i = 0; i < segments.length - 1; i++) {
      acc = '$acc${segments[i]}/';
      ancestors.add(acc);
    }
    return ancestors;
  }

  List<(String, String)> _breadcrumbs() {
    final base = _baseUrl;
    final crumbs = <(String, String)>[];
    if (_currentUrl.startsWith(base)) {
      final segments = _currentUrl.substring(base.length).split('/').where((s) => s.isNotEmpty).toList();
      var acc = base;
      for (var i = 0; i < segments.length; i++) {
        acc = '$acc${segments[i]}/';
        crumbs.add((_decode(segments[i]), i == segments.length - 1 ? _currentUrl : acc));
      }
    }
    return crumbs;
  }

  static String _decode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  void _rememberScrollPosition() {
    if (_scrollController.hasClients) {
      _scrollPositions[_currentUrl] = _scrollController.offset;
    }
  }

  void _restoreScrollPosition(String url) {
    final target = _scrollPositions[url];
    if (target == null || target <= 0) {
      _scrollTo(0, url);
      return;
    }
    // the target folder's scroll extent may still be an estimate on the first
    // frame, so retry once after the layout has settled
    _scrollTo(target, url);
    Timer(const Duration(milliseconds: 300), () => _scrollTo(target, url));
  }

  void _scrollTo(double target, String url) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || url != _currentUrl || !_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      final offset = target.clamp(0.0, max);
      if ((_scrollController.offset - offset).abs() > 0.5) {
        _scrollController.jumpTo(offset);
      }
      _lastScrollPixels = offset;
    });
  }

  void _navigateTo(String url) {
    if (url == _currentUrl) return;
    _rememberScrollPosition();
    setState(() {
      _currentUrl = url;
      _history = _ancestorsFor(url);
      _immersive = false;
    });
    _fetch();
  }

  void _goUp() {
    if (_history.isEmpty) return;
    _rememberScrollPosition();
    final parent = _history.removeLast();
    setState(() {
      _currentUrl = parent;
      _immersive = false;
    });
    _fetch();
  }

  Future<void> _fetch() async {
    final url = _currentUrl;
    _state.value = _LoadState.loading;
    _folders.value = [];
    _media.value = [];
    _probeGeneration++;
    try {
      final client = webDavRegistry.clientForServer(widget.server);
      if (client == null) {
        throw StateError('server not found');
      }
      final resources = await client.list(url);
      if (!mounted || url != _currentUrl) return;

      final folders = resources.where((r) => r.isCollection).toList();
      final media = <AvesEntry>[];
      var index = 0;
      for (final resource in resources.where((r) => !r.isCollection)) {
        final mime = _mimeForResource(resource);
        if (!MimeTypes.isImage(mime) && !MimeTypes.isVideo(mime)) continue;
        media.add(_entryFromResource(resource, mime, -1 - index));
        index++;
      }

      _folders.value = folders;
      _media.value = media;
      _state.value = _LoadState.ready;

      if (settings.webDavLastServerId != widget.server.id || settings.webDavLastUrl != url) {
        settings.setWebDavLastLocation(widget.server.id, url);
      }

      _restoreScrollPosition(url);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_addressScrollController.hasClients) {
          _addressScrollController.jumpTo(_addressScrollController.position.maxScrollExtent);
        }
      });
      _maybeProbe(media, settings.webDavLayout);
    } catch (error) {
      if (!mounted || url != _currentUrl) return;
      _error.value = error.toString();
      _state.value = _LoadState.error;
    }
  }

  void _maybeProbe(List<AvesEntry> media, String layout) {
    if (layout != 'mosaic') return;
    final generation = ++_probeGeneration;
    final pending = <String>[];
    for (final entry in media) {
      if (!entry.isImage) continue;
      if (_aspects.containsKey(entry.uri)) continue;
      pending.add(entry.uri);
      if (pending.length >= _maxProbeCount) break;
    }
    if (pending.isEmpty) return;

    var index = 0;
    Future<void> worker() async {
      while (true) {
        if (generation != _probeGeneration) return;
        final i = index++;
        if (i >= pending.length) return;
        final aspect = await webDavImageLoader.probeAspect(pending[i]);
        if (generation != _probeGeneration) return;
        if (aspect != null) {
          _aspects[pending[i]] = aspect;
          _scheduleAspectFlush();
        }
      }
    }

    for (var w = 0; w < _probeConcurrency; w++) {
      worker();
    }
  }

  void _scheduleAspectFlush() {
    _aspectFlushTimer ??= Timer(const Duration(milliseconds: 200), () {
      _aspectFlushTimer = null;
      if (mounted) setState(() {});
    });
  }

  double _aspectOf(AvesEntry entry) => (entry.isVideo ? 16 / 9 : (_aspects[entry.uri] ?? 1.0)).clamp(0.35, 2.6);

  void _onScaleStart(ScaleStartDetails details) {
    _scaleStartColumns = settings.webDavColumns;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount < 2) return;
    final scale = details.scale;
    if (scale <= 0) return;
    final columns = (_scaleStartColumns / scale).clamp(1.5, 8.0);
    if ((columns - settings.webDavColumns).abs() >= 0.02) {
      settings.webDavColumns = columns;
    }
  }

  AvesEntry _entryFromResource(WebDavResource resource, String mimeType, int id) {
    return AvesEntry(
      id: id,
      uri: resource.url,
      // remote entries have no local path, which also keeps the video backend
      // from looking for sibling subtitle files on disk
      path: null,
      contentId: null,
      pageId: null,
      sourceMimeType: mimeType,
      width: 0,
      height: 0,
      sourceRotationDegrees: 0,
      sizeBytes: resource.sizeBytes,
      sourceTitle: resource.name,
      dateAddedSecs: null,
      dateModifiedMillis: resource.dateModifiedMillis,
      sourceDateTakenMillis: null,
      durationMillis: null,
      trashed: false,
      origin: EntryOrigins.webDav,
    );
  }

  static String _mimeForResource(WebDavResource resource) {
    if (resource.isCollection) return 'application/octet-stream';
    final reported = resource.mimeType;
    if (reported != null && (MimeTypes.isImage(reported) || MimeTypes.isVideo(reported))) {
      return reported;
    }
    return _mimeFromName(resource.name);
  }

  static String _mimeFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
    if (lower.endsWith('.avif')) return 'image/avif';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    if (lower.endsWith('.tif') || lower.endsWith('.tiff')) return 'image/tiff';
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) return 'video/mp4';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.avi')) return 'video/x-msvideo';
    if (lower.endsWith('.wmv')) return 'video/x-ms-wmv';
    if (lower.endsWith('.flv')) return 'video/x-flv';
    if (lower.endsWith('.ts') || lower.endsWith('.m2ts')) return 'video/mp2t';
    if (lower.endsWith('.mpg') || lower.endsWith('.mpeg')) return 'video/mpeg';
    if (lower.endsWith('.3gp')) return 'video/3gpp';
    if (lower.endsWith('.3g2')) return 'video/3gpp2';
    if (lower.endsWith('.ogv')) return 'video/ogg';
    return 'application/octet-stream';
  }

  void _openFolder(WebDavResource folder) => _navigateTo(folder.url);

  void _openEntry(List<AvesEntry> visibleEntries, AvesEntry entry) {
    if (entry.isVideo) {
      // the video backend streams the file itself, so give it an authenticated URL
      final playableUrl = webDavRegistry.authenticatedUrl(entry.uri);
      final playableEntry = playableUrl == entry.uri ? entry : entry.copyWith(uri: playableUrl);
      Navigator.push(
        context,
        MaterialPageRoute(
          settings: const RouteSettings(name: WebDavVideoPage.routeName),
          builder: (context) => WebDavVideoPage(entry: playableEntry),
        ),
      );
      return;
    }
    final index = visibleEntries.indexOf(entry);
    final images = visibleEntries.where((e) => e.isImage).toList();
    final imageIndex = images.indexOf(entry);
    if (index < 0 || images.isEmpty || imageIndex < 0) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: WebDavViewerPage.routeName),
        builder: (context) => WebDavViewerPage(entries: images, initialIndex: imageIndex),
      ),
    );
  }

  Future<void> _promptJump() async {
    final l10n = context.l10n;
    final base = _baseUrl;
    final initial = _currentUrl.startsWith(base) ? _currentUrl.substring(base.length) : '';
    final controller = TextEditingController(text: _decode(initial));
    final input = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.webdavJumpToPath),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.webdavPathHint),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.webdavActionCancel)),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(l10n.webdavActionGo)),
        ],
      ),
    );
    if (input == null) return;
    final path = input.trim();
    if (path.isEmpty) return;

    final String target;
    if (path.startsWith('http://') || path.startsWith('https://')) {
      target = path.endsWith('/') ? path : '$path/';
    } else {
      final encoded = path.split('/').where((s) => s.isNotEmpty).map(Uri.encodeComponent).join('/');
      target = encoded.isEmpty ? base : '$base$encoded/';
    }
    _navigateTo(target);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _history.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _goUp();
      },
      child: AvesScaffold(
        drawer: const AppDrawer(),
        body: ValueListenableBuilder<_LoadState>(
          valueListenable: _state,
          builder: (context, state, child) {
            return ValueListenableBuilder<List<WebDavResource>>(
              valueListenable: _folders,
              builder: (context, folders, child) {
                return ValueListenableBuilder<List<AvesEntry>>(
                  valueListenable: _media,
                  builder: (context, media, child) => _buildScrollView(context, state: state, folders: folders, media: media),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildScrollView(BuildContext context, {required _LoadState state, required List<WebDavResource> folders, required List<AvesEntry> media}) {
    final layout = context.select<Settings, String>((s) => s.webDavLayout);
    final columns = context.select<Settings, double>((s) => s.webDavColumns);
    final mediaFilter = context.select<Settings, String>((s) => s.webDavMediaFilter);
    final showNames = context.select<Settings, bool>((s) => s.webDavShowNames);
    final immersiveEnabled = context.select<Settings, bool>((s) => s.webDavImmersive);
    final topInset = MediaQuery.paddingOf(context).top;
    final headerHeight = topInset + kToolbarHeight + WebDavBrowserPage.addressBarHeight;

    final visible = switch (mediaFilter) {
      'image' => media.where((e) => e.isImage).toList(),
      'video' => media.where((e) => e.isVideo).toList(),
      _ => media,
    };

    final List<Widget> contentSlivers;
    if (state == _LoadState.loading) {
      contentSlivers = [const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()))];
    } else if (state == _LoadState.error) {
      contentSlivers = [
        SliverFillRemaining(
          hasScrollBody: false,
          child: ValueListenableBuilder<String>(
            valueListenable: _error,
            builder: (context, error, child) => EmptyContent(
              icon: AIcons.error,
              text: '${context.l10n.webdavLoadError}\n$error',
              bottom: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: OutlinedButton(onPressed: _fetch, child: Text(context.l10n.webdavRefresh)),
              ),
            ),
          ),
        ),
      ];
    } else if (folders.isEmpty && visible.isEmpty) {
      contentSlivers = [SliverFillRemaining(hasScrollBody: false, child: EmptyContent(icon: AIcons.folder, text: context.l10n.webdavEmptyFolder))];
    } else {
      contentSlivers = [
        if (folders.isNotEmpty) _buildFolderSliver(context, folders),
        if (visible.isNotEmpty)
          if (layout == 'mosaic')
            ..._buildMosaicSlivers(context, visible, columns, showNames)
          else if (layout == 'list')
            _buildListSliver(context, visible, showNames)
          else
            _buildGridSliver(context, visible, columns, showNames),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
      ];
    }

    return RawGestureDetector(
      gestures: {
        EagerScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerScaleGestureRecognizer>(
          () => EagerScaleGestureRecognizer(debugOwner: this),
          (instance) {
            instance
              ..onStart = _onScaleStart
              ..onUpdate = _onScaleUpdate;
          },
        ),
      },
      child: DraggableScrollbar(
        backgroundColor: Colors.white,
        scrollThumbSize: AvesScrollThumb.thumbSize,
        scrollThumbBuilder: AvesScrollThumb.builder(
          height: AvesScrollThumb.thumbHeight,
          backgroundColor: Colors.white,
        ),
        controller: _scrollController,
        padding: EdgeInsets.only(top: immersiveEnabled ? 0 : headerHeight),
        labelTextBuilder: (offsetY) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(_folderName, style: const TextStyle(color: Colors.black87)),
        ),
        crumbTextBuilder: (label) => const SizedBox.shrink(),
        child: RefreshIndicator(
          onRefresh: _fetch,
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              _buildAppBar(context, immersiveEnabled),
              ...contentSlivers,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, bool immersiveEnabled) {
    return SliverAppBar(
      primary: true,
      pinned: !immersiveEnabled,
      floating: immersiveEnabled,
      snap: immersiveEnabled,
      automaticallyImplyLeading: false,
      leading: Builder(
        builder: (context) => IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => Scaffold.maybeOf(context)?.openDrawer(),
        ),
      ),
      title: Text(_folderName, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: context.l10n.webdavViewOptions,
          icon: const Icon(AIcons.layout),
          onPressed: () => showWebDavViewOptions(context),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(WebDavBrowserPage.addressBarHeight),
        child: _buildAddressBar(context),
      ),
    );
  }

  Widget _buildAddressBar(BuildContext context) {
    final crumbs = _breadcrumbs();
    final atRoot = crumbs.isEmpty;
    return SizedBox(
      height: WebDavBrowserPage.addressBarHeight,
      child: Row(
        children: [
          IconButton(
            tooltip: widget.server.displayName,
            icon: const Icon(AIcons.cloud),
            onPressed: atRoot ? null : () => _navigateTo(_baseUrl),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _addressScrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  if (atRoot)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      child: Text(
                        context.l10n.webdavRoot,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  for (var i = 0; i < crumbs.length; i++) ...[
                    if (i > 0) const Icon(Icons.chevron_right, size: 16),
                    InkWell(
                      onTap: i == crumbs.length - 1 ? null : () => _navigateTo(crumbs[i].$2),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                        child: Text(
                          crumbs[i].$1,
                          style: TextStyle(
                            color: i == crumbs.length - 1 ? Theme.of(context).colorScheme.primary : null,
                            fontWeight: i == crumbs.length - 1 ? FontWeight.bold : null,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: context.l10n.webdavJumpToPath,
            icon: const Icon(Icons.arrow_forward),
            onPressed: _promptJump,
          ),
        ],
      ),
    );
  }

  Widget _buildFolderSliver(BuildContext context, List<WebDavResource> folders) {
    return SliverList.builder(
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        return ListTile(
          leading: const Icon(AIcons.folder),
          title: Text(folder.name),
          onTap: () => _openFolder(folder),
        );
      },
    );
  }

  Widget _buildListSliver(BuildContext context, List<AvesEntry> entries, bool showNames) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return SliverList.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return ListTile(
          leading: SizedBox(
            width: 56,
            height: 56,
            child: entry.isVideo
                ? const _VideoPlaceholder()
                : ThumbnailImage(
                    entry: entry,
                    extent: 56,
                    devicePixelRatio: dpr,
                    fit: BoxFit.cover,
                    cancellableNotifier: _isScrolling,
                  ),
          ),
          title: Text(entry.sourceTitle ?? entry.bestTitle ?? ''),
          trailing: entry.isVideo ? const Icon(Icons.play_circle_outline, size: 20) : null,
          onTap: () => _openEntry(entries, entry),
        );
      },
    );
  }

  Widget _buildGridSliver(BuildContext context, List<AvesEntry> entries, double columns, bool showNames) {
    final crossAxisCount = columns.round().clamp(1, 10);
    final width = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return SliverPadding(
      padding: const EdgeInsets.all(4),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          return _WebDavTile(
            key: ValueKey(entry.uri),
            entry: entry,
            extent: width / crossAxisCount,
            devicePixelRatio: dpr,
            cancellableNotifier: _isScrolling,
            showName: showNames,
            onTap: () => _openEntry(entries, entry),
          );
        },
      ),
    );
  }

  List<Widget> _buildMosaicSlivers(BuildContext context, List<AvesEntry> entries, double columns, bool showNames) {
    const spacing = _mosaicSpacing;
    final width = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final targetHeight = width / columns;
    final contentWidth = width - 8;
    final rows = <(List<int> indices, double height)>[];

    var items = <int>[];
    var aspectSum = 0.0;

    void flushRow({required bool complete}) {
      if (items.isEmpty) return;
      final height = complete ? (contentWidth - spacing * (items.length - 1)) / aspectSum : targetHeight;
      rows.add((List.of(items), height.clamp(48.0, targetHeight * 2.4)));
      items = [];
      aspectSum = 0;
    }

    for (var i = 0; i < entries.length; i++) {
      final aspect = _aspectOf(entries[i]);
      final nextCount = items.length + 1;
      final nextWidth = (aspectSum + aspect) * targetHeight + spacing * (nextCount - 1);
      if (items.isNotEmpty && nextWidth > contentWidth) {
        flushRow(complete: true);
      }
      items.add(i);
      aspectSum += aspect;
    }
    flushRow(complete: false);

    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        sliver: SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (context, rowIndex) {
            final (indices, height) = rows[rowIndex];
            return Padding(
              padding: const EdgeInsets.only(bottom: spacing),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var k = 0; k < indices.length; k++) ...[
                    if (k > 0) const SizedBox(width: spacing),
                    SizedBox(
                      width: _aspectOf(entries[indices[k]]) * height,
                      height: height,
                      child: _WebDavTile(
                        key: ValueKey(entries[indices[k]].uri),
                        entry: entries[indices[k]],
                        extent: math.max(_aspectOf(entries[indices[k]]) * height, 48),
                        devicePixelRatio: dpr,
                        cancellableNotifier: _isScrolling,
                        showName: showNames,
                        isMosaic: true,
                        onTap: () => _openEntry(entries, entries[indices[k]]),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    ];
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0x33000000),
      child: Center(
        child: Icon(Icons.play_circle_outline, color: Colors.white, size: 32),
      ),
    );
  }
}

class _WebDavTile extends StatelessWidget {
  final AvesEntry entry;
  final double extent;
  final double devicePixelRatio;
  final ValueNotifier<bool> cancellableNotifier;
  final bool isMosaic;
  final bool showName;
  final VoidCallback onTap;

  const new({
    super.key,
    required this.entry,
    required this.extent,
    required this.devicePixelRatio,
    required this.cancellableNotifier,
    required this.onTap,
    this.isMosaic = false,
    this.showName = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget content = entry.isVideo
        ? const _VideoPlaceholder()
        : ThumbnailImage(
            entry: entry,
            extent: extent,
            devicePixelRatio: devicePixelRatio,
            fit: BoxFit.cover,
            isMosaic: isMosaic,
            cancellableNotifier: cancellableNotifier,
            heroTag: null,
          );
    if (showName) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          content,
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 3),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
              child: Text(
                entry.sourceTitle ?? entry.bestTitle ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
        ],
      );
    }
    return InkWell(onTap: onTap, child: content);
  }
}
