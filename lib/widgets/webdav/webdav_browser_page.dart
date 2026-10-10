import 'dart:async';
import 'dart:math' as math;

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/webdav/webdav_resource.dart';
import 'package:aves/model/source/webdav/webdav_server.dart';
import 'package:aves/services/common/webdav_registry.dart';
import 'package:aves/services/media/webdav_fetch_service.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/empty.dart';
import 'package:aves/widgets/common/thumbnail/image.dart';
import 'package:aves/widgets/webdav/webdav_layout_bar.dart';
import 'package:aves/widgets/webdav/webdav_viewer_page.dart';
import 'package:aves_model/aves_model.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

enum _LoadState { loading, ready, error }

class WebDavBrowserPage extends StatefulWidget {
  static const routeName = '/webdav/browse';

  final WebDavServer server;
  final String? initialUrl;

  const new({super.key, required this.server, this.initialUrl});

  @override
  State<WebDavBrowserPage> createState() => _WebDavBrowserPageState();
}

class _WebDavBrowserPageState extends State<WebDavBrowserPage> {
  static const int _maxProbeCount = 400;
  static const int _probeConcurrency = 4;

  final ValueNotifier<_LoadState> _state = ValueNotifier(_LoadState.loading);
  final ValueNotifier<String> _error = ValueNotifier('');
  final ValueNotifier<List<WebDavResource>> _folders = ValueNotifier([]);
  final ValueNotifier<List<AvesEntry>> _images = ValueNotifier([]);
  final ValueNotifier<bool> _isScrolling = ValueNotifier(false);
  final ScrollController _scrollController = ScrollController();
  final ScrollController _addressScrollController = ScrollController();

  // ancestors of the current folder (from server root to its parent)
  List<String> _history = [];
  late String _currentUrl;
  Timer? _scrollTimer;
  StreamSubscription? _settingsSub;

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
    // when the user switches to the mosaic layout, start reading aspect ratios
    _settingsSub = settings.updateStream.where((event) => event.key == SettingKeys.webDavLayoutKey).listen((_) {
      if (settings.webDavLayout == 'mosaic') {
        _maybeProbe(_images.value, 'mosaic');
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
    _images.dispose();
    _isScrolling.dispose();
    super.dispose();
  }

  void _onScroll() {
    _isScrolling.value = true;
    _scrollTimer?.cancel();
    _scrollTimer = Timer(const Duration(milliseconds: 400), () {
      _isScrolling.value = false;
    });
  }

  String get _folderName {
    final crumbs = _breadcrumbs();
    return crumbs.isNotEmpty ? crumbs.last.$1 : context.l10n.webdavRoot;
  }

  // folder URLs strictly above `url`, starting at the server root
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

  // path segments relative to the server root (folders only, no server URL)
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

  void _navigateTo(String url) {
    if (url == _currentUrl) return;
    setState(() {
      _currentUrl = url;
      _history = _ancestorsFor(url);
    });
    _fetch();
  }

  void _goUp() {
    if (_history.isEmpty) return;
    final parent = _history.removeLast();
    setState(() => _currentUrl = parent);
    _fetch();
  }

  Future<void> _fetch() async {
    final url = _currentUrl;
    _state.value = _LoadState.loading;
    _folders.value = [];
    _images.value = [];
    // invalidate any in-flight aspect probes
    _probeGeneration++;
    try {
      final client = webDavRegistry.clientForServer(widget.server);
      if (client == null) {
        throw StateError('server not found');
      }
      final resources = await client.list(url);
      if (!mounted || url != _currentUrl) return;

      final folders = resources.where((r) => r.isCollection).toList();
      final images = resources.where((r) => r.isImage || _looksLikeImage(r)).toList();

      final entries = <AvesEntry>[];
      for (var i = 0; i < images.length; i++) {
        entries.add(_entryFromResource(images[i], -1 - i));
      }

      _folders.value = folders;
      _images.value = entries;
      _state.value = _LoadState.ready;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_addressScrollController.hasClients) {
          _addressScrollController.jumpTo(_addressScrollController.position.maxScrollExtent);
        }
      });
      _maybeProbe(entries, settings.webDavLayout);
    } catch (error) {
      if (!mounted || url != _currentUrl) return;
      _error.value = error.toString();
      _state.value = _LoadState.error;
    }
  }

  // Reads aspect ratios for the current folder in the background so the mosaic
  // layout has real proportions. Bounded in count and concurrency; each probe
  // downloads at most the leading bytes of a file.
  void _maybeProbe(List<AvesEntry> images, String layout) {
    if (layout != 'mosaic') return;
    final generation = ++_probeGeneration;
    final pending = <String>[];
    for (final entry in images) {
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

  double _aspectOf(AvesEntry entry) => (_aspects[entry.uri] ?? 1.0).clamp(0.35, 2.6);

  AvesEntry _entryFromResource(WebDavResource resource, int id) {
    return AvesEntry(
      id: id,
      uri: resource.url,
      path: Uri.parse(resource.url).path,
      contentId: null,
      pageId: null,
      sourceMimeType: resource.mimeType ?? _mimeFromName(resource.name),
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

  static bool _looksLikeImage(WebDavResource resource) {
    if (resource.isCollection) return false;
    final name = resource.name.toLowerCase();
    return _imageExtensions.any(name.endsWith);
  }

  static const _imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif', '.avif', '.svg', '.tif', '.tiff'];

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
    return 'application/octet-stream';
  }

  void _openFolder(WebDavResource folder) => _navigateTo(folder.url);

  void _openViewer(int index) {
    final entries = _images.value;
    if (entries.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: WebDavViewerPage.routeName),
        builder: (context) => WebDavViewerPage(entries: entries, initialIndex: index),
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
    final l10n = context.l10n;
    final layout = context.select<Settings, String>((s) => s.webDavLayout);
    final columns = context.select<Settings, int>((s) => s.webDavColumns);
    final showLayoutBar = context.select<Settings, bool>((s) => s.webDavLayoutBar);

    return PopScope(
      canPop: _history.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _goUp();
      },
      child: AvesScaffold(
        appBar: AppBar(
          title: Text(_folderName),
          actions: [
            IconButton(
              tooltip: l10n.webdavLayout,
              onPressed: () => settings.webDavLayoutBar = !settings.webDavLayoutBar,
              icon: const Icon(AIcons.layout),
            ),
            IconButton(
              tooltip: l10n.webdavRefresh,
              onPressed: _fetch,
              icon: const Icon(AIcons.refresh),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(42),
            child: _buildAddressBar(context),
          ),
        ),
        bottomNavigationBar: showLayoutBar ? const WebDavLayoutBar() : null,
        body: ValueListenableBuilder<_LoadState>(
          valueListenable: _state,
          builder: (context, state, child) {
            switch (state) {
              case _LoadState.loading:
                return const Center(child: CircularProgressIndicator());
              case _LoadState.error:
                return ValueListenableBuilder<String>(
                  valueListenable: _error,
                  builder: (context, error, child) => EmptyContent(
                    icon: AIcons.error,
                    text: '${l10n.webdavLoadError}\n$error',
                    bottom: Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: OutlinedButton(onPressed: _fetch, child: Text(l10n.webdavRefresh)),
                    ),
                  ),
                );
              case _LoadState.ready:
                return _buildContent(context, columns: columns, layout: layout);
            }
          },
        ),
      ),
    );
  }

  Widget _buildAddressBar(BuildContext context) {
    final crumbs = _breadcrumbs();
    final atRoot = crumbs.isEmpty;
    return SizedBox(
      height: 42,
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

  Widget _buildContent(BuildContext context, {required int columns, required String layout}) {
    return ValueListenableBuilder<List<AvesEntry>>(
      valueListenable: _images,
      builder: (context, images, child) {
        return ValueListenableBuilder<List<WebDavResource>>(
          valueListenable: _folders,
          builder: (context, folders, child) {
            if (folders.isEmpty && images.isEmpty) {
              return EmptyContent(icon: AIcons.folder, text: context.l10n.webdavEmptyFolder);
            }
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final width = MediaQuery.sizeOf(context).width;
            return CustomScrollView(
              controller: _scrollController,
              slivers: [
                if (folders.isNotEmpty)
                  SliverList.builder(
                    itemCount: folders.length,
                    itemBuilder: (context, index) {
                      final folder = folders[index];
                      return ListTile(
                        leading: const Icon(AIcons.folder),
                        title: Text(folder.name),
                        onTap: () => _openFolder(folder),
                      );
                    },
                  ),
                if (images.isNotEmpty) ...[
                  if (layout == 'mosaic')
                    ..._buildMosaicSlivers(context, images, width, columns, dpr)
                  else if (layout == 'list')
                    SliverList.builder(
                      itemCount: images.length,
                      itemBuilder: (context, index) {
                        final entry = images[index];
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
                            ),
                          ),
                          title: Text(entry.sourceTitle ?? entry.bestTitle ?? ''),
                          onTap: () => _openViewer(index),
                        );
                      },
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.all(4),
                      sliver: SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 4,
                          crossAxisSpacing: 4,
                        ),
                        itemCount: images.length,
                        itemBuilder: (context, index) {
                          final entry = images[index];
                          return _WebDavImageTile(
                            key: ValueKey(entry.uri),
                            entry: entry,
                            extent: width / columns,
                            devicePixelRatio: dpr,
                            cancellableNotifier: _isScrolling,
                            onTap: () => _openViewer(index),
                          );
                        },
                      ),
                    ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
              ],
            );
          },
        );
      },
    );
  }

  static const double _mosaicSpacing = 4;

  List<Widget> _buildMosaicSlivers(BuildContext context, List<AvesEntry> images, double width, int columns, double dpr) {
    const spacing = _mosaicSpacing;
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

    for (var i = 0; i < images.length; i++) {
      final aspect = _aspectOf(images[i]);
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
                      width: _aspectOf(images[indices[k]]) * height,
                      height: height,
                      child: _WebDavImageTile(
                        key: ValueKey(images[indices[k]].uri),
                        entry: images[indices[k]],
                        extent: math.max(_aspectOf(images[indices[k]]) * height, 48),
                        devicePixelRatio: dpr,
                        cancellableNotifier: _isScrolling,
                        isMosaic: true,
                        onTap: () => _openViewer(indices[k]),
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

class _WebDavImageTile extends StatelessWidget {
  final AvesEntry entry;
  final double extent;
  final double devicePixelRatio;
  final ValueNotifier<bool> cancellableNotifier;
  final bool isMosaic;
  final VoidCallback onTap;

  const new({
    super.key,
    required this.entry,
    required this.extent,
    required this.devicePixelRatio,
    required this.cancellableNotifier,
    required this.onTap,
    this.isMosaic = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ThumbnailImage(
        entry: entry,
        extent: extent,
        devicePixelRatio: devicePixelRatio,
        fit: BoxFit.cover,
        isMosaic: isMosaic,
        cancellableNotifier: cancellableNotifier,
        heroTag: null,
      ),
    );
  }
}
