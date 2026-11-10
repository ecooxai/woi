import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/models/message_file_attachment.dart';
import 'package:woi/platform/clipboard_access.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/clipboard_selection_area.dart';
import 'package:woi/ui/widgets/message_tile.dart';

import '../fakes/fakes.dart';

class _Clipboard implements ClipboardAccess {
  String? text;
  @override
  Future<String?> readText() async => text;
  @override
  Future<void> writeText(String value) async {
    text = value;
  }
}

void main() {
  const files = [
    MessageFileAttachment(name: 'chosen image.png', uri: 'file:///synthetic/attachments/chosen%20image.png'),
    MessageFileAttachment(name: 'selected.txt', uri: 'file:///synthetic/attachments/selected.txt'),
  ];
  const authored = 'Keep this authored [local link](file:///notes/my-reference.txt) exactly.\nSecond line 🙂';
  final full = '$authored\n\n${files.map((file) => file.markdown).join('\n')}';
  Message message({bool provenance = true}) => Message(
    kind: MessageKind.user,
    text: full,
    createdAt: DateTime(2020),
    meta: {
      if (provenance) messageFilesMeta: [for (final file in files) file.toJson()],
    },
  );

  test('complete generated suffix survives storage while authored links remain text', () {
    final source = message();
    final restored = Message.fromJson((jsonDecode(jsonEncode(source.toJson())) as Map).cast<String, Object?>());
    expect(restored.text, full);
    expect(messageDisplayText(restored), full, reason: 'Copy and other text consumers retain the complete text.');
    final display = messageFileDisplay(restored)!;
    expect(display.text, authored);
    expect(display.files.map((file) => file.markdown), files.map((file) => file.markdown));
    final attachmentsOnly = message()..text = files.map((file) => file.markdown).join('\n');
    expect(messageFileDisplay(attachmentsOnly)!.text, isEmpty);
  });

  test('legacy, partial, stale, malformed and non-user metadata cannot hide text', () {
    expect(messageFileDisplay(message(provenance: false)), isNull);
    final partial = message()..meta[messageFilesMeta] = [files.last.toJson()];
    expect(messageFileDisplay(partial), isNull);
    final stale = message()..text += '\nAuthored after the attachments.';
    expect(messageFileDisplay(stale), isNull);
    for (final value in [
      null,
      [],
      [files.first.toJson(), 7],
      [
        {'name': 'x', 'uri': 'https://example.com/x'},
      ],
    ]) {
      expect(messageFileDisplay(message()..meta[messageFilesMeta] = value), isNull);
    }
    expect(messageFileDisplay(Message(kind: MessageKind.assistant, text: full, meta: message().meta)), isNull);
  });

  for (final provenance in [true, false]) {
    testWidgets('Copy action keeps all text with attachment provenance $provenance', (tester) async {
      final clipboard = _Clipboard();
      final source = message(provenance: provenance);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildWoiTheme(),
          home: Scaffold(
            body: ClipboardSelectionArea(
              clipboard: clipboard,
              child: SingleChildScrollView(
                child: MessageTile(message: source, audio: FakeAudioIO(), viewer: FakeViewer()),
              ),
            ),
          ),
        ),
      );
      expect(find.text(provenance ? authored : full), findsOneWidget);
      if (provenance) {
        expect(find.text('chosen image.png'), findsOneWidget);
        expect(find.text('selected.txt'), findsOneWidget);
        expect(find.text(full), findsNothing);
      }
      await tester.ensureVisible(find.byTooltip('Copy text'));
      await tester.tap(find.byTooltip('Copy text'));
      await tester.pump();
      expect(await clipboard.readText(), full);
      expect(source.text, full);
      expect(tester.takeException(), isNull);
    });
  }
}
