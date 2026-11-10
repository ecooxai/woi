import 'package:flutter/foundation.dart';

/// Capture readiness, distinct from a successful request to show permission UI.
class MediaCaptureState {
  const MediaCaptureState({
    this.state = 'inactive',
    this.requestId = 0,
    this.revision = 0,
    this.message,
    this.error,
    this.facing,
    this.frames = 0,
  });

  final String state;
  final int requestId;
  final int revision;
  final String? message;
  final String? error;
  final String? facing;
  final int frames;
  bool get active => state == 'active';
  bool get pending => state == 'permission_pending' || state == 'starting';
  bool get ok => error == null && state != 'denied' && state != 'error';

  factory MediaCaptureState.fromMap(Map<Object?, Object?> value) => MediaCaptureState(
    state: value['state'] as String? ?? (value['on'] == true ? 'active' : 'inactive'),
    requestId: (value['requestId'] as num?)?.toInt() ?? 0,
    revision: (value['revision'] as num?)?.toInt() ?? 0,
    message: value['message'] as String?,
    error: value['error'] as String?,
    facing: value['facing'] as String?,
    frames: (value['frames'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toToolResult() => {
    'ok': ok,
    'on': active,
    'state': state,
    'pending': pending,
    if (message != null) 'message': message,
    if (error != null) 'error': error,
    if (facing != null) 'facing': facing,
    if (requestId != 0) 'request_id': requestId,
    if (active && frames > 0) 'frames_received': frames,
  };
}

/// Optional screen capture capability. Unsupported platforms do not advertise
/// a screen_share tool; Android routes the UI and tool through this same state.
abstract interface class ScreenSharingControl {
  ValueListenable<MediaCaptureState> get sharingState;
  Future<MediaCaptureState> setSharing(bool on);
  Future<MediaCaptureState> refreshSharing();
}
