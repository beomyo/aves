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

// common contract implemented by every remote service backend (WebDAV, SMB, ...)
abstract class CloudClient {
  // lists the entries of a folder
  Future<List<CloudResource>> list(String url);

  // reads a whole file
  Future<Uint8List> getBytes(String url);

  // reads only the leading bytes of a file (used to sniff image dimensions)
  Future<Uint8List?> probeBytes(String url, {int maxBytes});

  // verifies that the server can be reached and browsed
  Future<void> testConnection();

  void close();
}
