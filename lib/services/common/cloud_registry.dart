import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/cloud/cloud_server.dart';
import 'package:aves/services/media/cloud_client.dart';
import 'package:aves/services/media/smb_client.dart';
import 'package:aves/services/media/smb_stream_server.dart';
import 'package:aves/services/media/webdav_client.dart';

// resolves the cloud service config owning a given URL and caches clients.
// Handles both WebDAV (`http(s)://`) and SMB (`smb://`) URLs.
class CloudRegistry {
  final Map<String, (CloudServer, CloudClient)> _clients = {};

  static String _normalizeBase(String url) => url.endsWith('/') ? url : '$url/';

  CloudServer? serverForUrl(String url) {
    CloudServer? best;
    for (final server in settings.cloudServers) {
      final base = _normalizeBase(server.url);
      if (url == server.url || url.startsWith(base)) {
        if (best == null || base.length > _normalizeBase(best.url).length) {
          best = server;
        }
      }
    }
    return best;
  }

  CloudClient? clientForUrl(String url) => clientForServer(serverForUrl(url));

  static String smbPathOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '/';
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? '/' : '/${segments.join('/')}';
  }

  // URL handed to consumers we do not control (e.g. the video backend streaming
  // the file itself): WebDAV keeps the credentials embedded in the URL, while
  // SMB is served through a loopback HTTP bridge.
  Future<String> playbackUrl(String url) async {
    final server = serverForUrl(url);
    if (server == null) return url;
    if (server.isSmb) {
      final bridged = await smbStreamServer.urlFor(server.id, smbPathOf(url));
      return bridged ?? url;
    }
    if (server.username.isEmpty) return url;
    final uri = Uri.parse(url);
    if (uri.userInfo.isNotEmpty) return url;
    return uri.replace(userInfo: '${Uri.encodeComponent(server.username)}:${Uri.encodeComponent(server.password)}').toString();
  }

  CloudClient? clientForServer(CloudServer? server) {
    if (server == null) return null;
    final cached = _clients[server.id];
    if (cached != null) {
      final (cachedServer, client) = cached;
      // reuse only if the connection-relevant config is unchanged
      if (cachedServer == server) {
        return client;
      }
      client.close();
    }
    final client = server.isSmb ? SmbClient(server) : WebDavClient(server);
    _clients[server.id] = (server, client);
    return client;
  }

  void clear() {
    for (final (_, client) in _clients.values) {
      client.close();
    }
    _clients.clear();
  }
}

final cloudRegistry = CloudRegistry();
