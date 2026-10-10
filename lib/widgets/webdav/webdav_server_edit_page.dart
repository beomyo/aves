import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/webdav/webdav_server.dart';
import 'package:aves/services/media/webdav_client.dart';
import 'package:aves/widgets/common/action_mixins/feedback.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:material_ui/material_ui.dart';

class WebDavServerEditPage extends StatefulWidget {
  static const routeName = '/webdav/server';

  final WebDavServer? server;

  const new({super.key, this.server});

  @override
  State<WebDavServerEditPage> createState() => _WebDavServerEditPageState();
}

class _WebDavServerEditPageState extends State<WebDavServerEditPage> with FeedbackMixin {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late bool _ignoreTlsErrors;

  bool get _isEditing => widget.server != null;

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    _nameController = TextEditingController(text: server?.name ?? '');
    _urlController = TextEditingController(text: server?.url ?? '');
    _usernameController = TextEditingController(text: server?.username ?? '');
    _passwordController = TextEditingController(text: server?.password ?? '');
    _ignoreTlsErrors = server?.ignoreTlsErrors ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  WebDavServer _buildServer() {
    final server = widget.server;
    return WebDavServer(
      id: server?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _nameController.text.trim(),
      url: _urlController.text.trim(),
      username: _usernameController.text,
      password: _passwordController.text,
      ignoreTlsErrors: _ignoreTlsErrors,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AvesScaffold(
      appBar: AppBar(
        title: Text(_isEditing ? l10n.webdavEditServer : l10n.webdavAddServer),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(l10n.webdavActionSave),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.webdavServerName,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.webdavServerUrl,
                hintText: 'https://host:port/dav/',
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return l10n.webdavServerUrl;
                final uri = Uri.tryParse(text);
                if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
                  return l10n.webdavServerUrl;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _usernameController,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.webdavUsername,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: true,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.webdavPassword,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _ignoreTlsErrors,
              title: Text(l10n.webdavIgnoreTlsErrors),
              onChanged: (value) => setState(() => _ignoreTlsErrors = value),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _testConnection,
              icon: const Icon(Icons.wifi_tethering),
              label: Text(l10n.webdavTestConnection),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _testConnection() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final server = _buildServer();
    final client = WebDavClient(server);
    try {
      await client.testConnection();
      if (!mounted) return;
      showFeedbackWithMessenger(context, messenger, FeedbackType.info, l10n.webdavTestConnectionSuccess);
    } catch (error) {
      if (!mounted) return;
      showFeedbackWithMessenger(context, messenger, FeedbackType.warn, '${l10n.webdavTestConnectionFailure} ${error is WebDavException ? error.message : error}');
    } finally {
      client.close();
    }
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final server = _buildServer();
    if (_isEditing) {
      settings.updateWebDavServer(server);
    } else {
      settings.addWebDavServer(server);
    }
    Navigator.pop(context);
  }
}
