import 'package:path/path.dart' as p;

/// Where the app keeps its data. On Linux: `~/.local/share/woi`.
class AppPaths {
  const AppPaths({required this.dataDir, required this.homeDir});

  final String dataDir;
  final String homeDir;

  String get conversationsDir => p.join(dataDir, 'conversations');
  String get audioDir => p.join(dataDir, 'audio');
  String get imagesDir => p.join(dataDir, 'images');
  String get settingsFile => p.join(dataDir, 'settings.json');
}
