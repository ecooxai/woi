import 'delegation_executor.dart';

export 'delegation_executor.dart' show DelegationImage;

/// Backends whose voice model cannot take images (gpt-live) keep camera
/// frames and media images here for their delegations, one per [slot]
/// ('camera', 'media'). null clears a slot.
abstract class ContextImageSink {
  void setContextImage(String slot, DelegationImage? image);
}

/// Message meta key: what an attached image is ('camera', 'media'; absent
/// for screenshots).
abstract final class ContextImageMeta {
  static const kind = 'imageKind';
}
