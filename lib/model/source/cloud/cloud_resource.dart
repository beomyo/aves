import 'package:equatable/equatable.dart';

class CloudResource extends Equatable {
  // absolute URL used for requests
  final String url;
  // decoded last path segment, used for display
  final String name;
  final bool isCollection;
  final String? mimeType;
  final int? sizeBytes;
  final int? dateModifiedMillis;

  @override
  List<Object?> get props => [url, name, isCollection, mimeType, sizeBytes, dateModifiedMillis];

  const new({
    required this.url,
    required this.name,
    required this.isCollection,
    this.mimeType,
    this.sizeBytes,
    this.dateModifiedMillis,
  });

  bool get isImage => !isCollection && (mimeType?.startsWith('image/') ?? false);
}
