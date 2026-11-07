import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/models/message.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/platform/android/android_python_runner.dart';
import 'package:woi/platform/linux/linux_shell.dart';
import 'package:woi/platform/python_runner.dart';
import 'package:woi/platform/shell.dart';
import 'package:woi/tools/python_tool.dart';
import 'package:woi/tools/tool_registry.dart';

import 'fakes/fakes.dart';

class _Python implements PythonRunner {
  final calls = <({String code, String cwd, Duration timeout})>[];
  ShellResult result = const ShellResult(
    exitCode: 0,
    stdout: '42\n',
    stderr: '',
    elapsed: Duration.zero,
  );
  @override
  Future<ShellResult> run(
    String code, {
    required String workingDirectory,
    Duration timeout = const Duration(seconds: 30),
    int maxOutputChars = 8000,
  }) async {
    calls.add((code: code, cwd: workingDirectory, timeout: timeout));
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePlatform platform;
  late FakeConfirmations confirmations;
  late _Python runner;
  late ToolRegistry registry;
  var settings = const AppSettings();
  setUp(() async {
    platform = await FakePlatform.create();
    confirmations = FakeConfirmations();
    runner = _Python();
    settings = const AppSettings();
    registry = ToolRegistry()
      ..register(
        pythonTool(
          runner: runner,
          files: platform.services.files,
          confirmations: confirmations,
          settings: () => settings,
        ),
      );
  });
  tearDown(() => platform.dispose());

  test('calculation returns real output and resolves home cwd', () async {
    final result = await registry.dispatch(
      'python',
      jsonEncode({'code': 'print(6 * 7)', 'cwd': '~'}),
    );
    expect(result.status, ToolStatus.success);
    expect(jsonDecode(result.json), containsPair('stdout', '42\n'));
    expect(runner.calls.single.cwd, platform.root.path);
    expect(runner.calls.single.code, 'print(6 * 7)');
  });

  test('Python respects command denial before executing', () async {
    settings = settings.copyWith(confirmBeforeBash: true);
    confirmations.approveCommands = false;
    final result = await registry.dispatch('python', '{"code":"print(7)"}');
    expect(result.status, ToolStatus.denied);
    expect(runner.calls, isEmpty);
    expect(confirmations.commandRequests.single, contains('print(7)'));
  });

  test('invalid code and cwd never reach a runner', () async {
    for (final args in [
      {'code': '  '},
      {'code': 'x' * 65537},
      {'code': 'print(1)', 'cwd': '~/missing'},
    ]) {
      expect(
        (await registry.dispatch('python', jsonEncode(args))).status,
        ToolStatus.error,
      );
    }
    expect(runner.calls, isEmpty);
  });

  test(
    'timeout is bounded and failure output is not claimed as success',
    () async {
      runner.result = const ShellResult(
        exitCode: -9,
        stdout: '',
        stderr: 'timed out',
        elapsed: Duration(seconds: 1),
        timedOut: true,
      );
      final result = await registry.dispatch(
        'python',
        '{"code":"while True: pass","timeout_s":999}',
      );
      expect(runner.calls.single.timeout, const Duration(seconds: 300));
      expect(jsonDecode(result.json), containsPair('ok', false));
      expect(jsonDecode(result.json), containsPair('timed_out', true));
    },
  );

  test(
    'Android transports Python source literally and reports worker result',
    () async {
      const channel = MethodChannel('woi-test/python');
      MethodCall? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            seen = call;
            return {'exit_code': 0, 'stdout': '21\n', 'stderr': '', 'ms': 3};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      const code = "value = 3 * 7\nprint(value)";
      final result = await const AndroidPythonRunner(channel: channel)
          .run(code, workingDirectory: platform.root.path);
      expect(seen!.method, 'pythonRun');
      expect((seen!.arguments as Map)['code'], code);
      expect((seen!.arguments as Map)['timeout_ms'], 30000);
      expect(result.stdout, '21\n');
      expect(result.exitCode, 0);
    },
  );

  test('desktop executes multiline Python without shell expansion', () async {
    const code =
        "from decimal import Decimal\nprint(Decimal('0.1') + Decimal('0.2'))\n"
        r'''print("quote ' $HOME $(touch should_not_exist)")''';
    final result = await ShellPythonRunner(LinuxShell())
        .run(code, workingDirectory: platform.root.path);
    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stdout, startsWith('0.3\n'));
    expect(result.stdout, contains(r'$HOME $(touch should_not_exist)'));
    expect(
      File('${platform.root.path}/should_not_exist').existsSync(),
      isFalse,
    );
  }, skip: !Platform.isLinux);

  test(
    'desktop timeout stops a blocked Python process and next call works',
    () async {
      final python = ShellPythonRunner(LinuxShell());
      final slow = await python.run(
        'import time\nprint("started", flush=True)\ntime.sleep(10)',
        workingDirectory: platform.root.path,
        timeout: const Duration(milliseconds: 300),
      );
      expect(slow.timedOut, isTrue);
      expect(slow.elapsed, lessThan(const Duration(seconds: 4)));
      final next = await python.run(
        'print(137 * 281)',
        workingDirectory: platform.root.path,
      );
      expect(next.stdout.trim(), '38497');
      expect(next.exitCode, 0);
    },
    skip: !Platform.isLinux,
  );
}
