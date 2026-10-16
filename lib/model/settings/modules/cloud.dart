import 'package:aves/model/source/cloud/cloud_server.dart';
import 'package:aves_model/aves_model.dart';

mixin CloudSettings on SettingsAccess {
  List<CloudServer> get cloudServers {
    final stored = getStringList(SettingKeys.cloudServersKey);
    if (stored != null) return stored.map(CloudServer.fromJsonString).nonNulls.toList();
    // migrate configurations saved before the WebDAV / SMB merge
    final legacy = getStringList(SettingKeys.legacyCloudServersKey);
    if (legacy != null && legacy.isNotEmpty) {
      final migrated = legacy.map(CloudServer.fromJsonString).nonNulls.toList();
      set(SettingKeys.cloudServersKey, migrated.map((server) => server.toJsonString()).toList());
      return migrated;
    }
    return const [];
  }

  set cloudServers(List<CloudServer> newValue) => set(SettingKeys.cloudServersKey, newValue.map((server) => server.toJsonString()).toList());

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
    final stored = getStringList(SettingKeys.cloudFolderLayoutsKey) ?? const [];
    final map = <String, String>{};
    for (final entry in stored) {
      final index = entry.lastIndexOf('\t');
      if (index <= 0) continue;
      map[entry.substring(0, index)] = entry.substring(index + 1);
    }
    return map;
  }

  void _setCloudFolderLayouts(Map<String, String> map) => set(SettingKeys.cloudFolderLayoutsKey, [for (final e in map.entries) '${e.key}\t${e.value}']);

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

  bool get cloudVideoDurationVisible => getBool(SettingKeys.cloudVideoDurationKey) ?? true;

  set cloudVideoDurationVisible(bool newValue) => set(SettingKeys.cloudVideoDurationKey, newValue);

  bool get cloudVideoPlayIcon => getBool(SettingKeys.cloudVideoPlayIconKey) ?? true;

  set cloudVideoPlayIcon(bool newValue) => set(SettingKeys.cloudVideoPlayIconKey, newValue);

  // URLs of folders already opened and of media already played, rendered dimmed
  List<String> get cloudVisited => getStringList(SettingKeys.cloudVisitedFoldersKey) ?? const [];

  set cloudVisited(List<String> newValue) => set(SettingKeys.cloudVisitedFoldersKey, newValue);

  bool isCloudVisited(String url) => cloudVisited.contains(url);

  void markCloudVisited(String url) {
    if (url.isEmpty) return;
    final current = cloudVisited;
    if (current.contains(url)) return;
    final next = [...current, url];
    cloudVisited = next.length > 4000 ? next.sublist(next.length - 4000) : next;
  }

  // last playback position and duration of each video (milliseconds), so it
  // can both resume and show a progress bar on the tile
  Map<String, (int, int)> get _cloudVideoPositions {
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
    return map;
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
