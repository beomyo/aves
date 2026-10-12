import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/cloud/cloud_server.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/cloud/cloud_browser_page.dart';
import 'package:aves/widgets/cloud/cloud_server_edit_page.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/empty.dart';
import 'package:aves/widgets/navigation/drawer/app_drawer.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

// Management page for every remote service (WebDAV / SMB).
class CloudServerListPage extends StatelessWidget {
  static const routeName = '/cloud/servers';

  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final servers = context.watch<Settings>().cloudServers;
    return AvesScaffold(
      appBar: AppBar(
        title: Text(context.l10n.cloudServersPageTitle),
      ),
      drawer: const AppDrawer(),
      floatingActionButton: FloatingActionButton(
        tooltip: context.l10n.cloudAddService,
        onPressed: () => _addServer(context),
        child: const Icon(AIcons.add),
      ),
      body: servers.isEmpty
          ? EmptyContent(
              icon: AIcons.cloud,
              text: context.l10n.cloudEmptyServers,
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

  // the "+" button asks which kind of service to add
  Future<void> _addServer(BuildContext context) async {
    final type = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(context.l10n.cloudAddService, style: Theme.of(context).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(AIcons.cloud),
              title: Text(context.l10n.cloudTypeWebDav),
              subtitle: Text(context.l10n.cloudTypeWebDavHint),
              onTap: () => Navigator.pop(context, CloudServerType.webDav),
            ),
            ListTile(
              leading: const Icon(Icons.storage_rounded),
              title: Text(context.l10n.cloudTypeSmb),
              subtitle: Text(context.l10n.cloudTypeSmbHint),
              onTap: () => Navigator.pop(context, CloudServerType.smb),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (type == null || !context.mounted) return;
    await _editServer(context, null, type: type);
  }

  void _browse(BuildContext context, CloudServer server) {
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: CloudBrowserPage.routeName),
        builder: (context) => CloudBrowserPage(server: server),
      ),
    );
  }

  Future<void> _editServer(BuildContext context, CloudServer? server, {String type = CloudServerType.webDav}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: CloudServerEditPage.routeName),
        builder: (context) => CloudServerEditPage(server: server, initialType: type),
      ),
    );
  }

  Future<void> _removeServer(BuildContext context, CloudServer server) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.cloudRemoveServer),
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
      settings.removeCloudServer(server.id);
    }
  }
}

class _ServerTile extends StatelessWidget {
  final CloudServer server;
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
      leading: Icon(server.isSmb ? Icons.storage_rounded : AIcons.cloud),
      title: Text(server.displayName),
      subtitle: Row(
        children: [
          Text(
            server.isSmb ? context.l10n.cloudTypeSmb : context.l10n.cloudTypeWebDav,
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(server.url, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
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
