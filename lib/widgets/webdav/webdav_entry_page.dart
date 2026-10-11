import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/webdav/webdav_server.dart';
import 'package:aves/widgets/webdav/webdav_browser_page.dart';
import 'package:aves/widgets/webdav/webdav_server_list_page.dart';
import 'package:material_ui/material_ui.dart';

// Entry point of the WebDAV feature: restores the last browsed folder,
// falling back to the server list when there is nothing to restore.
class WebDavEntryPage extends StatelessWidget {
  static const routeName = '/webdav';

  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final location = _lastLocation();
    if (location != null) {
      return WebDavBrowserPage(server: location.$1, initialUrl: location.$2);
    }
    return const WebDavServerListPage();
  }

  static (WebDavServer, String)? _lastLocation() {
    final serverId = settings.webDavLastServerId;
    final url = settings.webDavLastUrl;
    if (serverId == null || url == null) return null;
    WebDavServer? server;
    for (final candidate in settings.webDavServers) {
      if (candidate.id == serverId) {
        server = candidate;
        break;
      }
    }
    if (server == null) return null;
    return (server, url);
  }
}
