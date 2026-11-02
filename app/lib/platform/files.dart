import '../core/util/diff.dart';

enum EntryType { file, directory, link, other }

class DirEntry {
  const DirEntry({
    required this.name,
    required this.type,
    required this.size,
    this.modified,
  });
  final String name;
  final EntryType type;
  final int size;
  final DateTime? modified;

  Map<String, Object?> toJson() => {
        'name': name,
        't': switch (type) {
          EntryType.file => 'f',
          EntryType.directory => 'd',
          EntryType.link => 'l',
          EntryType.other => '?',
        },
        if (type == EntryType.file) 'size': size,
      };
}

class FileReadResult {
  const FileReadResult({
    required this.path,
    required this.content,
    required this.totalBytes,
    required this.totalLines,
    this.truncated = false,
    this.isBinary = false,
    this.startLine = 1,
  });
  final String path;
  final String content;
  final int totalBytes;
  final int totalLines;
  final bool truncated;
  final bool isBinary;
  final int startLine;
}

/// A pending write shown to the user for approval.
class FileWriteRequest {
  const FileWriteRequest({
    required this.path,
    required this.oldContent,
    required this.newContent,
    required this.diff,
    this.reason,
  });
  final String path;

  /// Null when the file does not exist yet.
  final String? oldContent;
  final String newContent;
  final LineDiff diff;
  final String? reason;

  bool get isNewFile => oldContent == null;
}

/// UI hook that approves or rejects a write. Must resolve to true only when
/// the user explicitly approved.
typedef WriteApprover = Future<bool> Function(FileWriteRequest request);

class WriteOutcome {
  const WriteOutcome({
    required this.path,
    required this.approved,
    required this.written,
    this.bytes = 0,
    this.added = 0,
    this.removed = 0,
    this.error,
  });
  final String path;
  final bool approved;
  final bool written;
  final int bytes;
  final int added;
  final int removed;
  final String? error;
}

/// File access. Writes cannot bypass confirmation: [write] requires an
/// approver and only touches the disk after it resolves to true.
abstract class Files {
  /// Expands `~` and makes relative paths relative to the home directory.
  String resolve(String path);

  Future<FileReadResult> read(String path,
      {int maxBytes = 64 * 1024, int? offsetLine, int? limitLines});

  Future<List<DirEntry>> list(String path, {bool showHidden = false});

  Future<WriteOutcome> write(String path, String content,
      {required WriteApprover approve, String? reason});
}
