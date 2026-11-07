import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../auth/auth.dart';
import '../net/realtime_socket.dart';

/// Describes or transcribes mono PCM16 24 kHz audio for the model.
typedef AudioDescriber = Future<String> Function(Uint8List pcm24k, {String? title, String? question});

const kAudioDescribeInstructions = '''
You describe an audio clip for a voice assistant that cannot hear it. If there is speech, give a verbatim
transcript first (up to ~120 words, then "…"), labelled "Transcript:". Then one or two sentences labelled
"Audio:" about what it is: speech, music (genre, instruments, mood, tempo; the song and artist only if you are
confident), or sounds. Answer the user's question about it if one is given. Plain text, no preamble.''';

/// Audio description through a one-shot Realtime session (text output):
/// the Responses API rejects `input_audio` ("Audio input is not available",
/// probed 2026-11-03 with gpt-6-luna and gpt-6.1-sol on the ChatGPT login),
/// while the Realtime models accept an `input_audio` content part.
AudioDescriber realtimeAudioDescriber({
  required Future<Credentials?> Function() credentials,
  required String Function() model,
  RealtimeConnector? connector,
  Uri? endpoint,
  Duration timeout = const Duration(seconds: 40),
  String instructions = kAudioDescribeInstructions,
}) => (pcm, {title, question}) async {
  final creds = await credentials();
  if (creds == null) throw StateError('not signed in');
  final base = endpoint ?? Uri.parse('wss://api.openai.com/v1/realtime');
  final uri = base.replace(queryParameters: {...base.queryParameters, 'model': model()});
  final ws = await (connector ?? IoRealtimeSocket.connect)(uri, creds.headers()).timeout(const Duration(seconds: 15));
  final text = StringBuffer();
  final done = Completer<String>();
  void fail(Object e) {
    if (!done.isCompleted) done.completeError(e);
  }

  var stage = 0;
  final sub = ws.messages.listen(
    (raw) {
      final Map<String, Object?> e;
      try {
        e = (jsonDecode(raw) as Map).cast();
      } catch (_) {
        return;
      }
      switch (e['type']) {
        case 'session.created' when stage == 0:
          stage = 1;
          ws.send(
            jsonEncode({
              'type': 'session.update',
              'session': {
                'type': 'realtime',
                'instructions': instructions,
                'output_modalities': ['text'],
                'audio': {
                  'input': {
                    'format': {'type': 'audio/pcm', 'rate': 24000},
                    'turn_detection': null,
                  },
                },
              },
            }),
          );
        case 'session.updated' when stage == 1:
          stage = 2;
          ws.send(
            jsonEncode({
              'type': 'conversation.item.create',
              'item': {
                'type': 'message',
                'role': 'user',
                'content': [
                  {'type': 'input_audio', 'audio': base64Encode(pcm)},
                  {
                    'type': 'input_text',
                    'text': [
                      'Audio clip${title == null ? '' : ' from "$title"'}.',
                      if (question != null && question.trim().isNotEmpty) 'User question: ${question.trim()}',
                    ].join(' '),
                  },
                ],
              },
            }),
          );
          ws.send(jsonEncode({'type': 'response.create'}));
        case 'response.output_text.delta' || 'response.text.delta':
          text.write(e['delta'] ?? '');
        case 'response.done':
          var out = text.toString();
          if (out.trim().isEmpty) out = _textOf(e['response']);
          if (!done.isCompleted) done.complete(out);
        case 'error':
          final err = e['error'];
          fail(StateError('realtime error: ${err is Map ? err['message'] : err}'));
      }
    },
    onError: fail,
    onDone: () => fail(StateError('audio describer socket closed (${ws.closeCode} ${ws.closeReason ?? ''})')),
  );
  try {
    return (await done.future.timeout(timeout)).trim();
  } finally {
    await sub.cancel();
    await ws.close();
  }
};

String _textOf(Object? response) {
  final b = StringBuffer();
  if (response is Map && response['output'] is List) {
    for (final o in response['output'] as List) {
      if (o is Map && o['content'] is List) {
        for (final c in o['content'] as List) {
          if (c is Map) b.write(c['text'] ?? c['transcript'] ?? '');
        }
      }
    }
  }
  return b.toString();
}
