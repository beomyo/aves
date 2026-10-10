import 'package:aves/model/source/webdav/webdav_server.dart';
import 'package:aves_model/aves_model.dart';

mixin WebDavSettings on SettingsAccess {
  List<WebDavServer> get webDavServers => (getStringList(SettingKeys.webDavServersKey) ?? []).map(WebDavServer.fromJsonString).nonNulls.toList();

  set webDavServers(List<WebDavServer> newValue) => set(SettingKeys.webDavServersKey, newValue.map((server) => server.toJsonString()).toList());

  void addWebDavServer(WebDavServer server) => webDavServers = [...webDavServers, server];

  void updateWebDavServer(WebDavServer server) => webDavServers = [for (final v in webDavServers) v.id == server.id ? server : v];

  void removeWebDavServer(String id) => webDavServers = webDavServers.where((v) => v.id != id).toList();

  int get webDavColumns => getInt(SettingKeys.webDavColumnsKey) ?? 3;

  set webDavColumns(int newValue) => set(SettingKeys.webDavColumnsKey, newValue);

  // one of `grid`, `list`, `mosaic`
  String get webDavLayout => getString(SettingKeys.webDavLayoutKey) ?? 'grid';

  set webDavLayout(String newValue) => set(SettingKeys.webDavLayoutKey, newValue);

  bool get webDavLayoutBar => getBool(SettingKeys.webDavLayoutBarKey) ?? true;

  set webDavLayoutBar(bool newValue) => set(SettingKeys.webDavLayoutBarKey, newValue);
}
