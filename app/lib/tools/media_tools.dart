import '../core/voice/voice_backend.dart' show ToolSpec;
import 'tool_registry.dart';

/// What the camera and media tools act on (AppController in the app).
class MediaToolsHost {
  const MediaToolsHost({required this.setCamera, required this.cameraOn, required this.inspectMedia});

  /// Turns the camera on/off; returns the tool result.
  final Future<Map<String, Object?>> Function(bool on) setCamera;
  final bool Function() cameraOn;

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
      'Open or close the webcam. While it is open, the latest camera frame is attached to every user turn '
          '(a frame is attached right after opening).',
      {
        'action': {
          'type': 'string',
          'enum': ['open', 'close', 'status'],
        },
      },
      ['action'],
    ),
    handler: (args, call) async {
      final action = args.str('action', 'status');
      if (action == 'status') return {'ok': true, 'on': host.cameraOn()};
      return host.setCamera(action == 'open');
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
