import 'package:aves/model/source/webdav/webdav_server.dart';
import 'package:aves_model/aves_model.dart';

mixin WebDavSettings on SettingsAccess {
  List<WebDavServer> get webDavServers => (getStringList(SettingKeys.webDavServersKey) ?? []).map(WebDavServer.fromJsonString).nonNulls.toList();

  set webDavServers(List<WebDavServer> newValue) => set(SettingKeys.webDavServersKey, newValue.map((server) => server.toJsonString()).toList());

  void addWebDavServer(WebDavServer server) => webDavServers = [...webDavServers, server];

  void updateWebDavServer(WebDavServer server) => webDavServers = [for (final v in webDavServers) v.id == server.id ? server : v];

  void removeWebDavServer(String id) => webDavServers = webDavServers.where((v) => v.id != id).toList();

  // fractional so pinch-to-zoom can resize continuously
  double get webDavColumns => getDouble(SettingKeys.webDavColumnsKey) ?? getInt(SettingKeys.webDavColumnsKey)?.toDouble() ?? 3;

  set webDavColumns(double newValue) => set(SettingKeys.webDavColumnsKey, newValue);

  // one of `grid`, `list`, `mosaic`
  String get webDavLayout => getString(SettingKeys.webDavLayoutKey) ?? 'grid';

  set webDavLayout(String newValue) => set(SettingKeys.webDavLayoutKey, newValue);

  bool get webDavLayoutBar => getBool(SettingKeys.webDavLayoutBarKey) ?? true;

  set webDavLayoutBar(bool newValue) => set(SettingKeys.webDavLayoutBarKey, newValue);

  // hide the app bar, address bar and layout bar while scrolling down
  bool get webDavImmersive => getBool(SettingKeys.webDavImmersiveKey) ?? true;

  set webDavImmersive(bool newValue) => set(SettingKeys.webDavImmersiveKey, newValue);

  // last opened location, to restore the page on the next launch
  String? get webDavLastServerId => getString(SettingKeys.webDavLastServerIdKey);

  String? get webDavLastUrl => getString(SettingKeys.webDavLastUrlKey);

  void setWebDavLastLocation(String? serverId, String? url) {
    set(SettingKeys.webDavLastServerIdKey, serverId);
    set(SettingKeys.webDavLastUrlKey, url);
  }
}
