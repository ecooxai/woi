// Stand-alone harness for measuring the built-in terminal's idle CPU without
// the rest of the app's animations:
//   flutter build linux --profile -t tool/terminal_idle_main.dart
//   WOI_TERM_TABS=3 build/linux/x64/profile/bundle/woi      # terminal panel
//   WOI_TERM_BASELINE=1 build/linux/x64/profile/bundle/woi  # static text only
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:woi/core/terminal/terminal_hub.dart';
import 'package:woi/ui/terminal/terminal_panel.dart';

void main() {
  final env = Platform.environment;
  final hub = TerminalHub(workingDirectory: () => Directory.current.path);
  final tabs = int.tryParse(env['WOI_TERM_TABS'] ?? '') ?? 1;
  for (var i = 1; i < tabs; i++) {
    hub.newShell();
  }
  final dark = env['WOI_TERM_DARK'] == '1';
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light, useMaterial3: true),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: env['WOI_TERM_BASELINE'] == '1'
              ? const Center(child: Text('baseline: no terminal'))
              : TerminalPanel(hub: hub),
        ),
      ),
    ),
  );
}
