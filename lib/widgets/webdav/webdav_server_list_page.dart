import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/webdav/webdav_server.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/empty.dart';
import 'package:aves/widgets/navigation/drawer/app_drawer.dart';
import 'package:aves/widgets/webdav/webdav_browser_page.dart';
import 'package:aves/widgets/webdav/webdav_server_edit_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

class WebDavServerListPage extends StatelessWidget {
  static const routeName = '/webdav';

  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final servers = context.watch<Settings>().webDavServers;
    return AvesScaffold(
      appBar: AppBar(
        title: Text(context.l10n.webdavServersPageTitle),
      ),
      drawer: const AppDrawer(),
      floatingActionButton: FloatingActionButton(
        tooltip: context.l10n.webdavAddServer,
        onPressed: () => _editServer(context, null),
        child: const Icon(AIcons.add),
      ),
      body: servers.isEmpty
          ? EmptyContent(
              icon: AIcons.cloud,
              text: context.l10n.webdavEmptyServers,
            )
          : ListView.builder(
              padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 80),
              itemCount: servers.length,
              itemBuilder: (context, index) {
                final server = servers[index];
                return _ServerTile(
                  server: server,
                  onTap: () => _browse(context, server),
                  onEdit: () => _editServer(context, server),
                  onRemove: () => _removeServer(context, server),
                );
              },
            ),
    );
  }

  void _browse(BuildContext context, WebDavServer server) {
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: WebDavBrowserPage.routeName),
        builder: (context) => WebDavBrowserPage(server: server),
      ),
    );
  }

  Future<void> _editServer(BuildContext context, WebDavServer? server) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: WebDavServerEditPage.routeName),
        builder: (context) => WebDavServerEditPage(server: server),
      ),
    );
  }

  Future<void> _removeServer(BuildContext context, WebDavServer server) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.webdavRemoveServer),
        content: Text(server.displayName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.webdavActionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.webdavActionRemove),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      settings.removeWebDavServer(server.id);
    }
  }
}

class _ServerTile extends StatelessWidget {
  final WebDavServer server;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  const new({
    required this.server,
    required this.onTap,
    required this.onEdit,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(AIcons.cloud),
      title: Text(server.displayName),
      subtitle: Text(server.url, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onTap,
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          switch (value) {
            case 'edit':
              onEdit();
            case 'remove':
              onRemove();
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(value: 'edit', child: Text(context.l10n.webdavActionEdit)),
          PopupMenuItem(value: 'remove', child: Text(context.l10n.webdavActionRemove)),
        ],
      ),
    );
  }
}
