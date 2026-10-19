import 'dart:async';
import 'dart:math' as math;

import 'package:aves/model/source/cloud/cloud_server.dart';
import 'package:aves_model/aves_model.dart';

// per folder viewing progress. A folder holding mostly images tracks how many
// of its thumbnails have been loaded, a folder holding mostly subfolders tracks
// how many of those have been opened. Only direct children are considered,
// one level deep, so the numbers stay cheap to maintain.
class CloudFolderStats {
  int totalImages = 0;
  int totalFolders = 0;
  int visitedFolders = 0;
  // 32 bit hashes of the image URLs whose thumbnails have been loaded
  final Set<int> loaded = {};
}

mixin CloudSettings on SettingsAccess {
  static const int _maxFolderStats = 2000;
  static const int _maxLoadedPerFolder = 6000;

  Map<String, CloudFolderStats>? _folderStatsCache;
  Timer? _folderStatsFlushTimer;
  bool _folderStatsDirty = false;

  // the store can be rewritten directly (settings reset/import), which bypasses
  // the setters above; drop every parsed view so it is rebuilt from the store
  void invalidateCloudCaches() {
    _cloudServersCache = null;
    _folderLayoutsCache = null;
    _visitedLookup = null;
    _videoPositionsCache = null;
    _folderStatsCache = null;
    _folderStatsFlushTimer?.cancel();
    _folderStatsFlushTimer = null;
    _folderStatsDirty = false;
  }

  // parsed views of the stored lists: each getter used to re-parse the whole
  // list on every call, which happens per tile (video duration/progress) and
  // per layout lookup, i.e. many times per frame
  Map<String, String>? _folderLayoutsCache;
  Set<String>? _visitedLookup;
  Map<String, (int, int)>? _videoPositionsCache;

  List<CloudServer>? _cloudServersCache;

  List<CloudServer> get cloudServers {
    final cached = _cloudServersCache;
    if (cached != null) return cached;
    final stored = getStringList(SettingKeys.cloudServersKey);
    if (stored != null) return _cloudServersCache = stored.map(CloudServer.fromJsonString).nonNulls.toList();
    // migrate configurations saved before the WebDAV / SMB merge
    final legacy = getStringList(SettingKeys.legacyCloudServersKey);
    if (legacy != null && legacy.isNotEmpty) {
      final migrated = legacy.map(CloudServer.fromJsonString).nonNulls.toList();
      set(SettingKeys.cloudServersKey, migrated.map((server) => server.toJsonString()).toList());
      return _cloudServersCache = migrated;
    }
    return _cloudServersCache = const [];
  }

  set cloudServers(List<CloudServer> newValue) {
    _cloudServersCache = newValue;
    set(SettingKeys.cloudServersKey, newValue.map((server) => server.toJsonString()).toList());
  }

  void addCloudServer(CloudServer server) => cloudServers = [...cloudServers, server];

  void updateCloudServer(CloudServer server) => cloudServers = [for (final v in cloudServers) v.id == server.id ? server : v];

  void removeCloudServer(String id) => cloudServers = cloudServers.where((v) => v.id != id).toList();

  // fractional so pinch-to-zoom can resize continuously
  double get cloudColumns => getDouble(SettingKeys.cloudColumnsKey) ?? getInt(SettingKeys.cloudColumnsKey)?.toDouble() ?? 3;

  set cloudColumns(double newValue) => set(SettingKeys.cloudColumnsKey, newValue);

  // one of `grid`, `list`, `mosaic`; used when a folder has no saved layout
  // (or when per-folder layouts are disabled)

  // default layout for folders containing images (and mixed content)
  String get cloudImageLayout => getString(SettingKeys.cloudImageLayoutKey) ?? 'mosaic';

  set cloudImageLayout(String newValue) => set(SettingKeys.cloudImageLayoutKey, newValue);

  // default layout for folders that only contain videos
  String get cloudVideoLayout => getString(SettingKeys.cloudVideoLayoutKey) ?? 'list';

  set cloudVideoLayout(String newValue) => set(SettingKeys.cloudVideoLayoutKey, newValue);

  // whether the layout chosen in a folder is remembered for that folder
  bool get cloudLayoutPerFolder => getBool(SettingKeys.cloudLayoutPerFolderKey) ?? false;

  set cloudLayoutPerFolder(bool newValue) => set(SettingKeys.cloudLayoutPerFolderKey, newValue);

  Map<String, String> get _cloudFolderLayouts {
    final cached = _folderLayoutsCache;
    if (cached != null) return cached;
    final stored = getStringList(SettingKeys.cloudFolderLayoutsKey) ?? const [];
    final map = <String, String>{};
    for (final entry in stored) {
      final index = entry.lastIndexOf('\t');
      if (index <= 0) continue;
      map[entry.substring(0, index)] = entry.substring(index + 1);
    }
    return _folderLayoutsCache = map;
  }

  void _setCloudFolderLayouts(Map<String, String> map) {
    _folderLayoutsCache = map;
    set(SettingKeys.cloudFolderLayoutsKey, [for (final e in map.entries) '${e.key}\t${e.value}']);
  }

  // effective layout for a folder
  String cloudLayoutFor(String url, {required bool video}) {
    if (cloudLayoutPerFolder) {
      final saved = _cloudFolderLayouts[url];
      if (saved != null) return saved;
    }
    return video ? cloudVideoLayout : cloudImageLayout;
  }

  // records the layout picked by the user: per folder when that is enabled,
  // otherwise as the default for the current media kind
  void setCloudLayoutFor(String url, String layout, {required bool video}) {
    if (cloudLayoutPerFolder && url.isNotEmpty) {
      _setCloudFolderLayouts({..._cloudFolderLayouts, url: layout});
    } else if (video) {
      cloudVideoLayout = layout;
    } else {
      cloudImageLayout = layout;
    }
  }

  // one of `all`, `image`, `video`
  String get cloudMediaFilter => getString(SettingKeys.cloudMediaFilterKey) ?? 'all';

  set cloudMediaFilter(String newValue) => set(SettingKeys.cloudMediaFilterKey, newValue);

  bool get cloudShowNames => getBool(SettingKeys.cloudShowNamesKey) ?? false;

  set cloudShowNames(bool newValue) => set(SettingKeys.cloudShowNamesKey, newValue);

  bool get cloudShowSizes => getBool(SettingKeys.cloudShowSizesKey) ?? false;

  set cloudShowSizes(bool newValue) => set(SettingKeys.cloudShowSizesKey, newValue);

  // show the thumbnail strip at the bottom of the image viewer
  bool get cloudViewerThumbnails => getBool(SettingKeys.cloudViewerThumbnailsKey) ?? true;

  set cloudViewerThumbnails(bool newValue) => set(SettingKeys.cloudViewerThumbnailsKey, newValue);

  // hide the app bar, address bar and layout bar while scrolling down
  bool get cloudImmersive => getBool(SettingKeys.cloudImmersiveKey) ?? true;

  set cloudImmersive(bool newValue) => set(SettingKeys.cloudImmersiveKey, newValue);

  // one of `nameAsc`, `nameDesc`
  String get cloudSort => getString(SettingKeys.cloudSortKey) ?? 'nameAsc';

  set cloudSort(String newValue) => set(SettingKeys.cloudSortKey, newValue);

  // remote video frames are extracted over the network, which is expensive,
  // so the whole feature can be turned off
  bool get cloudVideoThumbnails => getBool(SettingKeys.cloudVideoThumbnailsKey) ?? true;

  set cloudVideoThumbnails(bool newValue) => set(SettingKeys.cloudVideoThumbnailsKey, newValue);

  // percentage of the video duration used as the thumbnail timestamp: starting
  // slightly after the beginning skips the black frame many videos open with
  double get cloudVideoThumbnailPercent =>
      (getDouble(SettingKeys.cloudVideoThumbnailPercentKey) ?? defaultVideoThumbnailPercent).clamp(minVideoThumbnailPercent, maxVideoThumbnailPercent);

  set cloudVideoThumbnailPercent(double newValue) =>
      set(SettingKeys.cloudVideoThumbnailPercentKey, newValue.clamp(minVideoThumbnailPercent, maxVideoThumbnailPercent));

  static const double defaultVideoThumbnailPercent = 1;
  static const double minVideoThumbnailPercent = .5;
  static const double maxVideoThumbnailPercent = 20;

  // how many remote thumbnails may be extracted at once. Servers that rate
  // limit requests need a low value: parallel requests only multiply latency
  int get cloudThumbnailConcurrency => (getInt(SettingKeys.cloudThumbnailConcurrencyKey) ?? defaultThumbnailConcurrency).clamp(minThumbnailConcurrency, maxThumbnailConcurrency);

  set cloudThumbnailConcurrency(int newValue) => set(SettingKeys.cloudThumbnailConcurrencyKey, newValue.clamp(minThumbnailConcurrency, maxThumbnailConcurrency));

  static const int defaultThumbnailConcurrency = 1;
  static const int minThumbnailConcurrency = 1;
  static const int maxThumbnailConcurrency = 4;

  bool get cloudVideoDurationVisible => getBool(SettingKeys.cloudVideoDurationKey) ?? true;

  set cloudVideoDurationVisible(bool newValue) => set(SettingKeys.cloudVideoDurationKey, newValue);

  bool get cloudVideoPlayIcon => getBool(SettingKeys.cloudVideoPlayIconKey) ?? true;

  set cloudVideoPlayIcon(bool newValue) => set(SettingKeys.cloudVideoPlayIconKey, newValue);

  // URLs of folders already opened and of media already played, rendered dimmed
  List<String> get cloudVisited => getStringList(SettingKeys.cloudVisitedFoldersKey) ?? const [];

  set cloudVisited(List<String> newValue) {
    _visitedLookup = null;
    set(SettingKeys.cloudVisitedFoldersKey, newValue);
  }

  // O(1) lookup for the per-tile "watched"/dimmed check
  Set<String> get _cloudVisitedSet => _visitedLookup ??= cloudVisited.toSet();

  bool isCloudVisited(String url) => _cloudVisitedSet.contains(url);

  void markCloudVisited(String url) {
    if (url.isEmpty) return;
    final current = cloudVisited;
    if (current.contains(url)) return;
    final next = [...current, url];
    cloudVisited = next.length > 4000 ? next.sublist(next.length - 4000) : next;
  }

  // canonical folder key, with a trailing slash, so a collection URL returned
  // by a server with or without one maps to the same progress entry
  static String cloudFolderKey(String url) => url.endsWith('/') ? url : '$url/';

  bool isCloudFolderVisited(String url) {
    final key = cloudFolderKey(url);
    if (isCloudVisited(key)) return true;
    return key == url ? false : isCloudVisited(url);
  }

  // opening a subfolder also advances the progress of its parent, so a folder
  // showing "3/12" does not need to be re-listed to know that
  void markCloudFolderVisited(String url) {
    if (url.isEmpty) return;
    final key = cloudFolderKey(url);
    final wasVisited = isCloudVisited(key);
    markCloudVisited(key);
    if (wasVisited) return;
    final parent = cloudParentUrl(key);
    final stats = _folderStatsMap()[parent];
    if (stats == null) return;
    if (stats.visitedFolders < stats.totalFolders) {
      stats.visitedFolders++;
      // an explicit navigation is rare: persist right away so that leaving the
      // app immediately after opening a folder still records the visit
      flushCloudFolderStats();
    }
  }

  // parent of a file or of a folder. Collection URLs already end with a slash,
  // which must be removed before looking for the previous separator, otherwise
  // a folder would be reported as its own parent.
  static String cloudParentUrl(String url) {
    var value = url;
    while (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    final scheme = value.indexOf('://');
    final last = value.lastIndexOf('/');
    if (last <= scheme + 2) return value;
    return value.substring(0, last + 1);
  }

  static int _hashUrl(String url) {
    var hash = 0x811c9dc5;
    for (final codeUnit in url.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  Map<String, CloudFolderStats> _folderStatsMap() {
    final cached = _folderStatsCache;
    if (cached != null) return cached;
    final map = <String, CloudFolderStats>{};
    for (final row in getStringList(SettingKeys.cloudFolderStatsKey) ?? const <String>[]) {
      final parts = row.split('\t');
      if (parts.length < 5) continue;
      final totalImages = int.tryParse(parts[1]) ?? 0;
      final totalFolders = int.tryParse(parts[2]) ?? 0;
      final visitedFolders = int.tryParse(parts[3]) ?? 0;
      final hashes = parts[4].isEmpty ? const <int>[] : parts[4].split(',').map((v) => int.tryParse(v, radix: 16)).nonNulls;
      // normalize legacy entries that were stored without a trailing slash
      map[cloudFolderKey(parts[0])] = CloudFolderStats()
        ..totalImages = totalImages
        ..totalFolders = totalFolders
        ..visitedFolders = visitedFolders
        ..loaded.addAll(hashes);
    }
    return _folderStatsCache = map;
  }

  // records what the folder listing contains, so a parent row can later show
  // the progress of its subfolders without listing them again
  void recordCloudFolder(String url, {required int imageCount, required int folderCount}) {
    final key = cloudFolderKey(url);
    final map = _folderStatsMap();
    var stats = map[key];
    if (stats == null) {
      if (map.length >= _maxFolderStats) {
        map.remove(map.keys.first);
      }
      stats = map[key] = CloudFolderStats();
    }
    var changed = false;
    if (stats.totalImages != imageCount) {
      stats.totalImages = imageCount;
      changed = true;
    }
    if (stats.totalFolders != folderCount) {
      stats.totalFolders = folderCount;
      changed = true;
    }
    final cappedVisited = math.min(stats.visitedFolders, folderCount);
    if (stats.visitedFolders != cappedVisited) {
      stats.visitedFolders = cappedVisited;
      changed = true;
    }
    if (changed) _scheduleFolderStatsFlush();
  }

  // a thumbnail was decoded and shown: count it once, keyed by its URL hash so
  // the stored set stays compact even for folders with thousands of images
  void markCloudImageLoaded(String imageUrl) {
    if (imageUrl.isEmpty) return;
    final stats = _folderStatsMap()[cloudParentUrl(imageUrl)];
    if (stats == null || stats.loaded.length >= _maxLoadedPerFolder) return;
    if (stats.loaded.add(_hashUrl(imageUrl))) {
      _scheduleFolderStatsFlush();
    }
  }

  // the picture no longer exists on the server: stop counting it as loaded
  void forgetCloudImage(String imageUrl) {
    final stats = _folderStatsMap()[cloudParentUrl(imageUrl)];
    if (stats == null) return;
    if (stats.loaded.remove(_hashUrl(imageUrl))) {
      _scheduleFolderStatsFlush();
    }
  }

  // the folder no longer exists on the server: drop its progress and its
  // "already opened" mark
  void forgetCloudFolder(String url) {
    final key = cloudFolderKey(url);
    final map = _folderStatsMap();
    if (map.remove(key) != null) {
      _scheduleFolderStatsFlush();
    }
    final current = cloudVisited;
    if (current.contains(key) || current.contains(key.substring(0, key.length - 1))) {
      cloudVisited = current.where((v) => v != key && v != key.substring(0, key.length - 1)).toList();
    }
  }

  int get cloudProgressFolderCount => _folderStatsMap().length;

  int get cloudProgressImageCount => _folderStatsMap().values.fold(0, (sum, stats) => sum + math.min(stats.loaded.length, stats.totalImages));

  // wipes every folder's viewing progress and the "already opened / already
  // watched" marks. Playback positions and durations are kept.
  void clearCloudFolderProgress() {
    _folderStatsCache = null;
    _folderStatsFlushTimer?.cancel();
    _folderStatsFlushTimer = null;
    _folderStatsDirty = false;
    _visitedLookup = null;
    set(SettingKeys.cloudFolderStatsKey, null);
    set(SettingKeys.cloudVisitedFoldersKey, null);
  }

  // "loaded/total" for an image folder, "opened/total" for a folder of folders.
  // Folders that were never listed have no stats yet and show nothing.
  String? cloudFolderProgressText(String url) {
    final stats = _folderStatsMap()[cloudFolderKey(url)];
    if (stats == null) return null;
    // mostly images (or images only): report thumbnail progress
    if (stats.totalImages > 0 && stats.totalImages >= stats.totalFolders) {
      final loaded = math.min(stats.loaded.length, stats.totalImages);
      return '$loaded/${stats.totalImages}';
    }
    if (stats.totalFolders > 0) {
      final visited = math.min(stats.visitedFolders, stats.totalFolders);
      return '$visited/${stats.totalFolders}';
    }
    return null;
  }

  void _scheduleFolderStatsFlush() {
    _folderStatsDirty = true;
    // thumbnails arrive in bursts while scrolling: persist once they settle,
    // without rewriting the whole list on every few tiles
    _folderStatsFlushTimer ??= Timer(const Duration(seconds: 5), flushCloudFolderStats);
  }

  void flushCloudFolderStats() {
    _folderStatsFlushTimer?.cancel();
    _folderStatsFlushTimer = null;
    if (!_folderStatsDirty) return;
    _folderStatsDirty = false;
    final map = _folderStatsMap();
    final rows = [
      for (final entry in map.entries) '${entry.key}\t${entry.value.totalImages}\t${entry.value.totalFolders}\t${entry.value.visitedFolders}\t${entry.value.loaded.map((h) => h.toRadixString(16).padLeft(8, '0')).join(',')}',
    ];
    // write silently: this runs every few seconds while thumbnails load, and a
    // notification would rebuild every settings listener for no visible change
    store.setStringList(SettingKeys.cloudFolderStatsKey, rows);
  }

  Map<String, Object?> exportCloudFolderStats() => {
    'version': 1,
    'folders': <String, Object?>{
      for (final entry in _folderStatsMap().entries)
        entry.key: <String, Object?>{
          'images': entry.value.totalImages,
          'folders': entry.value.totalFolders,
          'visited': entry.value.visitedFolders,
          'loaded': [for (final hash in entry.value.loaded) hash.toRadixString(16).padLeft(8, '0')],
        },
    },
  };

  // merges an exported backup into the current progress (never lowers a count)
  int importCloudFolderStats(Object? json) {
    if (json is! Map) return 0;
    final folders = json['folders'];
    if (folders is! Map) return 0;
    final map = _folderStatsMap();
    var count = 0;
    for (final entry in folders.entries) {
      final url = entry.key;
      final value = entry.value;
      if (url is! String || url.isEmpty || value is! Map) continue;
      final stats = map.putIfAbsent(cloudFolderKey(url), CloudFolderStats.new);
      stats.totalImages = math.max(stats.totalImages, (value['images'] as num?)?.toInt() ?? 0);
      stats.totalFolders = math.max(stats.totalFolders, (value['folders'] as num?)?.toInt() ?? 0);
      stats.visitedFolders = math.max(stats.visitedFolders, (value['visited'] as num?)?.toInt() ?? 0);
      final loaded = value['loaded'];
      if (loaded is List) {
        for (final item in loaded) {
          final hash = item is int ? item : (item is String ? int.tryParse(item, radix: 16) : null);
          if (hash != null && stats.loaded.length < _maxLoadedPerFolder) {
            stats.loaded.add(hash);
          }
        }
      }
      count++;
    }
    if (count > 0) {
      _folderStatsDirty = true;
      flushCloudFolderStats();
    }
    return count;
  }

  // last playback position and duration of each video (milliseconds), so it
  // can both resume and show a progress bar on the tile
  Map<String, (int, int)> get _cloudVideoPositions {
    final cached = _videoPositionsCache;
    if (cached != null) return cached;
    final stored = getStringList(SettingKeys.cloudVideoPositionsKey) ?? const [];
    final map = <String, (int, int)>{};
    for (final entry in stored) {
      final parts = entry.split('\t');
      if (parts.length < 3) continue;
      final position = int.tryParse(parts[parts.length - 2]);
      final duration = int.tryParse(parts[parts.length - 1]);
      if (position == null || duration == null) continue;
      map[parts.sublist(0, parts.length - 2).join('\t')] = (position, duration);
    }
    return _videoPositionsCache = map;
  }

  int? cloudVideoPosition(String url) => _cloudVideoPositions[url]?.$1;

  int? cloudVideoDuration(String url) => _cloudVideoPositions[url]?.$2;

  void setCloudVideoProgress(String url, int positionMillis, int durationMillis) {
    if (url.isEmpty) return;
    final map = _cloudVideoPositions;
    if (positionMillis <= 0) {
      if (map.remove(url) == null) return;
    } else {
      final current = map[url];
      if (current != null && current.$1 == positionMillis && current.$2 == durationMillis) return;
      map[url] = (positionMillis, durationMillis);
    }
    _writeCloudVideoPositions(map);
  }

  // records the duration probed while extracting a thumbnail, keeping any
  // playback position already stored for that video
  void setCloudVideoDuration(String url, int durationMillis) {
    if (url.isEmpty || durationMillis <= 0) return;
    final map = _cloudVideoPositions;
    final current = map[url];
    if (current != null && current.$2 == durationMillis) return;
    map[url] = (current?.$1 ?? 0, durationMillis);
    _writeCloudVideoPositions(map);
  }

  void _writeCloudVideoPositions(Map<String, (int, int)> map) {
    final entries = map.entries.toList();
    // keep the most recently watched entries, not the oldest
    final capped = entries.length > 4000 ? entries.sublist(entries.length - 4000) : entries;
    _videoPositionsCache = Map.fromEntries(capped);
    set(SettingKeys.cloudVideoPositionsKey, [for (final e in capped) '${e.key}\t${e.value.$1}\t${e.value.$2}']);
  }

  // last opened location, to restore the page on the next launch
  String? get cloudLastServerId => getString(SettingKeys.cloudLastServerIdKey) ?? getString(SettingKeys.legacyWebDavLastServerIdKey);

  String? get cloudLastUrl => getString(SettingKeys.cloudLastUrlKey) ?? getString(SettingKeys.legacyWebDavLastUrlKey);

  void setCloudLastLocation(String? serverId, String? url) {
    set(SettingKeys.cloudLastServerIdKey, serverId);
    set(SettingKeys.cloudLastUrlKey, url);
  }
}
