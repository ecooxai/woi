import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/auth/pkce_login.dart';
import 'package:woi/ui/login/login_screen.dart';

class _FakeOpener implements PlatformUrlOpener {
  final opened = <Uri>[];
  @override
  Future<bool> open(Uri url) async {
    opened.add(url);
    return true;
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('woi-login-ui-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Widget app({
    required PkceLoginFlow Function() createFlow,
    Future<void> Function()? onSignedIn,
    Future<void> Function(String)? onApiKey,
  }) => MaterialApp(
    theme: ThemeData(brightness: Brightness.light),
    home: LoginScreen(
      createFlow: createFlow,
      onSignedIn: onSignedIn ?? () async {},
      onApiKey: onApiKey ?? (_) async {},
    ),
  );

  testWidgets('shows both sign-in options', (t) async {
    await t.pumpWidget(app(createFlow: () => throw UnimplementedError()));
    expect(find.text('Sign in with ChatGPT'), findsOneWidget);
    expect(find.text('Use OpenAI API key'), findsOneWidget);
  });

  testWidgets('API key option passes the trimmed key', (t) async {
    String? got;
    await t.pumpWidget(app(createFlow: () => throw UnimplementedError(), onApiKey: (k) async => got = k));
    await t.tap(find.byKey(const ValueKey('login-api-key')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('login-key-field')), '  sk-test  ');
    await t.tap(find.byKey(const ValueKey('login-key-continue')));
    await t.pump();
    expect(got, 'sk-test');
  });

  testWidgets('Sign in opens the browser, waits, and Cancel returns', (t) async {
    final opener = _FakeOpener();
    PkceLoginFlow? flow;
    await t.pumpWidget(
      app(
        createFlow: () => flow = PkceLoginFlow(authPath: '${tmp.path}/auth.json', opener: opener, ports: const [0]),
      ),
    );
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('login-chatgpt')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await t.pump();
    expect(find.byKey(const ValueKey('login-waiting')), findsOneWidget);
    expect(opener.opened.single.host, 'auth.openai.com');
    expect(flow!.port, isNonZero);

    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('login-cancel')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('login-choose')), findsOneWidget);
    expect(find.byKey(const ValueKey('login-error')), findsNothing);
  });
}
