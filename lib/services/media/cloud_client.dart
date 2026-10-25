import 'dart:typed_data';

import 'package:aves/model/source/cloud/cloud_resource.dart';

class CloudException implements Exception {
  final String message;
  final int? statusCode;

  const new(this.message, {this.statusCode});

  bool get isAuthError => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'CloudException($statusCode): $message';
}

// thrown when a transfer is dropped because nobody wants it any more (the
// folder was left) or because it exceeded its budget
class CloudAbortException implements Exception {
  const new();
}

// lets the caller drop a transfer that is no longer useful, so its connection
// and bandwidth are freed for the next listing instead of being held for up to
// two minutes
class CloudAbort {
  bool _aborted = false;

  bool get aborted => _aborted;

  void abort() => _aborted = true;
}

// common contract implemented by every remote service backend (WebDAV, SMB, ...)
abstract class CloudClient {
  // headers a consumer must send to fetch a resource directly from this
  // backend (e.g. WebDAV Basic auth). Empty when the backend needs none,
  // which is the case for SMB since it is served through the loopback bridge.
  Map<String, String> get requestHeaders;

  // lists the entries of a folder
  Future<List<CloudResource>> list(String url);

  // reads a whole file. `abort` lets the caller drop the transfer when the
  // entry is no longer on screen
  Future<Uint8List> getBytes(String url, {CloudAbort? abort});

  // reads only the leading bytes of a file (used to sniff image dimensions)
  Future<Uint8List?> probeBytes(String url, {int maxBytes});

  // deletes a file, or a folder and everything it contains
  Future<void> delete(String url);

  // verifies that the server can be reached and browsed
  Future<void> testConnection();

  void close();
}
