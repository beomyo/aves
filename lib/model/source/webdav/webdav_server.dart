import 'dart:convert';

import 'package:equatable/equatable.dart';

class WebDavServer extends Equatable {
  final String id;
  final String name;
  final String url;
  final String username;
  final String password;
  final bool ignoreTlsErrors;

  @override
  List<Object?> get props => [id, name, url, username, password, ignoreTlsErrors];

  const new({
    required this.id,
    required this.name,
    required this.url,
    required this.username,
    required this.password,
    this.ignoreTlsErrors = false,
  });

  String get displayName => name.isNotEmpty ? name : url;

  WebDavServer copyWith({
    String? id,
    String? name,
    String? url,
    String? username,
    String? password,
    bool? ignoreTlsErrors,
  }) {
    return WebDavServer(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      ignoreTlsErrors: ignoreTlsErrors ?? this.ignoreTlsErrors,
    );
  }

  Map<String, Object?> toJsonMap() => {
    'id': id,
    'name': name,
    'url': url,
    'username': username,
    'password': password,
    'ignoreTlsErrors': ignoreTlsErrors,
  };

  String toJsonString() => jsonEncode(toJsonMap());

  static WebDavServer? fromJsonString(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) return null;
    try {
      final jsonMap = jsonDecode(jsonString);
      if (jsonMap is Map) {
        final url = jsonMap['url'] as String?;
        if (url == null || url.isEmpty) return null;
        return WebDavServer(
          id: (jsonMap['id'] as String?) ?? url,
          name: (jsonMap['name'] as String?) ?? '',
          url: url,
          username: (jsonMap['username'] as String?) ?? '',
          password: (jsonMap['password'] as String?) ?? '',
          ignoreTlsErrors: (jsonMap['ignoreTlsErrors'] as bool?) ?? false,
        );
      }
    } catch (_) {
      // ignore malformed entry
    }
    return null;
  }
}
