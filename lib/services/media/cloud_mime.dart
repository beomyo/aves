import 'package:aves/model/source/cloud/cloud_resource.dart';
import 'package:aves/ref/mime_types.dart';

// mime sniffing for remote (WebDAV/SMB) resources, shared by the cloud browser
// and the in-player video picker, so media detection stays identical
String cloudMimeForResource(CloudResource resource) {
  if (resource.isCollection) return 'application/octet-stream';
  final reported = resource.mimeType;
  if (reported != null && (MimeTypes.isImage(reported) || MimeTypes.isVideo(reported))) {
    return reported;
  }
  return cloudMimeForName(resource.name);
}

String cloudMimeForName(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
  if (lower.endsWith('.avif')) return 'image/avif';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  if (lower.endsWith('.tif') || lower.endsWith('.tiff')) return 'image/tiff';
  if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) return 'video/mp4';
  if (lower.endsWith('.mkv')) return 'video/x-matroska';
  if (lower.endsWith('.webm')) return 'video/webm';
  if (lower.endsWith('.mov')) return 'video/quicktime';
  if (lower.endsWith('.avi')) return 'video/x-msvideo';
  if (lower.endsWith('.wmv')) return 'video/x-ms-wmv';
  if (lower.endsWith('.flv')) return 'video/x-flv';
  if (lower.endsWith('.ts') || lower.endsWith('.m2ts')) return 'video/mp2t';
  if (lower.endsWith('.mpg') || lower.endsWith('.mpeg')) return 'video/mpeg';
  if (lower.endsWith('.3gp')) return 'video/3gpp';
  if (lower.endsWith('.3g2')) return 'video/3gpp2';
  if (lower.endsWith('.ogv')) return 'video/ogg';
  return 'application/octet-stream';
}
