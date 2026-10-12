import 'dart:convert';

import 'package:equatable/equatable.dart';

// the kind of remote service behind a `CloudServer`
class CloudServerType {
  static const webDav = 'webdav';
  static const smb = 'smb';

  static const values = [webDav, smb];
}

class CloudServer extends Equatable {
  final String id;
  final String name;

  // one of `CloudServerType`
  final String type;

  // WebDAV: full `http(s)://` URL of the collection
  // SMB: `smb://host/share/path` (share omitted to browse all shares)
  final String url;

  final String username;
  final String password;

  // SMB only: Windows domain / workgroup
  final String domain;

  final bool ignoreTlsErrors;

  @override
  List<Object?> get props => [id, name, type, url, username, password, domain, ignoreTlsErrors];

  const new({
    required this.id,
    required this.name,
    required this.url,
    this.type = CloudServerType.webDav,
    this.username = '',
    this.password = '',
    this.domain = '',
    this.ignoreTlsErrors = false,
  });

  bool get isSmb => type == CloudServerType.smb;

  bool get isWebDav => !isSmb;

  Uri? get uri => Uri.tryParse(url);

  String get host => uri?.host ?? '';

  String get displayName => name.isNotEmpty ? name : url;

  CloudServer copyWith({
    String? id,
    String? name,
    String? type,
    String? url,
    String? username,
    String? password,
    String? domain,
    bool? ignoreTlsErrors,
  }) {
    return CloudServer(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      domain: domain ?? this.domain,
      ignoreTlsErrors: ignoreTlsErrors ?? this.ignoreTlsErrors,
    );
  }

  Map<String, Object?> toJsonMap() => {
    'id': id,
    'name': name,
    'type': type,
    'url': url,
    'username': username,
    'password': password,
    'domain': domain,
    'ignoreTlsErrors': ignoreTlsErrors,
  };

  String toJsonString() => jsonEncode(toJsonMap());

  static String typeForUrl(String url) => url.startsWith('smb://') ? CloudServerType.smb : CloudServerType.webDav;

  static CloudServer? fromJsonString(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) return null;
    try {
      final jsonMap = jsonDecode(jsonString);
      if (jsonMap is Map) {
        final url = jsonMap['url'] as String?;
        if (url == null || url.isEmpty) return null;
        return CloudServer(
          id: (jsonMap['id'] as String?) ?? url,
          name: (jsonMap['name'] as String?) ?? '',
          type: (jsonMap['type'] as String?) ?? typeForUrl(url),
          url: url,
          username: (jsonMap['username'] as String?) ?? '',
          password: (jsonMap['password'] as String?) ?? '',
          domain: (jsonMap['domain'] as String?) ?? '',
          ignoreTlsErrors: (jsonMap['ignoreTlsErrors'] as bool?) ?? false,
        );
      }
    } catch (_) {
      // ignore malformed entry
    }
    return null;
  }
}
