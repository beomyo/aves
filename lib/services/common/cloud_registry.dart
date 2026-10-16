import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/cloud/cloud_server.dart';
import 'package:aves/services/media/cloud_client.dart';
import 'package:aves/services/media/smb_client.dart';
import 'package:aves/services/media/smb_stream_server.dart';
import 'package:aves/services/media/webdav_client.dart';

// a URL an external consumer can open for a cloud resource, together with the
// HTTP headers it must send along (WebDAV Basic auth); SMB goes through the
// loopback HTTP bridge and needs no header
class CloudPlaybackSource {
  final String url;
  final Map<String, String> headers;

  const new(this.url, {this.headers = const {}});
}

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

  // like `playbackUrl`, but for consumers that accept HTTP headers instead of
  // credentials embedded in the URL (the native thumbnail extractor): WebDAV
  // returns the URL unchanged plus the Basic auth header, SMB returns the
  // loopback bridge URL with no header.
  Future<CloudPlaybackSource> playbackSource(String url) async {
    final server = serverForUrl(url);
    if (server == null) return CloudPlaybackSource(url);
    if (server.isSmb) {
      final bridged = await smbStreamServer.urlFor(server.id, smbPathOf(url));
      return CloudPlaybackSource(bridged ?? url);
    }
    final client = clientForServer(server);
    return CloudPlaybackSource(url, headers: client?.requestHeaders ?? const {});
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
