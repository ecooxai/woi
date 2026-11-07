import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/linux/pipewire_aec.dart';

class _Host implements Process {
  _Host({this.exitOnKill = true}) {
    input.stream.listen(
      (_) {},
      onDone: () {
        if (exitOnKill) exit();
      },
    );
    stdin = IOSink(input.sink);
  }
  final bool exitOnKill;
  final input = StreamController<List<int>>();
  final exited = Completer<int>();
  int kills = 0;
  @override
  late final IOSink stdin;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => exited.future;
  @override
  int get pid => 1;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (exitOnKill) exit();
    return true;
  }

  void exit() {
    if (!exited.isCompleted) exited.complete(0);
  }
}

void main() {
  test(
    'parallel acquires share startup and linger does not stop a remaining user',
    () async {
      final gate = Completer<Process>();
      var starts = 0;
      final launched = Completer<void>();
      final host = _Host();
      final aec = PipewireEchoCancel(
        instanceId: 'parallel',
        linger: const Duration(milliseconds: 5),
        startHostProcess: (_) {
          starts++;
          if (!launched.isCompleted) launched.complete();
          return gate.future;
        },
        probeNode: (_) async => true,
        readDefaults: () async => (null, null),
        log: (_) {},
      );
      final first = aec.acquire();
      final second = aec.acquire();
      await launched.future.timeout(const Duration(seconds: 2));
      expect(starts, 1);
      gate.complete(host);
      expect(await first, await second);
      aec.release();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(host.kills, 0);
      aec.release();
      await host.exitCode.timeout(const Duration(seconds: 2));
      await aec.stop();
      expect(aec.running, isFalse);
      await aec.dispose();
    },
  );

  test(
    'reconnect waits for old shutdown and never reuses its source or config',
    () async {
      final hosts = <_Host>[];
      final configs = <String>[];
      final aec = PipewireEchoCancel(
        instanceId: 'reconnect',
        startHostProcess: (path) async {
          configs.add(path);
          final host = _Host(exitOnKill: hosts.isNotEmpty);
          hosts.add(host);
          return host;
        },
        probeNode: (_) async => true,
        readDefaults: () async => (null, null),
        log: (_) {},
      );
      final oldSource = await aec.acquire();
      aec.release();
      final stopping = aec.stop();
      final reconnecting = aec.acquire();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(hosts, hasLength(1));
      hosts.first.exit();
      await stopping;
      final newSource = await reconnecting;
      expect(newSource, isNot(oldSource));
      expect(hosts, hasLength(2));
      expect(await File(configs.first).exists(), isFalse);
      expect(await File(configs.last).exists(), isTrue);
      aec.release();
      await aec.dispose();
    },
  );

  test('dispose during startup joins and stops the late process', () async {
    final gate = Completer<Process>();
    final launched = Completer<void>();
    final host = _Host();
    final aec = PipewireEchoCancel(
      instanceId: 'dispose',
      startHostProcess: (_) {
        launched.complete();
        return gate.future;
      },
      probeNode: (_) async => true,
      readDefaults: () async => (null, null),
      log: (_) {},
    );
    final acquiring = aec.acquire();
    await launched.future;
    final disposing = aec.dispose();
    gate.complete(host);
    expect(await acquiring, isNull);
    await disposing;
    expect(host.kills, greaterThan(0));
    expect(aec.running, isFalse);
  });

  test(
    'missing node after audio-server restart starts a new generation',
    () async {
      final hosts = <_Host>[];
      var oldNodeGone = false;
      final aec = PipewireEchoCancel(
        instanceId: 'server',
        startHostProcess: (_) async {
          final h = _Host();
          hosts.add(h);
          return h;
        },
        probeNode: (name) async => !oldNodeGone || name.endsWith('_1'),
        readDefaults: () async => (null, null),
        log: (_) {},
      );
      final old = await aec.acquire();
      oldNodeGone = true;
      final fresh = await aec.acquire();
      expect(fresh, isNot(old));
      expect(hosts, hasLength(2));
      expect(hosts.first.kills, greaterThan(0));
      aec.release();
      aec.release();
      await aec.dispose();
    },
  );

  test(
    'release during reconnect health check cannot stop its reserved user',
    () async {
      final host = _Host();
      var blockProbe = false;
      final checking = Completer<void>();
      final checked = Completer<bool>();
      final aec = PipewireEchoCancel(
        instanceId: 'reservation',
        linger: const Duration(milliseconds: 5),
        startHostProcess: (_) async => host,
        probeNode: (_) {
          if (!blockProbe) return Future.value(true);
          checking.complete();
          return checked.future;
        },
        readDefaults: () async => (null, null),
        log: (_) {},
      );
      final first = await aec.acquire();
      blockProbe = true;
      final reconnecting = aec.acquire();
      await checking.future;
      aec.release();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      checked.complete(true);
      expect(await reconnecting, first);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(host.kills, 0);
      expect(aec.running, isTrue);
      aec.release();
      await aec.dispose();
    },
  );

  test(
    'unexpected exit cleans old config before a replacement host starts',
    () async {
      final hosts = <_Host>[];
      final configs = <String>[];
      final aec = PipewireEchoCancel(
        instanceId: 'exit',
        startHostProcess: (path) async {
          configs.add(path);
          final host = _Host();
          hosts.add(host);
          return host;
        },
        probeNode: (_) async => true,
        readDefaults: () async => (null, null),
        log: (_) {},
      );
      final first = await aec.acquire();
      hosts.first.exit();
      await hosts.first.exitCode;
      await Future<void>.delayed(Duration.zero);
      final second = await aec.acquire();
      expect(second, isNot(first));
      expect(hosts, hasLength(2));
      expect(await File(configs.first).exists(), isFalse);
      expect(await File(configs.last).exists(), isTrue);
      aec.release();
      aec.release();
      await aec.dispose();
    },
  );
}
