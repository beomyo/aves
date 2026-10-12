import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/cloud/cloud_server.dart';
import 'package:aves/services/common/cloud_registry.dart';
import 'package:aves/services/media/cloud_client.dart';
import 'package:aves/widgets/common/action_mixins/feedback.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:material_ui/material_ui.dart';

class CloudServerEditPage extends StatefulWidget {
  static const routeName = '/cloud/server';

  final CloudServer? server;
  final String initialType;

  const new({super.key, this.server, this.initialType = CloudServerType.webDav});

  @override
  State<CloudServerEditPage> createState() => _CloudServerEditPageState();
}

class _CloudServerEditPageState extends State<CloudServerEditPage> with FeedbackMixin {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _domainController;
  late bool _ignoreTlsErrors;
  late String _type;

  bool get _isEditing => widget.server != null;

  bool get _isSmb => _type == CloudServerType.smb;

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    _type = server?.type ?? widget.initialType;
    _nameController = TextEditingController(text: server?.name ?? '');
    _urlController = TextEditingController(text: server?.url ?? '');
    _usernameController = TextEditingController(text: server?.username ?? '');
    _passwordController = TextEditingController(text: server?.password ?? '');
    _domainController = TextEditingController(text: server?.domain ?? '');
    _ignoreTlsErrors = server?.ignoreTlsErrors ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _domainController.dispose();
    super.dispose();
  }

  // `smb_connect` dials the default SMB port, so the port is dropped and the
  // address is normalized to `smb://host[/share][/]`
  static String _normalizeSmbUrl(String input) {
    var text = input.trim();
    if (text.isEmpty) return text;
    if (!text.contains('://')) text = 'smb://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return text;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return Uri(scheme: 'smb', host: uri.host, path: segments.isEmpty ? '/' : '/${segments.join('/')}/').toString();
  }

  CloudServer _buildServer() {
    final server = widget.server;
    final url = _isSmb ? _normalizeSmbUrl(_urlController.text) : _urlController.text.trim();
    return CloudServer(
      id: server?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _nameController.text.trim(),
      type: _type,
      url: url,
      username: _usernameController.text,
      password: _passwordController.text,
      domain: _isSmb ? _domainController.text.trim() : '',
      ignoreTlsErrors: _isSmb ? false : _ignoreTlsErrors,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final title = _isEditing ? l10n.webdavEditServer : (_isSmb ? l10n.cloudAddSmb : l10n.cloudAddWebDav);
    return AvesScaffold(
      appBar: AppBar(
        title: Text(title),
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
                labelText: _isSmb ? l10n.cloudSmbAddress : l10n.cloudServerAddress,
                hintText: _isSmb ? '192.168.1.10/share' : 'https://host:port/dav/',
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return l10n.cloudServerAddress;
                if (_isSmb) {
                  final normalized = _normalizeSmbUrl(text);
                  final uri = Uri.tryParse(normalized);
                  if (uri == null || uri.host.isEmpty) return l10n.cloudSmbAddress;
                  return null;
                }
                final uri = Uri.tryParse(text);
                if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
                  return l10n.cloudServerAddress;
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
            if (_isSmb) ...[
              const SizedBox(height: 16),
              TextFormField(
                controller: _domainController,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: l10n.cloudSmbDomain,
                  border: const OutlineInputBorder(),
                ),
              ),
            ] else ...[
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _ignoreTlsErrors,
                title: Text(l10n.webdavIgnoreTlsErrors),
                onChanged: (value) => setState(() => _ignoreTlsErrors = value),
              ),
            ],
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
    final client = cloudRegistry.clientForServer(server);
    if (client == null) return;
    try {
      await client.testConnection();
      if (!mounted) return;
      showFeedbackWithMessenger(context, messenger, FeedbackType.info, l10n.webdavTestConnectionSuccess);
    } catch (error) {
      if (!mounted) return;
      final message = error is CloudException ? error.message : error;
      showFeedbackWithMessenger(context, messenger, FeedbackType.warn, '${l10n.webdavTestConnectionFailure} $message');
    }
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final server = _buildServer();
    if (_isEditing) {
      settings.updateCloudServer(server);
    } else {
      settings.addCloudServer(server);
    }
    Navigator.pop(context);
  }
}
