import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/ui/theme.dart';
import 'package:woi/ui/widgets/controls.dart';
import 'package:woi/ui/widgets/input_bar.dart';
import 'package:woi/ui/widgets/message_tile.dart';
import 'package:woi/ui/widgets/voice_status.dart';

import '../fakes/fakes.dart';

Widget _host(Widget child) => MaterialApp(
  theme: buildWoiTheme(),
  home: Scaffold(
    body: Center(child: SizedBox(width: 360, child: child)),
  ),
);

void main() {
  testWidgets('mic tap toggles listening; a hold records once and release never toggles', (t) async {
    final modes = <MicMode>[];
    var starts = 0;
    var sends = 0;
    var cancels = 0;
    await t.pumpWidget(
      _host(
        MicButton(
          mode: MicMode.handsFree,
          held: false,
          onModeChanged: modes.add,
          onPttDown: () => starts++,
          onPttUp: () => sends++,
          onPttCancel: () => cancels++,
        ),
      ),
    );
    final mic = find.byKey(const ValueKey('mic-button'));
    await t.tap(mic);
    expect(modes, [MicMode.muted]);
    expect(starts, 0);
    final gesture = await t.startGesture(t.getCenter(mic));
    await t.pump(const Duration(milliseconds: 600));
    expect(starts, 1);
    expect(sends, 0);
    await gesture.up();
    await t.pump();
    expect(sends, 1);
    expect(cancels, 0);
    expect(modes, [MicMode.muted]);
    final second = await t.startGesture(t.getCenter(mic));
    await t.pump(const Duration(milliseconds: 600));
    await second.cancel();
    await t.pump();
    expect(starts, 2);
    expect(sends, 1);
    expect(cancels, 1);
  });

  testWidgets('disposing an active mic hold cancels instead of sending', (t) async {
    var sends = 0;
    var cancels = 0;
    await t.pumpWidget(
      _host(
        MicButton(
          mode: MicMode.muted,
          held: false,
          onModeChanged: (_) {},
          onPttDown: () {},
          onPttUp: () => sends++,
          onPttCancel: () => cancels++,
        ),
      ),
    );
    final gesture = await t.startGesture(t.getCenter(find.byKey(const ValueKey('mic-button'))));
    await t.pump(const Duration(milliseconds: 600));
    await t.pumpWidget(const SizedBox.shrink());
    await gesture.up();
    expect(cancels, 1);
    expect(sends, 0);
  });

  testWidgets('composer places status and microphone below text and send at the right edge', (t) async {
    final sent = <String>[];
    await t.pumpWidget(
      _host(
        Composer(
          onSend: sent.add,
          actionsBelow: true,
          actionsLeading: const SizedBox(key: ValueKey('status'), width: 48, height: 48),
          trailing: const SizedBox(key: ValueKey('microphone'), width: 48, height: 48),
        ),
      ),
    );
    final field = find.byKey(const ValueKey('composer-field'));
    final send = find.byKey(const ValueKey('send'));
    final mic = find.byKey(const ValueKey('microphone'));
    final status = find.byKey(const ValueKey('status'));
    expect(t.getCenter(send).dy, t.getCenter(mic).dy);
    expect(t.getCenter(status).dy, t.getCenter(send).dy);
    expect(t.getTopLeft(send).dx, greaterThan(t.getTopRight(mic).dx));
    expect(t.getTopLeft(send).dy, greaterThanOrEqualTo(t.getBottomLeft(field).dy));
    await t.enterText(field, 'Hello');
    await t.pump();
    await t.tap(send);
    expect(sent, ['Hello']);
    expect(t.takeException(), isNull);
  });

  testWidgets('voice status has no inline label and opens details with a retry', (t) async {
    var retries = 0;
    await t.pumpWidget(
      _host(VoiceStatusButton(mode: VoiceMode.offline, detail: 'Connection was lost', onRetry: () => retries++)),
    );
    expect(find.textContaining('Connection was lost'), findsNothing);
    final button = find.byKey(const ValueKey('voice-status-button'));
    expect(t.widget<PopupMenuButton<String>>(button).tooltip, contains('Connection was lost'));
    await t.tap(button);
    await t.pumpAndSettle();
    expect(find.textContaining('Connection was lost'), findsOneWidget);
    await t.tap(find.text('Reconnect'));
    await t.pumpAndSettle();
    expect(retries, 1);
  });

  testWidgets('assistant replies show their persisted model and old replies stay unattributed', (t) async {
    final audio = FakeAudioIO();
    final viewer = FakeViewer();
    final recorded = Message.fromJson(
      Message(kind: MessageKind.assistant, text: 'Hi', meta: {'model': 'voice-A'}).toJson(),
    );
    await t.pumpWidget(_host(MessageTile(message: recorded, audio: audio, viewer: viewer)));
    expect(find.text('voice-A'), findsOneWidget);
    expect(t.getTopLeft(find.text('voice-A')).dy, greaterThan(t.getTopLeft(find.text('Hi')).dy));
    final old = Message(kind: MessageKind.assistant, text: 'Older answer');
    await t.pumpWidget(_host(MessageTile(message: old, audio: audio, viewer: viewer)));
    expect(find.text('Model not recorded'), findsOneWidget);
    expect(find.text('voice-A'), findsNothing);
    final user = Message(kind: MessageKind.user, text: 'Hello');
    await t.pumpWidget(_host(MessageTile(message: user, audio: audio, viewer: viewer)));
    expect(find.text('Model not recorded'), findsNothing);
  });
}
