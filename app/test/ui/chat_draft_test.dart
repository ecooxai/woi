import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:woi/platform/clipboard_access.dart';
import 'package:woi/platform/file_picker.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/chat_draft.dart';
import 'package:woi/ui/widgets/controls.dart';

Widget _host(Widget child) => MaterialApp(
  theme: buildWoiTheme(),
  home: Scaffold(body: SizedBox(width: 360, child: child)),
);

void main() {
  test('clipboard text replaces the selected draft range; AI staging appends', () {
    final draft = ChatDraftController();
    addTearDown(draft.dispose);
    draft.text.value = const TextEditingValue(
      text: 'hello world',
      selection: TextSelection(baseOffset: 6, extentOffset: 11),
    );
    draft.stageClipboard(const ClipboardContent(text: 'there'));
    expect(draft.text.text, 'hello there');
    expect(draft.text.selection.baseOffset, 11);
    draft.stageClipboard(const ClipboardContent(text: 'question'), append: true);
    expect(draft.text.text, 'hello there\nquestion');
  });

  test('image paste stores actual bytes and a file-limit failure is atomic', () {
    final draft = ChatDraftController();
    addTearDown(draft.dispose);
    final bytes = Uint8List.fromList([1, 2, 3]);
    draft.stageClipboard(
      ClipboardContent(
        image: ClipboardImage(bytes: bytes, name: 'paste.png'),
      ),
    );
    bytes[0] = 9;
    expect(draft.attachments.single.bytes, [1, 2, 3]);
    expect(draft.text.text, isEmpty);
    expect(
      () => draft.addFiles(
        List.generate(8, (i) => PickedFile(bytes: Uint8List(0), name: '$i.txt', mimeType: 'text/plain')),
      ),
      throwsStateError,
    );
    expect(draft.attachments.single.name, 'paste.png');
    draft.remove(draft.attachments.single);
    expect(draft.hasAttachments, isFalse);
  });

  test('delayed image paste follows continued typing but not sent, cleared, or replaced drafts', () {
    final draft = ChatDraftController();
    addTearDown(draft.dispose);
    final image = ClipboardContent(image: ClipboardImage(bytes: Uint8List.fromList([1, 2, 3])));
    draft.insertText('Question');
    final typing = draft.capturePasteTarget();
    draft.insertText(' continued');
    draft.stageClipboard(image, at: typing);
    expect(draft.text.text, 'Question continued');
    expect(draft.attachments, hasLength(1));
    draft.clearAttachments();

    final sent = draft.capturePasteTarget();
    draft.setSending(true);
    draft.setSending(false);
    expect(() => draft.stageClipboard(image, at: sent), throwsStateError);

    final cleared = draft.capturePasteTarget();
    draft.text.clear();
    expect(() => draft.stageClipboard(image, at: cleared), throwsStateError);

    draft.insertText('Old draft');
    final replaced = draft.capturePasteTarget();
    draft.text.selection = TextSelection(baseOffset: 0, extentOffset: draft.text.text.length);
    draft.insertText('New draft');
    expect(() => draft.stageClipboard(image, at: replaced), throwsStateError);
    expect(draft.attachments, isEmpty);
    expect(draft.text.text, 'New draft');
    final previousConversation = draft.capturePasteTarget();
    draft.retirePendingPastes();
    expect(() => draft.stageClipboard(image, at: previousConversation), throwsStateError);
  });

  test('accepted submission clears the exact text and attachments together', () {
    final draft = ChatDraftController()..insertText('Please review');
    addTearDown(draft.dispose);
    draft.addFiles([
      PickedFile(bytes: Uint8List.fromList([1, 2, 3]), name: 'readme.txt', mimeType: 'text/plain'),
    ]);
    draft.setSending(true);
    final sent = draft.captureSubmission();
    draft.text.selection = const TextSelection.collapsed(offset: 3);
    expect(draft.clearSubmitted(sent), isTrue, reason: 'Selection movement does not change the submitted draft.');
    expect(draft.text.text, isEmpty);
    expect(draft.attachments, isEmpty);
    draft.setSending(false);
  });

  test('accepted old submissions cannot clear replacements, another conversation, or another draft', () {
    final draft = ChatDraftController()..insertText('Same words');
    final other = ChatDraftController()..insertText('Same words');
    addTearDown(draft.dispose);
    addTearDown(other.dispose);
    draft.setSending(true);
    final old = draft.captureSubmission();
    draft.text.clear();
    draft.text.text = 'Same words';
    expect(draft.clearSubmitted(old), isFalse, reason: 'Returning to identical text is still a replacement draft.');
    expect(other.clearSubmitted(old), isFalse);
    final priorConversation = draft.captureSubmission();
    draft.retirePendingPastes();
    expect(draft.clearSubmitted(priorConversation), isFalse);
    expect(draft.text.text, 'Same words');
    draft.setSending(false);
  });

  testWidgets('shared draft owns clearing after delayed send and preserves a replacement with equal text', (t) async {
    final draft = ChatDraftController()..insertText('Keep this replacement');
    final gate = Completer<void>();
    await t.pumpWidget(
      _host(
        Composer(
          controller: draft.text,
          clearOnSend: false,
          onSend: (_) async {
            draft.setSending(true);
            final sent = draft.captureSubmission();
            await gate.future;
            draft.clearSubmitted(sent);
            draft.setSending(false);
          },
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('send')));
    await t.pump();
    draft.text.clear();
    draft.text.text = 'Keep this replacement';
    gate.complete();
    await t.pumpAndSettle();
    expect(draft.text.text, 'Keep this replacement');
    await t.pumpWidget(const SizedBox.shrink());
    draft.dispose();
  });

  testWidgets('generic composer never clears a replacement text controller after delayed send', (t) async {
    final original = TextEditingController(text: 'Same question');
    final replacement = TextEditingController(text: 'Same question');
    final gate = Completer<void>();
    Future<void> onSend(String text) => gate.future;
    await t.pumpWidget(_host(Composer(controller: original, onSend: onSend)));
    await t.tap(find.byKey(const ValueKey('send')));
    await t.pump();
    await t.pumpWidget(_host(Composer(controller: replacement, onSend: onSend)));
    gate.complete();
    await t.pumpAndSettle();
    expect(replacement.text, 'Same question');
    await t.pumpWidget(const SizedBox.shrink());
    original.dispose();
    replacement.dispose();
  });

  testWidgets('image-only send is enabled and remains pending until accepted', (t) async {
    final draft = ChatDraftController();
    final gate = Completer<void>();
    final sent = <String>[];
    await t.pumpWidget(
      _host(
        Composer(
          controller: draft.text,
          hasAttachments: true,
          onSend: (text) {
            sent.add(text);
            return gate.future;
          },
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('send')));
    await t.pump();
    expect(sent, ['']);
    expect(t.widget<IconButton>(find.byKey(const ValueKey('send'))).onPressed, isNull);
    gate.complete();
    await t.pump();
    await t.pumpWidget(const SizedBox.shrink());
    draft.dispose();
  });

  testWidgets('send failure preserves draft text and external text updates remain visible', (t) async {
    final draft = ChatDraftController();
    draft.insertText('Do not lose this');
    await t.pumpWidget(
      _host(Composer(controller: draft.text, onSend: (_) => Future<void>.error(StateError('Connection unavailable')))),
    );
    await t.tap(find.byKey(const ValueKey('send')));
    await t.pumpAndSettle();
    expect(draft.text.text, 'Do not lose this');
    expect(find.text('Connection unavailable'), findsOneWidget);
    draft.insertText('\nAdded from Clipboard', append: true);
    await t.pump();
    expect(find.textContaining('Added from Clipboard'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
    draft.dispose();
  });

  testWidgets('Ctrl+V delegates rich paste without changing unrelated editor text', (t) async {
    var pastes = 0;
    final draft = ChatDraftController();
    await t.pumpWidget(_host(Composer(controller: draft.text, onSend: (_) {}, onPaste: () => pastes++)));
    await t.tap(find.byKey(const ValueKey('composer-field')));
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyV);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(pastes, 1);
    expect(draft.text.text, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
    draft.dispose();
  });

  for (final width in [320.0, 360.0]) {
    testWidgets('attachment count and horizontal scroll reveal every selected file at $width px', (t) async {
      final draft = ChatDraftController();
      const longName = 'long-file-name-synthetic-review-synthetic-review-synthetic-review.txt';
      draft.addFiles([
        PickedFile(bytes: Uint8List.fromList([1]), name: longName, mimeType: 'text/plain'),
        PickedFile(
          bytes: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5VEAAAAASUVORK5CYII=',
          ),
          name: 'selected-image.png',
          mimeType: 'image/png',
        ),
        PickedFile(bytes: Uint8List.fromList([2]), name: 'unread-binary.dat', mimeType: 'application/octet-stream'),
      ]);
      await t.pumpWidget(
        MaterialApp(
          theme: buildWoiTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: ChatAttachmentTray(draft: draft),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('3 attachments'), findsOneWidget);
      expect(find.text('Swipe or scroll'), findsOneWidget);
      expect(find.byTooltip(longName), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('chat-attachment-name-0'))).maxLines, 2);
      await t.drag(find.byKey(const ValueKey('chat-attachments-scroll')), const Offset(-600, 0));
      await t.pumpAndSettle();
      expect(find.byTooltip('Remove unread-binary.dat').hitTestable(), findsOneWidget);
      await t.tap(find.byTooltip('Remove unread-binary.dat'));
      await t.pumpAndSettle();
      expect(draft.attachments.map((file) => file.name), [longName, 'selected-image.png']);
      expect(find.text('2 attachments'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
      draft.dispose();
    });
  }

  for (final source in const [(16, 16384), (16384, 16)]) {
    testWidgets('extreme ${source.$1}x${source.$2} thumbnail decodes inside both bounds', (t) async {
      final draft = ChatDraftController();
      draft.addFiles([
        PickedFile(
          bytes: img.encodePng(img.Image(width: source.$1, height: source.$2)),
          name: 'extreme.png',
          mimeType: 'image/png',
        ),
      ]);
      await t.pumpWidget(_host(ChatAttachmentTray(draft: draft)));
      await t.pumpAndSettle();
      final widget = t.widget<Image>(
        find.descendant(of: find.byKey(const ValueKey('chat-attachment-0')), matching: find.byType(Image)),
      );
      final dimensions = await t.runAsync(() async {
        final completed = Completer<(int, int)>();
        final stream = widget.image.resolve(const ImageConfiguration());
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (info, _) {
            if (!completed.isCompleted) completed.complete((info.image.width, info.image.height));
          },
          onError: (Object error, StackTrace? stack) {
            if (!completed.isCompleted) completed.completeError(error, stack);
          },
        );
        stream.addListener(listener);
        try {
          return await completed.future.timeout(const Duration(seconds: 5));
        } finally {
          stream.removeListener(listener);
        }
      });
      final (width, height) = dimensions!;
      expect(width, inInclusiveRange(1, 280));
      expect(height, inInclusiveRange(1, 160));
      expect(width * height, lessThanOrEqualTo(280 * 160));
      await t.pumpWidget(const SizedBox.shrink());
      draft.dispose();
    });
  }
}
