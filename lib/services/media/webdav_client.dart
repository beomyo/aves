import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aves/model/source/webdav/webdav_resource.dart';
import 'package:aves/model/source/webdav/webdav_server.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:xml/xml.dart';

class WebDavException implements Exception {
  final String message;
  final int? statusCode;

  const new(this.message, {this.statusCode});

  bool get isAuthError => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'WebDavException($statusCode): $message';
}

class WebDavClient {
  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<D:propfind xmlns:D="DAV:">'
      '<D:prop>'
      '<D:resourcetype/>'
      '<D:getcontenttype/>'
      '<D:getcontentlength/>'
      '<D:getlastmodified/>'
      '</D:prop>'
      '</D:propfind>';

  static const _listTimeout = Duration(seconds: 90);
  static const _getTimeout = Duration(seconds: 120);

  final WebDavServer server;

  // normalized base URL, always ending with a separator
  late final Uri baseUri;
  late final http.Client _client;

  new(this.server) {
    var url = server.url.trim();
    if (!url.endsWith('/')) {
      url = '$url/';
    }
    baseUri = Uri.parse(url);
    if (server.ignoreTlsErrors) {
      final httpClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..badCertificateCallback = ((cert, host, port) => true);
      _client = IOClient(httpClient);
    } else {
      _client = http.Client();
    }
  }

  void close() => _client.close();

  Map<String, String> get _authHeaders {
    if (server.username.isEmpty && server.password.isEmpty) return const {};
    final token = base64Encode(utf8.encode('${server.username}:${server.password}'));
    return {'Authorization': 'Basic $token'};
  }

  Uri resolve(String url) {
    final uri = Uri.parse(url);
    if (uri.hasScheme) return uri;
    return baseUri.resolveUri(uri);
  }

  Future<void> testConnection() async {
    await list(baseUri.toString());
  }

  Future<List<WebDavResource>> list(String url) async {
    final requestUrl = resolve(url);
    final request = http.Request('PROPFIND', requestUrl)
      ..headers.addAll({
        ..._authHeaders,
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      })
      ..bodyBytes = utf8.encode(_propfindBody);

    final body = await _send(request, timeout: _listTimeout);
    return _parseMultiStatus(body, requestUrl.path, baseUri);
  }

  Future<Uint8List> getBytes(String url) async {
    final requestUrl = resolve(url);
    try {
      final response = await _client.get(requestUrl, headers: _authHeaders).timeout(_getTimeout);
      if (response.statusCode >= 400) {
        throw WebDavException('failed to download file', statusCode: response.statusCode);
      }
      return response.bodyBytes;
    } on SocketException catch (e) {
      throw WebDavException('connection failed: ${e.message}');
    } on HandshakeException catch (e) {
      throw WebDavException('TLS handshake failed: ${e.message}');
    } on Exception catch (e) {
      throw WebDavException('download failed: $e');
    }
  }

  // fetches only the leading bytes of a file (used to read image dimensions
  // without downloading the whole file). Falls back to aborting early when the
  // server ignores the `Range` header.
  Future<Uint8List?> probeBytes(String url, {int maxBytes = 96 * 1024}) async {
    final requestUrl = resolve(url);
    final request = http.Request('GET', requestUrl)
      ..headers.addAll({
        ..._authHeaders,
        'Range': 'bytes=0-${maxBytes - 1}',
      });

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_getTimeout);
    } on Exception {
      return null;
    }
    if (response.statusCode >= 400) return null;

    final builder = BytesBuilder();
    try {
      await for (final chunk in response.stream) {
        builder.add(chunk);
        if (builder.length >= maxBytes) break;
      }
    } catch (_) {
      // early abort is expected when the server ignores `Range`
    }
    return builder.isEmpty ? null : builder.takeBytes();
  }

  Future<String> _send(http.Request request, {required Duration timeout}) async {
    http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request)).timeout(timeout);
    } on SocketException catch (e) {
      throw WebDavException('connection failed: ${e.message}');
    } on HandshakeException catch (e) {
      throw WebDavException('TLS handshake failed: ${e.message}');
    } on Exception catch (e) {
      throw WebDavException('request failed: $e');
    }

    // follow a single redirect if the server moved the collection
    if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
      final location = response.headers['location'];
      if (location != null) {
        final redirectRequest = http.Request(request.method, resolve(location))
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
        response = await http.Response.fromStream(await _client.send(redirectRequest)).timeout(timeout);
      }
    }

    switch (response.statusCode) {
      case 200:
      case 207:
        return response.body;
      case 401:
        throw const WebDavException('authentication failed, check the username and password', statusCode: 401);
      case 403:
        throw const WebDavException('access forbidden', statusCode: 403);
      case 404:
        throw const WebDavException('path not found, the URL is likely wrong (e.g. AList uses "/dav")', statusCode: 404);
      case 405:
        throw const WebDavException('not a WebDAV endpoint, the URL is likely wrong (e.g. AList uses "/dav")', statusCode: 405);
      default:
        throw WebDavException('unexpected server response', statusCode: response.statusCode);
    }
  }

  // `package:xml` name matching is namespace-prefix sensitive
  // (`findAllElements('response')` does NOT match `<D:response>`),
  // so all lookups go through local-name comparisons.
  static Iterable<XmlElement> _childElements(XmlElement element, String localName) => element.childElements.where((e) => e.name.local == localName);

  static List<WebDavResource> _parseMultiStatus(String body, String requestedPath, Uri base) {
    final resources = <WebDavResource>[];
    final document = XmlDocument.parse(body);

    for (final response in document.descendantElements.where((e) => e.name.local == 'response')) {
      final hrefElement = _childElements(response, 'href').firstOrNull;
      if (hrefElement == null) continue;
      final href = hrefElement.innerText.trim();
      if (href.isEmpty) continue;

      final parsed = Uri.parse(href);
      final resolved = parsed.hasScheme ? parsed : base.resolveUri(parsed);
      // `Uri.path` keeps percent-encoding, so compare on the raw path
      final rawPath = resolved.path;
      final rawRequestedPath = requestedPath;
      if (rawPath == rawRequestedPath || '$rawPath/' == rawRequestedPath) continue;

      final prop = _findProp(response);
      final resourceType = prop == null ? null : _childElements(prop, 'resourcetype').firstOrNull;
      final isCollection = resourceType != null && _childElements(resourceType, 'collection').isNotEmpty;

      final mimeType = _text(prop, 'getcontenttype')?.split(';').first.trim();
      final sizeBytes = int.tryParse(_text(prop, 'getcontentlength') ?? '');
      final lastModified = _text(prop, 'getlastmodified');

      // last path segment, percent-decoded for display
      final trimmedRaw = rawPath.endsWith('/') ? rawPath.substring(0, rawPath.length - 1) : rawPath;
      final slash = trimmedRaw.lastIndexOf('/');
      final name = _decode(trimmedRaw.substring(slash + 1));
      if (name.isEmpty) continue;

      resources.add(
        WebDavResource(
          url: resolved.toString(),
          name: name,
          isCollection: isCollection,
          mimeType: (mimeType != null && mimeType.isNotEmpty) ? mimeType : null,
          sizeBytes: sizeBytes,
          dateModifiedMillis: lastModified != null ? _tryParseHttpDate(lastModified) : null,
        ),
      );
    }

    resources.sort((a, b) {
      if (a.isCollection != b.isCollection) return a.isCollection ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return resources;
  }

  static XmlElement? _findProp(XmlElement response) {
    for (final propstat in _childElements(response, 'propstat')) {
      final status = _childElements(propstat, 'status').firstOrNull?.innerText ?? '';
      if (status.contains(' 200 ') || status.isEmpty) {
        final prop = _childElements(propstat, 'prop').firstOrNull;
        if (prop != null) return prop;
      }
    }
    // fall back to any `prop`
    return _childElements(response, 'prop').firstOrNull;
  }

  static String? _text(XmlElement? prop, String localName) {
    final element = prop == null ? null : _childElements(prop, localName).firstOrNull;
    final text = element?.innerText.trim();
    return (text == null || text.isEmpty) ? null : text;
  }

  static String _decode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      // not valid percent-encoding, use as is
      return value;
    }
  }

  static int? _tryParseHttpDate(String value) {
    try {
      return HttpDate.parse(value).millisecondsSinceEpoch;
    } catch (_) {
      try {
        return DateTime.parse(value).millisecondsSinceEpoch;
      } catch (_) {
        return null;
      }
    }
  }
}
