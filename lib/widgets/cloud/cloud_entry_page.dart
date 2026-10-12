import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/cloud/cloud_server.dart';
import 'package:aves/widgets/cloud/cloud_browser_page.dart';
import 'package:aves/widgets/cloud/cloud_server_list_page.dart';
import 'package:material_ui/material_ui.dart';

// Entry point of the cloud features: restores the last browsed folder,
// falling back to the service list when there is nothing to restore.
class CloudEntryPage extends StatelessWidget {
  static const routeName = '/cloud';

  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final location = _lastLocation();
    if (location != null) {
      return CloudBrowserPage(server: location.$1, initialUrl: location.$2);
    }
    return const CloudServerListPage();
  }

  static (CloudServer, String)? _lastLocation() {
    final serverId = settings.cloudLastServerId;
    final url = settings.cloudLastUrl;
    if (serverId == null || url == null) return null;
    CloudServer? server;
    for (final candidate in settings.cloudServers) {
      if (candidate.id == serverId) {
        server = candidate;
        break;
      }
    }
    if (server == null) return null;
    return (server, url);
  }
}
