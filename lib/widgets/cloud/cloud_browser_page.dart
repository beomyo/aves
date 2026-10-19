import 'dart:async';
import 'dart:convert';
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
import 'package:aves/services/common/services.dart';
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
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
  static const int _maxFolderSnapshots = 30;
  static const int _maxFolderLists = 60;

  final ValueNotifier<_LoadState> _state = ValueNotifier(_LoadState.loading);
  final ValueNotifier<String> _error = ValueNotifier('');
  final ValueNotifier<List<CloudResource>> _folders = ValueNotifier([]);
  final ValueNotifier<List<AvesEntry>> _media = ValueNotifier([]);
  final ValueNotifier<bool> _isScrolling = ValueNotifier(false);
  final ScrollController _scrollController = ScrollController();
  final ScrollController _addressScrollController = ScrollController();
  final GlobalKey _currentCrumbKey = GlobalKey();
  final GlobalKey _addressViewportKey = GlobalKey();

  // visited folders, in navigation order. Going back moves `_trailIndex`
  // without dropping the deeper entries, so the address bar can still offer
  // them and returning to one is instant (the listing is cached).
  List<String> _trail = [];
  int _trailIndex = 0;
  late String _currentUrl;
  Timer? _scrollTimer;
  StreamSubscription? _settingsSub;

  // listing snapshots per folder, so navigating back and forth does not list
  // the same folder again; `_folderLists` only keeps the folders of a listing
  // and is enough to find the sibling to move to on over-scroll
  final Map<String, _FolderSnapshot> _folderSnapshots = {};
  final Map<String, List<CloudResource>> _folderLists = {};
  final Set<String> _primingParents = {};
  final Map<String, DateTime> _siblingRetryAfter = {};

  // over-scroll progress towards the next sibling folder (mosaic only)
  final ValueNotifier<double> _nextFolderProgress = ValueNotifier(0);
  final ValueNotifier<CloudResource?> _nextFolder = ValueNotifier(null);
  Timer? _overscrollTimer;
  double _overscroll = 0;
  double _overscrollThreshold = 0;

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
  Timer? _abandonTimer;

  String get _baseUrl => widget.server.url.endsWith('/') ? widget.server.url : '${widget.server.url}/';

  @override
  void initState() {
    super.initState();
    _currentUrl = _asFolderUrl(widget.initialUrl ?? _baseUrl);
    _trail = [..._ancestorsFor(_currentUrl), _currentUrl];
    _trailIndex = _trail.length - 1;
    _scrollController.addListener(_onScroll);
    _settingsSub = settings.updateStream.listen((event) {
      if (const [
        SettingKeys.cloudImageLayoutKey,
        SettingKeys.cloudVideoLayoutKey,
        SettingKeys.cloudFolderLayoutsKey,
        SettingKeys.cloudLayoutPerFolderKey,
      ].contains(event.key)) {
        // the mosaic lays out with the aspect ratios already learned from
        // thumbnails; switching layouts only needs a rebuild
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
          setState(() {});
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
    // the page is going away: stop generating the thumbnails of this folder
    _abandonThumbnailsSoon(_media.value.map((e) => e.uri));
    _settingsSub?.cancel();
    _scrollTimer?.cancel();
    _aspectFlushTimer?.cancel();
    _overscrollTimer?.cancel();
    // persist the progress gathered while browsing before the page goes away
    settings.flushCloudFolderStats();
    _scrollController.dispose();
    _addressScrollController.dispose();
    _state.dispose();
    _error.dispose();
    _folders.dispose();
    _media.dispose();
    _isScrolling.dispose();
    _nextFolderProgress.dispose();
    _nextFolder.dispose();
    super.dispose();
  }

  void _onScroll() {
    // cancel pending thumbnail loads while scrolling
    _isScrolling.value = true;
    _scrollTimer?.cancel();
    _scrollTimer = Timer(const Duration(milliseconds: 400), () {
      _isScrolling.value = false;
    });

    // near the end of a mosaic, fetch the parent listing so the over-scroll
    // gesture can name the next folder. Done here (not when the folder opens)
    // so it cannot delay browsing or the next folder's listing.
    if (_scrollController.hasClients) {
      final position = _scrollController.position;
      if (position.extentAfter < position.viewportDimension * .5) {
        _primeSiblings();
      }
    }

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
    final crumbs = _breadcrumbs(_currentUrl);
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

  List<(String, String)> _breadcrumbs(String url) {
    final base = _baseUrl;
    final crumbs = <(String, String)>[];
    if (url.startsWith(base)) {
      final segments = url.substring(base.length).split('/').where((s) => s.isNotEmpty).toList();
      var acc = base;
      for (var i = 0; i < segments.length; i++) {
        acc = '$acc${segments[i]}/';
        crumbs.add((_decode(segments[i]), i == segments.length - 1 ? url : acc));
      }
    }
    return crumbs;
  }

  // deepest folder reached on this branch. The trail keeps the entries the user
  // went back from, so the address bar can offer them without re-listing.
  String get _deepestTrailUrl {
    var deepest = _currentUrl;
    for (var i = _trailIndex + 1; i < _trail.length; i++) {
      final url = _trail[i];
      if (url != _currentUrl && url.startsWith(_currentUrl) && url.length > deepest.length) {
        deepest = url;
      }
    }
    return deepest;
  }

  static String _trimFolderUrl(String url) => url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  // collection URLs from a server may or may not end with a slash; keep ours
  // canonical so cache keys and progress entries always match
  static String _asFolderUrl(String url) => url.endsWith('/') ? url : '$url/';

  static bool _sameFolder(String a, String b) => _trimFolderUrl(a) == _trimFolderUrl(b);

  String? _parentOf(String url) {
    final current = _trimFolderUrl(url);
    final base = _trimFolderUrl(_baseUrl);
    if (current == base || !current.startsWith(base)) return null;
    final last = current.lastIndexOf('/');
    if (last < 0) return null;
    final parent = current.substring(0, last + 1);
    return parent.length > base.length ? parent : null;
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

  void _navigateTo(String rawUrl) {
    final url = _asFolderUrl(rawUrl);
    if (_sameFolder(url, _currentUrl)) return;
    // stop generating the thumbnails of the folder being left
    _abandonThumbnailsSoon(_media.value.map((e) => e.uri));
    _rememberScrollPosition();
    _resetOverscroll();
    final existing = _trail.indexWhere((v) => _sameFolder(v, url));
    if (existing >= 0) {
      // already visited: reuse the cached listing instead of fetching it again
      _trailIndex = existing;
    } else {
      // a genuinely new path: drop the forward entries and fetch once
      _trail = [..._trail.take(_trailIndex + 1), url];
      _trailIndex = _trail.length - 1;
    }
    // progress is recorded once the listing succeeds, never before the request
    setState(() {
      _currentUrl = url;
      _immersive = false;
    });
    _showFolder(url);
  }

  // moves back through the trail without dropping its forward entries, so the
  // address bar can still show (and return to) the folder we came from
  void _goBack() {
    if (_trailIndex <= 0) return;
    _rememberScrollPosition();
    _abandonThumbnailsSoon(_media.value.map((e) => e.uri));
    _resetOverscroll();
    _trailIndex--;
    setState(() {
      _currentUrl = _trail[_trailIndex];
      _immersive = false;
    });
    _showFolder(_currentUrl);
  }

  void _showFolder(String url) {
    final snapshot = _folderSnapshots[url];
    if (snapshot == null) {
      _fetch();
      return;
    }
    _state.value = _LoadState.ready;
    _folders.value = snapshot.folders;
    _media.value = snapshot.media;
    _rememberFolderList(url, snapshot.folders);
    _restoreScrollPosition(url);
    _revealCurrentCrumb();
  }

  // keep the current segment visible even when the bar still shows the deeper
  // folders we went back from
  void _revealCurrentCrumb() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final crumbContext = _currentCrumbKey.currentContext;
      final viewportContext = _addressViewportKey.currentContext;
      if (crumbContext == null || viewportContext == null || !_addressScrollController.hasClients) return;
      final crumbBox = crumbContext.findRenderObject() as RenderBox?;
      final viewportBox = viewportContext.findRenderObject() as RenderBox?;
      if (crumbBox == null || viewportBox == null || !crumbBox.hasSize || !viewportBox.hasSize) return;
      // centre the current segment without touching the vertical scroll view
      final offset = crumbBox.localToGlobal(Offset.zero, ancestor: viewportBox).dx;
      final target = _addressScrollController.offset + offset - (viewportBox.size.width - crumbBox.size.width) / 2;
      _addressScrollController.jumpTo(target.clamp(0.0, _addressScrollController.position.maxScrollExtent));
    });
  }

  // in mosaic the layout depends on knowing the folder contents; keep the
  // sibling list around so the over-scroll gesture can name the next folder
  void _primeSiblings() {
    // only the mosaic layout uses the gesture, and only once its own listing
    // has arrived: do not compete with the request we are waiting for
    if (_state.value != _LoadState.ready) return;
    if (_resolvedLayout(_media.value) != 'mosaic') return;
    final parent = _parentOf(_currentUrl);
    if (parent == null || _folderLists.containsKey(parent) || !_primingParents.add(parent)) return;
    final retryAfter = _siblingRetryAfter[parent];
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) {
      _primingParents.remove(parent);
      return;
    }
    unawaited(_fetchSiblings(parent));
  }

  void _rememberFolderList(String parent, List<CloudResource> folders) {
    _folderLists.remove(parent);
    _folderLists[parent] = folders;
    while (_folderLists.length > _maxFolderLists) {
      _folderLists.remove(_folderLists.keys.first);
    }
  }

  void _rememberSnapshot(String url, _FolderSnapshot snapshot) {
    _folderSnapshots.remove(url);
    _folderSnapshots[url] = snapshot;
    while (_folderSnapshots.length > _maxFolderSnapshots) {
      _folderSnapshots.remove(_folderSnapshots.keys.first);
    }
    _rememberFolderList(url, snapshot.folders);
  }

  Future<void> _fetchSiblings(String parent) async {
    try {
      final client = cloudRegistry.clientForServer(widget.server);
      if (client == null) return;
      final resources = await client.list(parent);
      if (!mounted) return;
      _rememberFolderList(parent, resources.where((r) => r.isCollection).toList());
      _siblingRetryAfter.remove(parent);
    } catch (_) {
      // best effort: without the parent listing over-scroll navigation is
      // simply unavailable for this folder. Do not retry on every scroll tick.
      _siblingRetryAfter[parent] = DateTime.now().add(const Duration(seconds: 30));
    } finally {
      _primingParents.remove(parent);
    }
  }

  CloudResource? _nextFolderInParent() {
    final parent = _parentOf(_currentUrl);
    if (parent == null) return null;
    final folders = _folderLists[parent];
    if (folders == null || folders.length < 2) return null;
    final sorted = _sortByName(folders, (f) => f.name, settings.cloudSort == 'nameDesc');
    final index = sorted.indexWhere((f) => _sameFolder(f.url, _currentUrl));
    if (index < 0 || index + 1 >= sorted.length) return null;
    return sorted[index + 1];
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is OverscrollNotification && notification.metrics.axis == Axis.vertical) {
      if (_resolvedLayout(_media.value) != 'mosaic') return false;
      if (notification.metrics.extentAfter > 0 || notification.overscroll <= 0) return false;
      final next = _nextFolderInParent();
      if (next == null) {
        // the parent listing is not known yet: fetch it, the next attempt will
        // be able to show the hint
        _primeSiblings();
        return false;
      }
      _nextFolder.value = next;
      _overscrollThreshold = MediaQuery.sizeOf(context).height / 3;
      _overscroll += notification.overscroll;
      _nextFolderProgress.value = (_overscroll / _overscrollThreshold).clamp(0.0, 1.0);
      _overscrollTimer?.cancel();
      _overscrollTimer = Timer(const Duration(milliseconds: 700), _resetOverscroll);
      if (_overscroll >= _overscrollThreshold) {
        _resetOverscroll();
        HapticFeedback.mediumImpact();
        _navigateTo(next.url);
      }
      return false;
    }
    if (notification is ScrollUpdateNotification && notification.metrics.extentAfter > 0) {
      _resetOverscroll();
    }
    return false;
  }

  void _resetOverscroll() {
    _overscrollTimer?.cancel();
    _overscrollTimer = null;
    _overscroll = 0;
    _nextFolderProgress.value = 0;
    _nextFolder.value = null;
  }

  // `keepContent` is used by pull-to-refresh: the current tiles stay visible
  // (and keep their entries, so video frames are not requested again) until the
  // fresh listing replaces them
  Future<void> _fetch({bool keepContent = false}) async {
    final url = _currentUrl;
    if (!keepContent) {
      _state.value = _LoadState.loading;
      _folders.value = [];
      _media.value = [];
    }
    try {
      final client = cloudRegistry.clientForServer(widget.server);
      if (client == null) {
        throw StateError('server not found');
      }
      final resources = await client.list(url);
      if (!mounted || url != _currentUrl) return;

      final folders = resources.where((r) => r.isCollection).toList();
      final previous = keepContent ? {for (final entry in _media.value) entry.uri: entry} : const <String, AvesEntry>{};
      final media = <AvesEntry>[];
      var index = 0;
      for (final resource in resources.where((r) => !r.isCollection)) {
        final mime = _mimeForResource(resource);
        if (!MimeTypes.isImage(mime) && !MimeTypes.isVideo(mime)) continue;
        media.add(previous[resource.url] ?? _entryFromResource(resource, mime, -1 - index));
        index++;
      }

      _rememberSnapshot(url, _FolderSnapshot(folders, media));
      _folders.value = folders;
      _media.value = media;
      _state.value = _LoadState.ready;

      if (!keepContent) {
        _restoreScrollPosition(url);
      }
      _revealCurrentCrumb();

      // the grid is on screen first: progress persistence and the "last
      // location" write must not sit between the listing response and the frame,
      // and must never run before the request (a slow store would delay it)
      final imageCount = media.where((e) => e.isImage).length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        settings.recordCloudFolder(url, imageCount: imageCount, folderCount: folders.length);
        settings.markCloudFolderVisited(url);
        if (mounted && url == _currentUrl) {
          if (settings.cloudLastServerId != widget.server.id || settings.cloudLastUrl != url) {
            settings.setCloudLastLocation(widget.server.id, url);
          }
        }
      });
    } catch (error) {
      if (!mounted || url != _currentUrl) return;
      if (keepContent) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$error')));
        return;
      }
      _error.value = error.toString();
      _state.value = _LoadState.error;
    }
  }

  // the aspect ratio is learned from each thumbnail that loads (see
  // `_onTileImageInfo`). Probing every file with a separate Range request used
  // to flood rate limited servers and delay the next folder's listing.
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

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirmDelete(String message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.entryActionDelete),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.webdavActionCancel)),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.entryActionDelete),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  // long press on a tile: delete the file from the server (no local copy)
  Future<void> _deleteEntry(AvesEntry entry) async {
    final name = entry.sourceTitle ?? entry.bestTitle ?? entry.uri;
    if (!await _confirmDelete(context.l10n.cloudDeleteFileConfirmation(name)) || !mounted) return;
    try {
      final client = cloudRegistry.clientForServer(widget.server);
      if (client == null) throw StateError('server not found');
      await client.delete(entry.uri);
      await evictCloudThumbnail(entry.uri);
      EntryCache.evict(entry.uri);
      if (entry.isImage) settings.forgetCloudImage(entry.uri);
      _removeMedia(entry);
    } catch (error) {
      if (!mounted) return;
      _showMessage('${context.l10n.cloudDeleteFailed}: $error');
    }
  }

  void _removeMedia(AvesEntry entry) {
    if (!mounted) return;
    final url = _currentUrl;
    final folders = _folders.value;
    final media = _media.value.where((e) => e.uri != entry.uri).toList();
    _media.value = media;
    _rememberSnapshot(url, _FolderSnapshot(folders, media));
    _aspects.remove(entry.uri);
    settings.recordCloudFolder(
      url,
      imageCount: media.where((e) => e.isImage).length,
      folderCount: folders.length,
    );
    setState(() {});
  }

  // long press on a folder row: delete it and everything it contains
  Future<void> _deleteFolder(CloudResource folder) async {
    if (!await _confirmDelete(context.l10n.cloudDeleteFolderConfirmation(folder.name)) || !mounted) return;
    try {
      final client = cloudRegistry.clientForServer(widget.server);
      if (client == null) throw StateError('server not found');
      await client.delete(folder.url);
      _removeFolder(folder);
    } catch (error) {
      if (!mounted) return;
      _showMessage('${context.l10n.cloudDeleteFailed}: $error');
    }
  }

  void _removeFolder(CloudResource folder) {
    if (!mounted) return;
    final url = _currentUrl;
    final folders = _folders.value.where((f) => f.url != folder.url).toList();
    final media = _media.value;
    _folders.value = folders;
    _rememberSnapshot(url, _FolderSnapshot(folders, media));
    settings.recordCloudFolder(
      url,
      imageCount: media.where((e) => e.isImage).length,
      folderCount: folders.length,
    );
    settings.forgetCloudFolder(folder.url);
    _folderSnapshots.remove(folder.url);
    _folderLists.remove(folder.url);
    setState(() {});
  }

  // a compact JSON backup of the folder progress, so reinstalling the app does
  // not lose which pictures have already been seen
  Future<void> _exportProgress() async {
    final json = settings.exportCloudFolderStats();
    final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(json));
    final basename = 'aves-cloud-progress-${DateTime.now().millisecondsSinceEpoch}';
    final result = await storageService.createFile(basename: basename, mimeType: MimeTypes.json, bytes: bytes);
    if (!mounted) return;
    if (result == true) {
      _showMessage(context.l10n.genericSuccessFeedback);
    } else if (result == false) {
      _showMessage(context.l10n.genericFailureFeedback);
    }
  }

  Future<void> _importProgress() async {
    final bytes = await storageService.openFile();
    if (!mounted || bytes.isEmpty) return;
    try {
      final count = settings.importCloudFolderStats(jsonDecode(utf8.decode(bytes)));
      if (count > 0) {
        _showMessage(context.l10n.cloudProgressImported(count));
        if (mounted) setState(() {});
      } else {
        _showMessage(context.l10n.genericFailureFeedback);
      }
    } catch (_) {
      _showMessage(context.l10n.genericFailureFeedback);
    }
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
      canPop: _trailIndex <= 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _goBack();
      },
      child: AvesScaffold(
        drawer: const AppDrawer(),
        body: Stack(
          children: [
            ValueListenableBuilder<_LoadState>(
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
            _NextFolderHint(folder: _nextFolder, progress: _nextFolderProgress),
          ],
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
          // refresh keeps the current tiles (and their image providers) in
          // place: clearing them made every video frame look regenerated
          onRefresh: () => _fetch(keepContent: true),
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              // build a screen and a half ahead, so thumbnails of the images
              // about to enter the viewport are already on their way
              scrollCacheExtent: layout == 'mosaic' || layout == 'grid' ? const ScrollCacheExtent.viewport(1) : const ScrollCacheExtent.pixels(800),
              slivers: [
                _buildAppBar(context, immersiveEnabled, videoMode),
                ...contentSlivers,
              ],
            ),
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
          onPressed: () => showCloudViewOptions(
            context,
            url: _currentUrl,
            video: videoMode,
            onRebuildThumbnails: _rebuildThumbnails,
            onExportProgress: _exportProgress,
            onImportProgress: _importProgress,
          ),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(CloudBrowserPage.addressBarHeight),
        child: _buildAddressBar(context),
      ),
    );
  }

  Widget _buildAddressBar(BuildContext context) {
    // the trail keeps the folders we went back from, so the address bar can
    // still show that depth and return to any of them without re-listing
    final crumbs = _breadcrumbs(_deepestTrailUrl);
    final entries = <(String, String)>[(context.l10n.webdavRoot, _baseUrl), ...crumbs];
    final currentIndex = entries.indexWhere((crumb) => _sameFolder(crumb.$2, _currentUrl));
    final selected = currentIndex < 0 ? entries.length - 1 : currentIndex;
    final atRoot = _sameFolder(_currentUrl, _baseUrl);
    final disabledColor = Theme.of(context).disabledColor;
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
              key: _addressViewportKey,
              controller: _addressScrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0) const Icon(Icons.chevron_right, size: 16),
                    InkWell(
                      key: i == selected ? _currentCrumbKey : null,
                      onTap: i == selected ? null : () => _navigateTo(entries[i].$2),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                        child: Text(
                          entries[i].$1,
                          style: TextStyle(
                            // folders deeper than the current one were reached
                            // before: dimmed, but still tappable to go forward
                            color: i == selected ? Theme.of(context).colorScheme.primary : (i > selected ? disabledColor : null),
                            fontWeight: i == selected ? FontWeight.bold : null,
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
    final hintColor = Theme.of(context).hintColor;
    return SliverList.builder(
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        // collection URLs may differ by a trailing slash
        final isVisited = visited.contains(folder.url) || settings.isCloudFolderVisited(folder.url);
        final color = isVisited ? disabledColor : null;
        // "loaded/total" for an image folder, "opened/total" for a folder of
        // folders; one level deep, nothing is counted recursively
        final progress = settings.cloudFolderProgressText(folder.url);
        return ListTile(
          minLeadingWidth: 56,
          leading: SizedBox(
            width: 56,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(AIcons.folder, color: color),
                if (progress != null)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      progress,
                      maxLines: 1,
                      style: TextStyle(fontSize: 10, height: 1.1, color: color ?? hintColor),
                    ),
                  ),
              ],
            ),
          ),
          title: Text(folder.name, style: TextStyle(color: color)),
          onTap: () => _openFolder(folder),
          onLongPress: () => _deleteFolder(folder),
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
  static double? _progressOf(AvesEntry entry) {
    if (!entry.isVideo) return null;
    final position = settings.cloudVideoPosition(entry.uri);
    final duration = settings.cloudVideoDuration(entry.uri);
    if (position == null || duration == null || duration <= 0) return null;
    return (position / duration).clamp(0.0, 1.0);
  }

  // a thumbnail decoded: remember the aspect ratio for the mosaic layout and,
  // for images, count the picture as loaded in its folder progress
  void _onTileImageInfo(AvesEntry entry, ImageInfo info) {
    final image = info.image;
    final width = image.width;
    final height = image.height;
    if (width > 0 && height > 0) {
      _onTileAspect(entry.uri, width / height);
    }
    if (entry.isImage) {
      settings.markCloudImageLoaded(entry.uri);
    }
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
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (entry.isVideo) const _VideoPlaceholder(),
                ThumbnailImage(
                  entry: entry,
                  extent: 56,
                  devicePixelRatio: dpr,
                  fit: BoxFit.cover,
                  cancellableNotifier: _isScrolling,
                  errorPlaceholder: entry.isVideo ? const SizedBox.shrink() : null,
                  onImageInfo: (info) => _onTileImageInfo(entry, info),
                ),
                if (entry.isVideo) _VideoLoadingOverlay(entry.uri),
              ],
            ),
          ),
          title: Text(
            entry.sourceTitle ?? entry.bestTitle ?? '',
            style: watched ? TextStyle(color: Theme.of(context).disabledColor) : null,
          ),
          subtitle: subtitleText.isEmpty ? null : Text(subtitleText),
          trailing: entry.isVideo && showVideoPlayIcon ? const Icon(Icons.play_circle_outline, size: 20) : null,
          onTap: () => _openEntry(entries, entry),
          onLongPress: () => _deleteEntry(entry),
        );
      },
    );
  }

  Widget _buildGridSliver(BuildContext context, List<AvesEntry> entries, double columns, bool showNames, bool showSizes) {
    final crossAxisCount = columns.round().clamp(1, 10);
    final width = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // no padding or spacing: the images touch each other edge to edge
    return SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 0,
        crossAxisSpacing: 0,
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
          onImageInfo: _onTileImageInfo,
          onTap: () => _openEntry(entries, entry),
          onLongPress: () => _deleteEntry(entry),
        );
      },
    );
  }

  List<Widget> _buildMosaicSlivers(BuildContext context, List<AvesEntry> entries, double columns, bool showNames, bool showSizes) {
    final width = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final targetHeight = width / columns;
    // no gaps: rows are edge to edge, and the whole mosaic uses the full width
    final contentWidth = width;
    final rows = <(List<int> indices, double height)>[];

    var items = <int>[];
    var aspectSum = 0.0;

    void flushRow({required bool complete}) {
      if (items.isEmpty) return;
      final height = complete ? width / aspectSum : targetHeight;
      rows.add((List.of(items), height.clamp(48.0, targetHeight * 2.4)));
      items = [];
      aspectSum = 0;
    }

    for (var i = 0; i < entries.length; i++) {
      final aspect = _aspectOf(entries[i]);
      final nextWidth = (aspectSum + aspect) * targetHeight;
      if (items.isNotEmpty && nextWidth > contentWidth) {
        flushRow(complete: true);
      }
      items.add(i);
      aspectSum += aspect;
    }
    flushRow(complete: false);

    return [
      SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, rowIndex) {
          final (indices, height) = rows[rowIndex];
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var k = 0; k < indices.length; k++)
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
                    onImageInfo: _onTileImageInfo,
                    onTap: () => _openEntry(entries, entries[indices[k]]),
                    onLongPress: () => _deleteEntry(entries[indices[k]]),
                  ),
                ),
            ],
          );
        },
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
  final VoidCallback? onLongPress;
  final void Function(AvesEntry entry, ImageInfo info)? onImageInfo;

  const new({
    super.key,
    required this.entry,
    required this.extent,
    required this.devicePixelRatio,
    required this.cancellableNotifier,
    required this.onTap,
    this.onLongPress,
    this.isMosaic = false,
    this.showName = false,
    this.showSize = false,
    this.watched = false,
    this.progress,
    this.onImageInfo,
  });

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
            onImageInfo: (info) => onImageInfo?.call(entry, info),
          ),
          // the frame is being extracted: say so instead of showing an empty tile
          _VideoLoadingOverlay(entry.uri),
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
        onImageInfo: (info) => onImageInfo?.call(entry, info),
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
    return InkWell(onTap: onTap, onLongPress: onLongPress, child: content);
  }
}

// a small spinner over a video tile while its frame is being extracted
class _VideoLoadingOverlay extends StatelessWidget {
  final String uri;

  const new(this.uri);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: cloudGeneratingVideoThumbnails,
      builder: (context, generating, child) {
        if (!generating.contains(uri)) return const SizedBox.shrink();
        return const Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
              child: Padding(
                padding: EdgeInsets.all(5),
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
            ),
          ),
        );
      },
    );
  }
}

// over-scroll hint shown while the user is pulling past the end of a mosaic
class _NextFolderHint extends StatelessWidget {
  final ValueListenable<CloudResource?> folder;
  final ValueListenable<double> progress;

  const new({required this.folder, required this.progress});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CloudResource?>(
      valueListenable: folder,
      builder: (context, next, child) {
        if (next == null) return const SizedBox.shrink();
        return ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, child) {
            if (value <= 0) return const SizedBox.shrink();
            return Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(left: 16, right: 16, bottom: 16 + MediaQuery.paddingOf(context).bottom),
                child: IgnorePointer(
                  child: Material(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(24),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 20),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              context.l10n.cloudNextFolder(next.name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 72,
                            child: LinearProgressIndicator(
                              value: value.clamp(0.0, 1.0),
                              minHeight: 3,
                              backgroundColor: Colors.white24,
                              valueColor: const AlwaysStoppedAnimation(Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// listing kept in memory so navigating within the trail is instant
class _FolderSnapshot {
  final List<CloudResource> folders;
  final List<AvesEntry> media;

  const new(this.folders, this.media);
}
