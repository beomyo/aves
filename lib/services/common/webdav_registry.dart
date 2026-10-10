import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/webdav/webdav_server.dart';
import 'package:aves/services/media/webdav_client.dart';

// resolves the WebDAV server config owning a given URL and caches clients.
class WebDavRegistry {
  final Map<String, (WebDavServer, WebDavClient)> _clients = {};

  static String _normalizeBase(String url) => url.endsWith('/') ? url : '$url/';

  WebDavServer? serverForUrl(String url) {
    WebDavServer? best;
    for (final server in settings.webDavServers) {
      final base = _normalizeBase(server.url);
      if (url.startsWith(base) || url == server.url) {
        if (best == null || base.length > _normalizeBase(best.url).length) {
          best = server;
        }
      }
    }
    return best;
  }

  WebDavClient? clientForUrl(String url) => clientForServer(serverForUrl(url));

  WebDavClient? clientForServer(WebDavServer? server) {
    if (server == null) return null;
    final cached = _clients[server.id];
    if (cached != null) {
      final (cachedServer, client) = cached;
      // reuse only if the connection-relevant config is unchanged
      if (cachedServer.url == server.url && cachedServer.username == server.username && cachedServer.password == server.password && cachedServer.ignoreTlsErrors == server.ignoreTlsErrors) {
        return client;
      }
      client.close();
    }
    final client = WebDavClient(server);
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

final webDavRegistry = WebDavRegistry();
