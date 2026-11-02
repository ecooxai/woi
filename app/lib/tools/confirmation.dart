import '../platform/files.dart';

/// User approval for side-effecting actions; implemented by the UI.
abstract class ConfirmationService {
  /// Shows the diff preview; resolves true only on explicit approval.
  Future<bool> confirmFileWrite(FileWriteRequest request);

  /// Asks before running a shell command.
  Future<bool> confirmCommand(String command);
}
