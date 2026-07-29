import 'dart:io';

import 'package:file_picker/file_picker.dart';

class NativeFileSave {
  static Future<bool> saveFileFromPath({
    required String sourcePath,
    String? fileName,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw UnsupportedError(
        'Native file save is only supported on Android and iOS.',
      );
    }

    final file = File(sourcePath);
    if (!file.existsSync()) {
      throw FileSystemException('Source file not found', sourcePath);
    }

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save file',
      fileName: fileName ?? file.uri.pathSegments.last,
      bytes: await file.readAsBytes(),
    );

    return result != null;
  }
}
