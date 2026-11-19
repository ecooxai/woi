import '../platform/files.dart';

/// User approval for side-effecting actions; implemented by the UI.
abstract class ConfirmationService {
  /// Shows the diff preview; resolves true only on explicit approval.
  Future<bool> confirmFileWrite(FileWriteRequest request);

  /// Asks before running a shell command.
  Future<bool> confirmCommand(String command);
}

/// Preserves backups/undo for an already-authorized automatic worker without
/// opening a second app-level approval prompt.
abstract class AutomaticFileWriteApproval {
  Future<bool> approveAutomaticFileWrite(FileWriteRequest request);
}
