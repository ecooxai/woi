import 'dart:io';

import 'package:path/path.dart' as p;

import 'android/android_bridge.dart';

/// Copies [srcPath] to the user's Downloads as [fileName] (a free name is
/// picked when it exists). Returns where it went, for the user.
///
/// Linux: the XDG download dir (`xdg-user-dir DOWNLOAD`, else ~/Downloads).
/// Android: the shared Downloads collection (MediaStore), "Download/Woi".
Future<String> saveToDownloads(String srcPath, String fileName, {String mime = 'audio/wav'}) async {
  if (Platform.isAndroid) {
    final where = await AndroidBridge.method.invokeMethod<String>('saveDownload', {
      'path': srcPath,
      'name': fileName,
      'mime': mime,
    });
    return where ?? 'Downloads';
  }
  final dir = Directory(await _downloadDir());
  await dir.create(recursive: true);
  final base = p.basenameWithoutExtension(fileName);
  final ext = p.extension(fileName);
  var target = p.join(dir.path, fileName);
  for (var i = 2; await File(target).exists(); i++) {
    target = p.join(dir.path, '$base ($i)$ext');
  }
  await File(srcPath).copy(target);
  return target;
}

Future<String> _downloadDir() async {
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  try {
    final r = await Process.run('xdg-user-dir', ['DOWNLOAD']);
    final d = (r.stdout as String).trim();
    // xdg-user-dir prints $HOME itself when the dir is not configured.
    if (r.exitCode == 0 && d.isNotEmpty && d != home) return d;
  } catch (_) {}
  return p.join(home, 'Downloads');
}
