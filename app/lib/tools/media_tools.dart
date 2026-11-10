import '../core/voice/voice_backend.dart' show ToolSpec;
import 'tool_registry.dart';

/// What the camera and media tools act on (AppController in the app).
class MediaToolsHost {
  const MediaToolsHost({
    required this.setCamera,
    required this.cameraOn,
    required this.inspectMedia,
    this.cameraStatus,
    this.setCameraFacing,
    this.setScreenSharing,
    this.screenSharingStatus,
  });

  /// Turns the camera on/off; returns the tool result.
  final Future<Map<String, Object?>> Function(bool on) setCamera;
  final bool Function() cameraOn;
  final Future<Map<String, Object?>> Function()? cameraStatus;
  final Future<Map<String, Object?>> Function(String facing)? setCameraFacing;
  final Future<Map<String, Object?>> Function(bool on)? setScreenSharing;
  final Future<Map<String, Object?>> Function()? screenSharingStatus;

  /// Attaches the open viewer item's content to the conversation and returns
  /// the tool result (`ok: false` when nothing is open).
  final Future<Map<String, Object?>> Function(String? question) inspectMedia;
}

ToolSpec _spec(String name, String description, Map<String, Object?> props, [List<String> required = const []]) =>
    ToolSpec(
      name: name,
      description: description,
      parameters: {'type': 'object', 'properties': props, 'required': required, 'additionalProperties': false},
    );

/// `camera` (open/close/status) and `inspect_media` (look at / listen to what
/// is open in Woi's viewer).
List<ToolDefinition> mediaTools(MediaToolsHost host) => [
  ToolDefinition(
    spec: _spec(
      'camera',
      'Control camera input for the current Woi session. Open/switch only when the user asks to activate '
          'or change the camera; mentioning a camera or asking about an image is not permission to start it. '
          'Use open, close, status, or switch with facing front/back. Android may require a visible permission '
          'window. Report pending/starting as pending, never as active; status confirms first-frame readiness. '
          'While active, camera frames can accompany the user’s turns. Close also cancels a pending start.',
      {
        'action': {
          'type': 'string',
          'enum': ['open', 'close', 'status', 'switch'],
        },
        'facing': {
          'type': 'string',
          'enum': ['front', 'back'],
          'description': 'Optional for open; required for switch. Android only.',
        },
      },
      ['action'],
    ),
    handler: (args, _) async {
      final action = args.str('action', 'status');
      final facing = args['facing'] as String?;
      if (facing != null && action != 'open' && action != 'switch') {
        throw ToolFailure('facing is only valid for open or switch.');
      }
      if (action == 'status') {
        return host.cameraStatus != null
            ? await host.cameraStatus!()
            : {'ok': true, 'on': host.cameraOn(), 'state': host.cameraOn() ? 'active' : 'inactive', 'pending': false};
      }
      if (action == 'switch' && facing == null) throw ToolFailure('switch requires facing: front or back.');
      if (facing != null) {
        if (host.setCameraFacing == null) throw ToolFailure('Camera facing selection is unavailable on this platform.');
        return host.setCameraFacing!(facing);
      }
      return host.setCamera(action == 'open');
    },
  ),
  ToolDefinition(
    spec: _spec(
      'screen_share',
      'Start, stop, or check Android screen capture for the current Woi AI session. Start only when the '
          'user asks to share/capture their screen with Woi, not merely because screen content is mentioned. '
          'Android must show its real MediaProjection consent; never accept it for the user or bypass it. '
          'permission_pending/starting is not active. Report the returned state and use status to confirm '
          'capture after consent. Active screen frames can accompany turns. Stop also cancels pending consent. '
          'This controls Woi input, not broadcasting to another recipient.',
      {
        'action': {
          'type': 'string',
          'enum': ['start', 'stop', 'status'],
        },
      },
      ['action'],
    ),
    isEnabled: () => host.setScreenSharing != null && host.screenSharingStatus != null,
    handler: (args, _) async {
      if (args.str('action') == 'status') return host.screenSharingStatus!();
      return host.setScreenSharing!(args.str('action') == 'start');
    },
  ),
  ToolDefinition(
    spec: _spec(
      'inspect_media',
      'Look at or listen to what is open in Woi\'s media viewer, to answer questions about it: an image is '
          'attached as an image, a video as its current frame at the playing position (with the timestamp), '
          'audio comes back as a transcript/description around the current position, text as an excerpt.',
      {
        'question': {'type': 'string', 'description': "The user's question about the media (optional)"},
      },
    ),
    handler: (args, call) async {
      final q = args.str('question');
      return host.inspectMedia(q.isEmpty ? null : q);
    },
  ),
];
