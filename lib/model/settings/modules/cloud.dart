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

  // one of `grid`, `list`, `mosaic`
  String get cloudLayout => getString(SettingKeys.cloudLayoutKey) ?? 'grid';

  set cloudLayout(String newValue) => set(SettingKeys.cloudLayoutKey, newValue);

  // one of `all`, `image`, `video`
  String get cloudMediaFilter => getString(SettingKeys.cloudMediaFilterKey) ?? 'all';

  set cloudMediaFilter(String newValue) => set(SettingKeys.cloudMediaFilterKey, newValue);

  bool get cloudShowNames => getBool(SettingKeys.cloudShowNamesKey) ?? false;

  set cloudShowNames(bool newValue) => set(SettingKeys.cloudShowNamesKey, newValue);

  // hide the app bar, address bar and layout bar while scrolling down
  bool get cloudImmersive => getBool(SettingKeys.cloudImmersiveKey) ?? true;

  set cloudImmersive(bool newValue) => set(SettingKeys.cloudImmersiveKey, newValue);

  // one of `nameAsc`, `nameDesc`
  String get cloudSort => getString(SettingKeys.cloudSortKey) ?? 'nameAsc';

  set cloudSort(String newValue) => set(SettingKeys.cloudSortKey, newValue);

  // URLs of folders already opened, rendered dimmed in the browser
  List<String> get cloudVisitedFolders => getStringList(SettingKeys.cloudVisitedFoldersKey) ?? const [];

  set cloudVisitedFolders(List<String> newValue) => set(SettingKeys.cloudVisitedFoldersKey, newValue);

  bool isCloudFolderVisited(String url) => cloudVisitedFolders.contains(url);

  void markCloudFolderVisited(String url) {
    if (url.isEmpty) return;
    final current = cloudVisitedFolders;
    if (current.contains(url)) return;
    final next = [...current, url];
    cloudVisitedFolders = next.length > 4000 ? next.sublist(next.length - 4000) : next;
  }

  // last opened location, to restore the page on the next launch
  String? get cloudLastServerId => getString(SettingKeys.cloudLastServerIdKey) ?? getString(SettingKeys.legacyWebDavLastServerIdKey);

  String? get cloudLastUrl => getString(SettingKeys.cloudLastUrlKey) ?? getString(SettingKeys.legacyWebDavLastUrlKey);

  void setCloudLastLocation(String? serverId, String? url) {
    set(SettingKeys.cloudLastServerIdKey, serverId);
    set(SettingKeys.cloudLastUrlKey, url);
  }
}
