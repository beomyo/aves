import 'dart:async';
import 'dart:math' as math;

import 'package:aves/model/entry/cache.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/cloud/cloud_resource.dart';
import 'package:aves/model/source/cloud/cloud_server.dart';
import 'package:aves/ref/mime_types.dart';
import 'package:aves/services/common/cloud_registry.dart';
import 'package:aves/services/media/cloud_fetch_service.dart';
import 'package:aves/services/media/cloud_mime.dart';
import 'package:aves/theme/format.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/utils/file_utils.dart';
import 'package:aves/widgets/common/basic/draggable_scrollbar/scrollbar.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/behaviour/eager_scale_gesture_recognizer.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/empty.dart';
import 'package:aves/widgets/common/identity/scroll_thumb.dart';
import 'package:aves/widgets/common/thumbnail/image.dart';
import 'package:aves/widgets/navigation/drawer/app_drawer.dart';
import 'package:aves/widgets/cloud/cloud_server_list_page.dart';
import 'package:aves/widgets/cloud/cloud_video_page.dart';
import 'package:aves/widgets/cloud/cloud_view_options.dart';
import 'package:aves/widgets/cloud/cloud_viewer_page.dart';
import 'package:aves_model/aves_model.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

enum _LoadState { loading, ready, error }

// duration badge of a cloud video, or null when it is unknown or hidden
String? _cloudVideoDurationText(AvesEntry entry, {required bool visible}) {
  if (!entry.isVideo || !visible) return null;
  final durationMillis = settings.cloudVideoDuration(entry.uri);
  if (durationMillis == null || durationMillis <= 0) return null;
  return formatFriendlyDuration(Duration(milliseconds: durationMillis));
}

class CloudBrowserPage extends StatefulWidget {
  static const routeName = '/cloud/browse';
  static const double addressBarHeight = 42;

  final CloudServer server;
  final String? initialUrl;

  const new({super.key, required this.server, this.initialUrl});

  @override
  State<CloudBrowserPage> createState() => _CloudBrowserPageState();
}

class _CloudBrowserPageState extends State<CloudBrowserPage> {
  static const int _maxProbeCount = 400;
  static const int _probeConcurrency = 4;
  static const double _mosaicSpacing = 4;

  final ValueNotifier<_LoadState> _state = ValueNotifier(_LoadState.loading);
  final ValueNotifier<String> _error = ValueNotifier('');
  final ValueNotifier<List<CloudResource>> _folders = ValueNotifier([]);
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
  Timer? _abandonTimer;

  String get _baseUrl => widget.server.url.endsWith('/') ? widget.server.url : '${widget.server.url}/';

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.initialUrl ?? _baseUrl;
    _history = _ancestorsFor(_currentUrl);
    _scrollController.addListener(_onScroll);
    _settingsSub = settings.updateStream.listen((event) {
      if (const [
        SettingKeys.cloudImageLayoutKey,
        SettingKeys.cloudVideoLayoutKey,
        SettingKeys.cloudFolderLayoutsKey,
        SettingKeys.cloudLayoutPerFolderKey,
      ].contains(event.key)) {
        if (_resolvedLayout(_media.value) == 'mosaic') {
          _maybeProbe(_media.value, 'mosaic');
        }
      } else if (event.key == SettingKeys.cloudVideoPositionsKey) {
        // a duration probed while extracting a thumbnail arrived in the
        // background: refresh the badges (the video player writes this key too,
        // hence the visible-route guard)
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
          setState(() {});
        }
      }
    });
    _fetch();
  }

  @override
  void dispose() {
    _probeGeneration++;
    // the page is going away: stop generating the thumbnails of this folder
    _abandonThumbnailsSoon(_media.value.map((e) => e.uri));
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

    if (!settings.cloudImmersive) {
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
    // stop generating the thumbnails of the folder being left
    _abandonThumbnailsSoon(_media.value.map((e) => e.uri));
    _rememberScrollPosition();
    settings.markCloudVisited(url);
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
    settings.markCloudVisited(parent);
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
      final client = cloudRegistry.clientForServer(widget.server);
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

      if (settings.cloudLastServerId != widget.server.id || settings.cloudLastUrl != url) {
        settings.setCloudLastLocation(widget.server.id, url);
      }

      _restoreScrollPosition(url);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_addressScrollController.hasClients) {
          _addressScrollController.jumpTo(_addressScrollController.position.maxScrollExtent);
        }
      });
      _maybeProbe(media, _resolvedLayout(media));
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
        final aspect = await cloudImageLoader.probeAspect(pending[i]);
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

  // records the real aspect ratio of a video, taken from its extracted frame,
  // so the mosaic layout does not have to fall back to 16/9
  void _onTileAspect(String uri, double aspect) {
    if (!mounted || !aspect.isFinite || aspect <= 0) return;
    final current = _aspects[uri];
    if (current != null && (current - aspect).abs() / current < 0.02) return;
    _aspects[uri] = aspect;
    _scheduleAspectFlush();
  }

  // drops the cached thumbnails of the entries of the current folder (the
  // persisted payloads and the in-memory image keys), so they are fetched again
  Future<void> _rebuildThumbnails() async {
    final entries = _media.value;
    for (final entry in entries) {
      await evictCloudThumbnail(entry.uri);
      EntryCache.evict(entry.uri);
    }
    // aspect ratios were derived from the discarded images
    _aspects.clear();
    if (mounted) setState(() {});
  }

  // stops extracting the thumbnails of a folder that is no longer on screen,
  // after a short grace period so an accidental tap does not lose progress
  void _abandonThumbnailsSoon(Iterable<String> uris) {
    final list = uris.toList();
    if (list.isEmpty) return;
    _abandonTimer?.cancel();
    _abandonTimer = Timer(const Duration(seconds: 3), () {
      _abandonTimer = null;
      abandonCloudVideoThumbnails(list);
    });
  }

  double _aspectOf(AvesEntry entry) => (entry.isVideo ? (_aspects[entry.uri] ?? 16 / 9) : (_aspects[entry.uri] ?? 1.0)).clamp(0.35, 2.6);

  void _onScaleStart(ScaleStartDetails details) {
    _scaleStartColumns = settings.cloudColumns;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount < 2) return;
    final scale = details.scale;
    if (scale <= 0) return;
    final columns = (_scaleStartColumns / scale).clamp(1.0, 8.0);
    if ((columns - settings.cloudColumns).abs() >= 0.02) {
      settings.cloudColumns = columns;
    }
  }

  AvesEntry _entryFromResource(CloudResource resource, String mimeType, int id) {
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
      origin: widget.server.isSmb ? EntryOrigins.smb : EntryOrigins.webDav,
    );
  }

  static String _mimeForResource(CloudResource resource) => cloudMimeForResource(resource);

  void _openFolder(CloudResource folder) => _navigateTo(folder.url);

  // opens the service management page, so another service can be added from here
  void _openServers() {
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: CloudServerListPage.routeName),
        builder: (context) => const CloudServerListPage(showResume: false),
      ),
    );
  }

  Future<void> _openEntry(List<AvesEntry> visibleEntries, AvesEntry entry) async {
    if (entry.isVideo) {
      // remember that this video was opened, and where we stopped watching
      setState(() => settings.markCloudVisited(entry.uri));
      // the video backend streams the file itself, so hand it a URL it can
      // consume: an authenticated URL for WebDAV, a loopback bridge for SMB
      final playableUrl = await cloudRegistry.playbackUrl(entry.uri);
      if (!mounted) return;
      final playableEntry = playableUrl == entry.uri ? entry : entry.copyWith(uri: playableUrl);
      await Navigator.push(
        context,
        MaterialPageRoute(
          settings: const RouteSettings(name: CloudVideoPage.routeName),
          builder: (context) => CloudVideoPage(entry: playableEntry, storageUri: entry.uri),
        ),
      );
      if (mounted) setState(() {});
      return;
    }
    final index = visibleEntries.indexOf(entry);
    final images = visibleEntries.where((e) => e.isImage).toList();
    final imageIndex = images.indexOf(entry);
    if (index < 0 || images.isEmpty || imageIndex < 0) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: CloudViewerPage.routeName),
        builder: (context) => CloudViewerPage(entries: images, initialIndex: imageIndex),
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
            return ValueListenableBuilder<List<CloudResource>>(
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

  Widget _buildScrollView(BuildContext context, {required _LoadState state, required List<CloudResource> folders, required List<AvesEntry> media}) {
    final columns = context.select<Settings, double>((s) => s.cloudColumns);
    final mediaFilter = context.select<Settings, String>((s) => s.cloudMediaFilter);
    final showNames = context.select<Settings, bool>((s) => s.cloudShowNames);
    final showSizes = context.select<Settings, bool>((s) => s.cloudShowSizes);
    final immersiveEnabled = context.select<Settings, bool>((s) => s.cloudImmersive);
    // a folder holding only videos (or the "videos only" filter) uses the video
    // default layout, everything else the image default
    final videoMode = mediaFilter == 'video' || (mediaFilter == 'all' && media.isNotEmpty && media.every((e) => e.isVideo));
    final layout = context.select<Settings, String>((s) => s.cloudLayoutFor(_currentUrl, video: videoMode));
    final topInset = MediaQuery.paddingOf(context).top;
    final headerHeight = topInset + kToolbarHeight + CloudBrowserPage.addressBarHeight;

    final sort = context.select<Settings, String>((s) => s.cloudSort);
    final descending = sort == 'nameDesc';

    final visible = switch (mediaFilter) {
      'image' => media.where((e) => e.isImage).toList(),
      'video' => media.where((e) => e.isVideo).toList(),
      _ => media,
    };
    final sortedFolders = _sortByName(folders, (f) => f.name, descending);
    final sortedVisible = _sortByName(visible, (e) => e.sourceTitle ?? e.bestTitle ?? '', descending);

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
    } else if (sortedFolders.isEmpty && sortedVisible.isEmpty) {
      contentSlivers = [SliverFillRemaining(hasScrollBody: false, child: EmptyContent(icon: AIcons.folder, text: context.l10n.webdavEmptyFolder))];
    } else {
      contentSlivers = [
        if (sortedFolders.isNotEmpty) _buildFolderSliver(context, sortedFolders),
        if (sortedVisible.isNotEmpty)
          if (layout == 'mosaic')
            ..._buildMosaicSlivers(context, sortedVisible, columns, showNames, showSizes)
          else if (layout == 'list')
            _buildListSliver(context, sortedVisible, showNames, showSizes)
          else
            _buildGridSliver(context, sortedVisible, columns, showNames, showSizes),
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
              _buildAppBar(context, immersiveEnabled, videoMode),
              ...contentSlivers,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, bool immersiveEnabled, bool videoMode) {
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
          tooltip: context.l10n.cloudServersPageTitle,
          icon: const Icon(AIcons.cloud),
          onPressed: _openServers,
        ),
        IconButton(
          tooltip: context.l10n.webdavViewOptions,
          icon: const Icon(AIcons.layout),
          onPressed: () => showCloudViewOptions(context, url: _currentUrl, video: videoMode, onRebuildThumbnails: _rebuildThumbnails),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(CloudBrowserPage.addressBarHeight),
        child: _buildAddressBar(context),
      ),
    );
  }

  Widget _buildAddressBar(BuildContext context) {
    final crumbs = _breadcrumbs();
    final atRoot = crumbs.isEmpty;
    return SizedBox(
      height: CloudBrowserPage.addressBarHeight,
      child: Row(
        children: [
          IconButton(
            tooltip: widget.server.displayName,
            icon: Icon(widget.server.isSmb ? Icons.storage_rounded : AIcons.cloud),
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

  Widget _buildFolderSliver(BuildContext context, List<CloudResource> folders) {
    // folders already opened once are dimmed
    final visited = settings.cloudVisited.toSet();
    final disabledColor = Theme.of(context).disabledColor;
    return SliverList.builder(
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        final isVisited = visited.contains(folder.url);
        final color = isVisited ? disabledColor : null;
        return ListTile(
          leading: Icon(AIcons.folder, color: color),
          title: Text(folder.name, style: TextStyle(color: color)),
          onTap: () => _openFolder(folder),
        );
      },
    );
  }

  // effective layout of the current folder: video default for video-only
  // content, image default otherwise, overridden by a per-folder choice
  String _resolvedLayout(List<AvesEntry> media) {
    final filter = settings.cloudMediaFilter;
    final videoMode = filter == 'video' || (filter == 'all' && media.isNotEmpty && media.every((e) => e.isVideo));
    return settings.cloudLayoutFor(_currentUrl, video: videoMode);
  }

  // watch progress (0..1) of a video, or null when unknown
  static double? _progressOf(AvesEntry entry) {    if (!entry.isVideo) return null;
    final position = settings.cloudVideoPosition(entry.uri);
    final duration = settings.cloudVideoDuration(entry.uri);
    if (position == null || duration == null || duration <= 0) return null;
    return (position / duration).clamp(0.0, 1.0);
  }

  static List<T> _sortByName<T>(List<T> items, String Function(T) nameOf, bool descending) {
    final sorted = [...items]..sort((a, b) => nameOf(a).toLowerCase().compareTo(nameOf(b).toLowerCase()));
    return descending ? sorted.reversed.toList() : sorted;
  }

  Widget _buildListSliver(BuildContext context, List<AvesEntry> entries, bool showNames, bool showSizes) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final showVideoDuration = context.select<Settings, bool>((s) => s.cloudVideoDurationVisible);
    final showVideoPlayIcon = context.select<Settings, bool>((s) => s.cloudVideoPlayIcon);
    return SliverList.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final watched = entry.isVideo && settings.isCloudVisited(entry.uri);
        final sizeBytes = entry.sizeBytes;
        final sizeText = (showSizes && sizeBytes != null) ? formatFileSize(settings.avesLocale, sizeBytes, round: 0) : null;
        final durationText = _cloudVideoDurationText(entry, visible: showVideoDuration);
        final subtitleText = [?sizeText, ?durationText].join('  ·  ');
        return ListTile(
          leading: SizedBox(
            width: 56,
            height: 56,
            child: ThumbnailImage(
              entry: entry,
              extent: 56,
              devicePixelRatio: dpr,
              fit: BoxFit.cover,
              cancellableNotifier: _isScrolling,
              errorPlaceholder: entry.isVideo ? const _VideoPlaceholder() : null,
              onImageInfo: entry.isVideo
                  ? (info) {
                      final image = info.image;
                      if (image.width > 0 && image.height > 0) _onTileAspect(entry.uri, image.width / image.height);
                    }
                  : null,
            ),
          ),
          title: Text(
            entry.sourceTitle ?? entry.bestTitle ?? '',
            style: watched ? TextStyle(color: Theme.of(context).disabledColor) : null,
          ),
          subtitle: subtitleText.isEmpty ? null : Text(subtitleText),
          trailing: entry.isVideo && showVideoPlayIcon ? const Icon(Icons.play_circle_outline, size: 20) : null,
          onTap: () => _openEntry(entries, entry),
        );
      },
    );
  }

  Widget _buildGridSliver(BuildContext context, List<AvesEntry> entries, double columns, bool showNames, bool showSizes) {
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
          return _CloudTile(
            key: ValueKey(entry.uri),
            entry: entry,
            extent: width / crossAxisCount,
            devicePixelRatio: dpr,
            cancellableNotifier: _isScrolling,
            showName: showNames,
            showSize: showSizes,
            watched: entry.isVideo && settings.isCloudVisited(entry.uri),
            progress: _progressOf(entry),
            onVideoAspect: _onTileAspect,
            onTap: () => _openEntry(entries, entry),
          );
        },
      ),
    );
  }

  List<Widget> _buildMosaicSlivers(BuildContext context, List<AvesEntry> entries, double columns, bool showNames, bool showSizes) {
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
                      child: _CloudTile(
                        key: ValueKey(entries[indices[k]].uri),
                        entry: entries[indices[k]],
                        extent: math.max(_aspectOf(entries[indices[k]]) * height, 48),
                        devicePixelRatio: dpr,
                        cancellableNotifier: _isScrolling,
                        showName: showNames,
                        showSize: showSizes,
                        watched: entries[indices[k]].isVideo && settings.isCloudVisited(entries[indices[k]].uri),
                        progress: _progressOf(entries[indices[k]]),
                        isMosaic: true,
                        onVideoAspect: _onTileAspect,
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

// dark scrim shown behind a video tile while its frame is extracted (and kept
// when extraction fails), so the tile never flashes a broken-image icon
class _VideoPlaceholder extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Color(0x33000000));
}

// play affordance, duration badge and watch progress, stacked on top of a video
// tile whether or not its frame could be extracted
class _VideoOverlay extends StatelessWidget {
  final double? progress;
  final String? durationText;
  final bool showPlayIcon;

  const new({this.progress, this.durationText, this.showPlayIcon = true});

  @override
  Widget build(BuildContext context) {
    final value = progress;
    final duration = durationText;
    final hasProgress = value != null && value > 0;
    // keep the bottom row clear of the progress bar
    final bottomInset = hasProgress ? 5.0 : 3.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (showPlayIcon)
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: EdgeInsets.only(left: 3, bottom: bottomInset),
              child: const Icon(
                Icons.play_circle_outline,
                color: Colors.white,
                size: 22,
                shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
              ),
            ),
          ),
        if (duration != null)
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: EdgeInsets.only(right: 3, bottom: bottomInset),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  child: Text(
                    duration,
                    style: const TextStyle(color: Colors.white, fontSize: 11, height: 1.2),
                  ),
                ),
              ),
            ),
          ),
        if (hasProgress)
          Align(
            alignment: Alignment.bottomCenter,
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Colors.redAccent),
            ),
          ),
      ],
    );
  }
}

class _CloudTile extends StatelessWidget {
  final AvesEntry entry;
  final double extent;
  final double devicePixelRatio;
  final ValueNotifier<bool> cancellableNotifier;
  final bool isMosaic;
  final bool showName;
  final bool showSize;
  final bool watched;
  final double? progress;
  final VoidCallback onTap;
  final void Function(String uri, double aspect)? onVideoAspect;

  const new({
    super.key,
    required this.entry,
    required this.extent,
    required this.devicePixelRatio,
    required this.cancellableNotifier,
    required this.onTap,
    this.isMosaic = false,
    this.showName = false,
    this.showSize = false,
    this.watched = false,
    this.progress,
    this.onVideoAspect,
  });

  void _onVideoInfo(ImageInfo info) {
    final image = info.image;
    final w = image.width;
    final h = image.height;
    if (w <= 0 || h <= 0) return;
    // the extracted frame keeps the video aspect ratio, so it can drive the
    // mosaic layout the same way probed image dimensions do
    onVideoAspect?.call(entry.uri, w / h);
  }

  @override
  Widget build(BuildContext context) {
    // options are selected here (rather than read from `settings` directly) so
    // that toggling them applies immediately, even from the options sheet
    final showVideoDuration = context.select<Settings, bool>((s) => s.cloudVideoDurationVisible);
    final showVideoPlayIcon = context.select<Settings, bool>((s) => s.cloudVideoPlayIcon);
    Widget content;
    if (entry.isVideo) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          // stands in until the frame arrives, and remains when extraction fails
          const _VideoPlaceholder(),
          // always requested: the thumbnail option only disables automatic
          // extraction, and a frame already known (captured while watching, or
          // cached) must still be shown
          ThumbnailImage(
            entry: entry,
            extent: extent,
            devicePixelRatio: devicePixelRatio,
            fit: BoxFit.cover,
            isMosaic: isMosaic,
            cancellableNotifier: cancellableNotifier,
            heroTag: null,
            showLoadingBackground: false,
            errorPlaceholder: const SizedBox.shrink(),
            onImageInfo: _onVideoInfo,
          ),
          _VideoOverlay(
            progress: progress,
            durationText: _cloudVideoDurationText(entry, visible: showVideoDuration),
            showPlayIcon: showVideoPlayIcon,
          ),
        ],
      );
    } else {
      content = ThumbnailImage(
        entry: entry,
        extent: extent,
        devicePixelRatio: devicePixelRatio,
        fit: BoxFit.cover,
        isMosaic: isMosaic,
        cancellableNotifier: cancellableNotifier,
        heroTag: null,
      );
    }
    // videos already watched are dimmed
    if (watched) {
      content = Opacity(opacity: 0.55, child: content);
    }
    if (showName || showSize) {
      final sizeBytes = entry.sizeBytes;
      final sizeText = (showSize && sizeBytes != null) ? formatFileSize(settings.avesLocale, sizeBytes, round: 0) : null;
      final nameText = showName ? (entry.sourceTitle ?? entry.bestTitle ?? '') : null;
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (nameText != null)
                    Text(
                      nameText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  if (sizeText != null)
                    Text(
                      sizeText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return InkWell(onTap: onTap, child: content);
  }
}
