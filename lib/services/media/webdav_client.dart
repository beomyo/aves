import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aves/model/source/cloud/cloud_resource.dart';
import 'package:aves/model/source/cloud/cloud_server.dart';
import 'package:aves/services/media/cloud_client.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:xml/xml.dart';

// a network level failure (as opposed to a server response): these are the ones
// worth a retry, because the usual cause is a pooled keep-alive connection the
// server already closed, and a fresh attempt succeeds at once
class _TransportError implements Exception {
  final Object cause;

  const new(this.cause);
}

class WebDavClient implements CloudClient {
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

  static const _listTimeout = Duration(seconds: 45);
  static const _getTimeout = Duration(seconds: 120);
  static const _deleteTimeout = Duration(seconds: 120);

  final CloudServer server;

  // normalized base URL, always ending with a separator
  late final Uri baseUri;
  late final http.Client _client;

  new(this.server) {
    var url = server.url.trim();
    if (!url.endsWith('/')) {
      url = '$url/';
    }
    baseUri = Uri.parse(url);
    // an explicit HTTP client, so that an unreachable host or a half open
    // connection cannot hold a request open for minutes, and so that pooled
    // connections are dropped early (reusing one the server already closed is
    // the usual reason a request hangs instead of failing)
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 8);
    if (server.ignoreTlsErrors) {
      httpClient.badCertificateCallback = ((cert, host, port) => true);
    }
    _client = IOClient(httpClient);
  }

  @override
  void close() => _client.close();

  // retries a network level failure once: the first attempt may have used a
  // stale pooled connection, the second one opens a fresh one
  Future<T> _withRetry<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on _TransportError {
      try {
        return await action();
      } on _TransportError catch (retryError) {
        throw CloudException(_describeTransport(retryError.cause));
      } on CloudAbortException {
        rethrow;
      } on CloudException {
        rethrow;
      } catch (retryError) {
        throw CloudException('request failed: $retryError');
      }
    }
  }

  static String _describeTransport(Object error) {
    if (error is SocketException) return 'connection failed: ${error.message}';
    if (error is HandshakeException) return 'TLS handshake failed: ${error.message}';
    if (error is TimeoutException) return 'the server did not respond in time';
    return 'connection failed: $error';
  }

  @override
  Map<String, String> get requestHeaders {
    if (server.username.isEmpty && server.password.isEmpty) return const {};
    final token = base64Encode(utf8.encode('${server.username}:${server.password}'));
    return {'Authorization': 'Basic $token'};
  }

  Uri resolve(String url) {
    final uri = Uri.parse(url);
    if (uri.hasScheme) return uri;
    return baseUri.resolveUri(uri);
  }

  @override
  Future<void> testConnection() async {
    await list(baseUri.toString());
  }

  @override
  Future<List<CloudResource>> list(String url) async {
    final requestUrl = resolve(url);
    // a request object can only be finalized once, so a retry needs a fresh one
    http.Request build() => http.Request('PROPFIND', requestUrl)
      ..headers.addAll({
        ...requestHeaders,
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      })
      ..bodyBytes = utf8.encode(_propfindBody);

    final body = await _send(build, timeout: _listTimeout);
    return _parseMultiStatus(body, requestUrl.path, baseUri);
  }

  @override
  Future<Uint8List> getBytes(String url, {CloudAbort? abort}) {
    final requestUrl = resolve(url);
    // the deadline aborts the transfer itself, not only the future waiting on
    // it: a stalled body used to keep its connection for the full timeout
    final deadline = CloudAbort();
    final timer = Timer(_getTimeout, deadline.abort);
    return _withRetry(() => _download(requestUrl, abort, deadline)).whenComplete(timer.cancel);
  }

  Future<Uint8List> _download(Uri requestUrl, CloudAbort? caller, CloudAbort deadline) async {
    final request = http.Request('GET', requestUrl)..headers.addAll(requestHeaders);
    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_getTimeout);
    } on SocketException catch (e) {
      throw _TransportError(e);
    } on HandshakeException catch (e) {
      throw _TransportError(e);
    } on HttpException catch (e) {
      throw _TransportError(e);
    } on http.ClientException catch (e) {
      throw _TransportError(e);
    }
    if (response.statusCode >= 400) {
      throw CloudException('failed to download file', statusCode: response.statusCode);
    }

    final builder = BytesBuilder(copy: false);
    try {
      // leaving this loop (including by throwing) cancels the subscription,
      // which closes the connection
      await for (final chunk in response.stream) {
        if ((caller?.aborted ?? false) || deadline.aborted) {
          throw const CloudAbortException();
        }
        builder.add(chunk);
      }
    } on HttpException catch (e) {
      throw _TransportError(e);
    } on http.ClientException catch (e) {
      throw _TransportError(e);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> delete(String url) {
    final requestUrl = resolve(url);
    return _withRetry(() async {
      http.Response response;
      try {
        response = await _client.delete(requestUrl, headers: requestHeaders).timeout(_deleteTimeout);
      } on SocketException catch (e) {
        throw _TransportError(e);
      } on HandshakeException catch (e) {
        throw _TransportError(e);
      } on HttpException catch (e) {
        throw _TransportError(e);
      } on http.ClientException catch (e) {
        throw _TransportError(e);
      }
      // a missing resource is already in the desired state
      if (response.statusCode >= 400 && response.statusCode != 404) {
        throw CloudException('failed to delete', statusCode: response.statusCode);
      }
    });
  }

  // fetches only the leading bytes of a file (used to read image dimensions
  // without downloading the whole file). Falls back to aborting early when the
  // server ignores the `Range` header.
  @override
  Future<Uint8List?> probeBytes(String url, {int maxBytes = 96 * 1024}) async {
    final requestUrl = resolve(url);
    final request = http.Request('GET', requestUrl)
      ..headers.addAll({
        ...requestHeaders,
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

  Future<String> _send(http.Request Function() build, {required Duration timeout}) {
    return _withRetry(() async {
      final request = build();
      http.Response response;
      try {
        response = await http.Response.fromStream(await _client.send(request)).timeout(timeout);
      } on SocketException catch (e) {
        throw _TransportError(e);
      } on HandshakeException catch (e) {
        throw _TransportError(e);
      } on HttpException catch (e) {
        throw _TransportError(e);
      } on http.ClientException catch (e) {
        throw _TransportError(e);
      } on TimeoutException catch (e) {
        // a half open connection never answers: a fresh attempt usually does
        throw _TransportError(e);
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
          throw const CloudException('authentication failed, check the username and password', statusCode: 401);
        case 403:
          throw const CloudException('access forbidden', statusCode: 403);
        case 404:
          throw const CloudException('path not found, the URL is likely wrong (e.g. AList uses "/dav")', statusCode: 404);
        case 405:
          throw const CloudException('not a WebDAV endpoint, the URL is likely wrong (e.g. AList uses "/dav")', statusCode: 405);
        default:
          throw CloudException('unexpected server response', statusCode: response.statusCode);
      }
    });
  }

  // `package:xml` name matching is namespace-prefix sensitive
  // (`findAllElements('response')` does NOT match `<D:response>`),
  // so all lookups go through local-name comparisons.
  static Iterable<XmlElement> _childElements(XmlElement element, String localName) => element.childElements.where((e) => e.name.local == localName);

  static List<CloudResource> _parseMultiStatus(String body, String requestedPath, Uri base) {
    final resources = <CloudResource>[];
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
        CloudResource(
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
