import 'package:nearsend/platform/storage_location.dart';

class ReceiveFilePreview {
  const ReceiveFilePreview({
    required this.fileId,
    required this.originalPath,
    required this.sizeBytes,
  });

  final String fileId;
  final String originalPath;
  final int sizeBytes;

  String get suggestedName =>
      originalPath.substring(originalPath.lastIndexOf('/') + 1);
}

class ReceiveConfirmation {
  const ReceiveConfirmation({
    required this.location,
    required this.outputNames,
    this.rememberAsDefault = false,
  });

  final StorageLocationRef location;
  final Map<String, String> outputNames;
  final bool rememberAsDefault;
}
