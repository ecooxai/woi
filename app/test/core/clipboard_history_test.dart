import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/clipboard/clipboard_history.dart';
import 'package:woi/platform/clipboard_access.dart';

class _Clipboard implements ClipboardAccess, RichClipboardAccess {
  ClipboardContent? value;
  Object? error;
  Completer<ClipboardContent?>? gate;
  int reads = 0;
  int writes = 0;
  int activeReads = 0;
  int peakReads = 0;
  final focusRequests = <bool>[];
  bool? allowFocus;
  @override
  Future<ClipboardContent?> readContent({bool allowFocus = true}) async {
    reads++;
    this.allowFocus = allowFocus;
    focusRequests.add(allowFocus);
    activeReads++;
    if (activeReads > peakReads) peakReads = activeReads;
    try {
      if (error case final failure?) throw failure;
      return gate == null ? value : await gate!.future;
    } finally {
      activeReads--;
    }
  }

  @override
  Future<void> writeContent(ClipboardContent content) async {
    writes++;
    value = content;
  }

  @override
  Future<String?> readText() async => value?.text;
  @override
  Future<void> writeText(String text) => writeContent(ClipboardContent(text: text));
}

class _EventClipboard extends _Clipboard implements ClipboardChangeEvents {
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  @override
  bool get supportsBackgroundCapture => true;
}

class _DelayedLoadHistory extends ClipboardHistoryController {
  _DelayedLoadHistory({required super.clipboard, required super.directory});
  final loaded = Completer<void>();
  @override
  Future<void> load() => loaded.future;
}

Future<void> _until(bool Function() ready) async {
  final limit = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(limit)) fail('Clipboard operation did not settle.');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory root;
  late _Clipboard clipboard;
  final controllers = <ClipboardHistoryController>[];
  ClipboardHistoryController history({
    int maxEntries = 50,
    int maxBytes = 32 * 1024 * 1024,
    Duration pollInterval = const Duration(seconds: 2),
  }) {
    final result = ClipboardHistoryController(
      clipboard: clipboard,
      directory: root,
      maxEntries: maxEntries,
      maxBytes: maxBytes,
      pollInterval: pollInterval,
    );
    controllers.add(result);
    return result;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('woi-history-');
    clipboard = _Clipboard();
  });
  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
      await controller.flush();
    }
    controllers.clear();
    if (clipboard is _EventClipboard) await (clipboard as _EventClipboard).events.close();
    await root.delete(recursive: true);
  });

  test('text and image snapshots survive restart with exact bytes and names', () async {
    final first = history();
    await first.remember(const ClipboardContent(text: 'first\nline two'));
    final bytes = Uint8List.fromList([137, 80, 78, 71, 0, 255, 18]);
    final image = await first.remember(
      ClipboardContent(
        image: ClipboardImage(bytes: bytes, mimeType: 'image/png', name: 'screen copy.png'),
      ),
    );
    bytes[0] = 0;
    expect(image.content.image!.bytes[0], 137, reason: 'The source buffer cannot mutate history.');
    final restarted = history();
    await restarted.load();
    expect(restarted.entries.map((item) => item.id), first.entries.map((item) => item.id));
    expect(restarted.entries.first.content.image!.bytes, [137, 80, 78, 71, 0, 255, 18]);
    expect(restarted.entries.first.content.image!.name, 'screen copy.png');
    expect(restarted.entries.last.content.text, 'first\nline two');
    expect(restarted.error, isNull);
  });

  test('deduplicates actual contents and moves a copied item to the newest position', () async {
    final h = history();
    final a = await h.remember(const ClipboardContent(text: 'A'));
    await h.remember(const ClipboardContent(text: 'B'));
    final newerA = await h.remember(const ClipboardContent(text: 'A'));
    expect(newerA.id, a.id);
    expect(h.entries.map((item) => item.content.text), ['A', 'B']);
    expect(newerA.copiedAt.isBefore(a.copiedAt), isFalse);
    final bytes = Uint8List.fromList([1, 2, 3]);
    final one = await h.remember(
      ClipboardContent(
        image: ClipboardImage(bytes: bytes, name: 'one.png'),
      ),
    );
    final two = await h.remember(
      ClipboardContent(
        image: ClipboardImage(bytes: bytes, name: 'renamed.png'),
      ),
    );
    expect(one.id, two.id, reason: 'Changing a filename does not duplicate the same image.');
    expect(h.entries.length, 3);
  });

  test('Copy acts on the selected image after system clipboard has changed', () async {
    final h = history();
    final selected = await h.remember(
      ClipboardContent(
        image: ClipboardImage(bytes: Uint8List.fromList([1, 2, 3]), name: 'selected.png'),
      ),
    );
    clipboard.value = const ClipboardContent(text: 'Something newer');
    await h.capture();
    await h.copy(selected);
    expect(clipboard.writes, 1);
    expect(clipboard.value!.image!.name, 'selected.png');
    expect(clipboard.value!.image!.bytes, [1, 2, 3]);
    expect(clipboard.value!.text, isNull);
    expect(h.entries.first.id, selected.id);
    expect(h.entries.last.content.text, 'Something newer');
  });

  test('retention honors item and byte limits; oversize rejection preserves saved entries', () async {
    final h = history(maxEntries: 2, maxBytes: 8);
    await h.remember(const ClipboardContent(text: 'one'));
    await h.remember(const ClipboardContent(text: 'two'));
    await h.remember(const ClipboardContent(text: 'three'));
    expect(h.entries.map((item) => item.content.text), ['three', 'two']);
    expect(h.totalBytes, 8);
    await expectLater(h.remember(const ClipboardContent(text: 'far too large')), throwsStateError);
    expect(h.entries.map((item) => item.content.text), ['three', 'two']);
    final restarted = history(maxEntries: 2, maxBytes: 8);
    await restarted.load();
    expect(restarted.entries.length, 2);
  });

  test('background capture never asks for focus and access denial retains history', () async {
    final h = history();
    await h.remember(const ClipboardContent(text: 'retained'));
    clipboard.error = StateError('Android clipboard access needs Woi in the foreground');
    expect(await h.capture(allowFocus: false), isNull);
    expect(clipboard.allowFocus, isFalse);
    expect(h.entries.single.content.text, 'retained');
    expect(h.error, contains('foreground'));
    clipboard.error = null;
    clipboard.value = const ClipboardContent(text: 'allowed now');
    expect((await h.capture())!.content.text, 'allowed now');
    expect(clipboard.allowFocus, isTrue);
    expect(h.error, isNull);
  });

  test('overlapping captures share the read and add one snapshot', () async {
    final h = history();
    await h.load();
    clipboard.gate = Completer<ClipboardContent?>();
    final first = h.capture(allowFocus: false);
    final second = h.capture(allowFocus: false);
    await Future<void>.delayed(Duration.zero);
    expect(clipboard.reads, 1);
    clipboard.gate!.complete(const ClipboardContent(text: 'single capture'));
    await Future.wait([first, second]);
    expect(h.entries.single.content.text, 'single capture');
    expect(h.capturing, isFalse);
  });

  test('remove and clear do not modify the system clipboard or re-add unchanged data', () async {
    final h = history();
    clipboard.value = const ClipboardContent(text: 'keep on clipboard');
    await h.capture();
    await h.remove(h.entries.single.id);
    await h.capture(allowFocus: false);
    expect(h.entries, isEmpty);
    expect(clipboard.value!.text, 'keep on clipboard');
    expect(clipboard.writes, 0);
    await h.capture();
    expect(h.entries.length, 1, reason: 'Explicit Capture can save an unchanged item again.');
    await h.clear();
    final restarted = history();
    await restarted.load();
    expect(restarted.entries, isEmpty);
  });

  test('reload enforces the current entry cap and durably trims the index', () async {
    final original = history(maxEntries: 100);
    for (var i = 0; i < 8; i++) {
      await original.remember(ClipboardContent(text: 'saved $i'));
    }
    final bounded = history(maxEntries: 3);
    await bounded.load();
    expect(bounded.entries.map((entry) => entry.content.text), ['saved 7', 'saved 6', 'saved 5']);
    final index = jsonDecode(await File('${root.path}/history.json').readAsString()) as Map;
    expect(index['entries'] as List, hasLength(3));
    final again = history(maxEntries: 3);
    await again.load();
    expect(again.entries, hasLength(3));
    expect(again.error, isNull, reason: 'Reload does not repeat an already repaired index warning.');
  });

  test('reload bounds aggregate bytes before loading images and removes pruned image files', () async {
    final original = history(maxBytes: 64);
    final text = await original.remember(const ClipboardContent(text: 'old'));
    final pruned = await original.remember(
      ClipboardContent(
        image: ClipboardImage(bytes: Uint8List.fromList([1, 2, 3, 4, 5]), name: 'too-much.png'),
      ),
    );
    final newest = await original.remember(
      ClipboardContent(
        image: ClipboardImage(bytes: Uint8List.fromList([6, 7, 8, 9]), name: 'newest.png'),
      ),
    );
    final bounded = history(maxBytes: 8);
    await bounded.load();
    expect(bounded.entries.map((entry) => entry.id), [newest.id, text.id]);
    expect(bounded.totalBytes, 7);
    expect(await File('${root.path}/${pruned.id}.image').exists(), isFalse);
    expect(await File('${root.path}/${newest.id}.image').exists(), isTrue);
    expect(bounded.error, contains('trimmed'));
  });

  test('streamed digest preserves v1 identity and saved image buffers cannot be mutated', () async {
    final bytes = Uint8List.fromList(List.generate(4096, (index) => index % 256));
    const text = 'Unicode ☃ and 🧪 with a null \u0000 and newline\n';
    final expected = sha256.convert([...utf8.encode(text), 0, ...bytes]).toString();
    final h = history();
    final entry = await h.remember(
      ClipboardContent(
        text: text,
        image: ClipboardImage(bytes: bytes),
      ),
    );
    expect(entry.id, expected);
    expect(() => entry.content.image!.bytes[0] = 9, throwsUnsupportedError);
    final restarted = history();
    await restarted.load();
    expect(restarted.entries.single.id, expected);
    expect(() => restarted.entries.single.content.image!.bytes[0] = 9, throwsUnsupportedError);
  });

  test('unchanged image capture reuses the saved snapshot and does not rewrite its index', () async {
    final h = history();
    clipboard.value = ClipboardContent(image: ClipboardImage(bytes: Uint8List.fromList([1, 2, 3])));
    final first = await h.capture(allowFocus: false);
    final index = File('${root.path}/history.json');
    final before = await index.readAsString();
    for (var i = 0; i < 3; i++) {
      expect(identical(await h.capture(allowFocus: false), first), isTrue);
    }
    expect(clipboard.reads, 4);
    expect(await index.readAsString(), before);
    expect(h.entries, hasLength(1));
  });

  test('successful empty clipboard read clears a previous access error without losing history', () async {
    final h = history();
    await h.remember(const ClipboardContent(text: 'saved'));
    clipboard.error = StateError('access denied');
    await h.capture();
    expect(h.error, contains('access denied'));
    clipboard.error = null;
    clipboard.value = null;
    expect(await h.capture(), isNull);
    expect(h.error, isNull);
    expect(h.entries.single.content.text, 'saved');
  });

  test('native changes capture immediately and unchanged events reuse the saved item', () async {
    final source = _EventClipboard();
    clipboard = source;
    final h = history(pollInterval: const Duration(hours: 1));
    h.setActive(true);
    await _until(() => source.reads == 1 && !h.capturing);
    source.value = const ClipboardContent(text: 'rapid A');
    source.events.add(null);
    await _until(() => h.entries.isNotEmpty && !h.capturing);
    source.value = const ClipboardContent(text: 'rapid B');
    source.events.add(null);
    await _until(() => h.entries.length == 2 && !h.capturing);
    final newest = h.entries.first;
    source.events.add(null);
    await _until(() => source.reads == 4 && !h.capturing);
    expect(h.entries.map((entry) => entry.content.text), ['rapid B', 'rapid A']);
    expect(identical(h.entries.first, newest), isTrue);
    expect(source.focusRequests, everyElement(isFalse));
    expect(h.supportsBackgroundCapture, isTrue);
  });

  test('events during a native read queue one latest follow-up without overlapping reads', () async {
    final source = _EventClipboard();
    clipboard = source;
    final h = history(pollInterval: const Duration(hours: 1));
    final gate = source.gate = Completer<ClipboardContent?>();
    h.setActive(true);
    await _until(() => source.reads == 1);
    source.gate = null;
    source.value = const ClipboardContent(text: 'latest B');
    source.events.add(null);
    source.events.add(null);
    expect(source.reads, 1);
    gate.complete(const ClipboardContent(text: 'in-flight A'));
    await _until(() => h.entries.length == 2 && !h.capturing);
    expect(source.reads, 2);
    expect(source.peakReads, 1);
    expect(h.entries.map((entry) => entry.content.text), ['latest B', 'in-flight A']);
  });

  test('explicit capture waits for a fresh focused read after a passive capture', () async {
    final h = history();
    await h.load();
    final gate = clipboard.gate = Completer<ClipboardContent?>();
    final passive = h.capture(allowFocus: false);
    await _until(() => clipboard.reads == 1);
    final explicit = h.capture();
    clipboard.gate = null;
    clipboard.value = const ClipboardContent(text: 'fresh explicit');
    gate.complete(const ClipboardContent(text: 'older passive'));
    expect((await passive)!.content.text, 'older passive');
    expect((await explicit)!.content.text, 'fresh explicit');
    expect(clipboard.focusRequests, [false, true]);
    expect(clipboard.peakReads, 1);
  });

  test('deactivation cancels events and queued work; reactivation reads the current clipboard once', () async {
    final source = _EventClipboard();
    clipboard = source;
    final h = history(pollInterval: const Duration(hours: 1));
    final gate = source.gate = Completer<ClipboardContent?>();
    h.setActive(true);
    await _until(() => source.reads == 1);
    source.value = const ClipboardContent(text: 'on return');
    source.events.add(null);
    h.setActive(false);
    expect(source.events.hasListener, isFalse);
    source.gate = null;
    gate.complete(const ClipboardContent(text: 'started before leaving'));
    await _until(() => !h.capturing);
    source.events.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(source.reads, 1);
    h.setActive(true);
    h.setActive(true);
    await _until(() => h.entries.length == 2 && !h.capturing);
    expect(source.reads, 2);
    expect(h.entries.first.content.text, 'on return');
  });

  test('dispose cancels notifications and discards an in-flight snapshot and queued follow-up', () async {
    final source = _EventClipboard();
    clipboard = source;
    final h = history(pollInterval: const Duration(hours: 1));
    final gate = source.gate = Completer<ClipboardContent?>();
    var notices = 0;
    h.addListener(() => notices++);
    h.setActive(true);
    await _until(() => source.reads == 1);
    source.events.add(null);
    h.dispose();
    controllers.remove(h);
    final before = notices;
    expect(source.events.hasListener, isFalse);
    gate.complete(const ClipboardContent(text: 'too late'));
    await _until(() => !h.capturing);
    source.events.add(null);
    expect(await h.capture(), isNull);
    expect(h.entries, isEmpty);
    expect(source.reads, 1);
    expect(notices, before);
  });

  test('dispose during loading never starts native clipboard access', () async {
    final h = _DelayedLoadHistory(clipboard: clipboard, directory: root);
    final capture = h.capture(allowFocus: false);
    h.dispose();
    h.loaded.complete();
    expect(await capture, isNull);
    expect(clipboard.reads, 0);
  });

  test('a new native event recovers after access denial without losing older history', () async {
    final source = _EventClipboard();
    clipboard = source;
    final h = history(pollInterval: const Duration(hours: 1));
    await h.remember(const ClipboardContent(text: 'retained'));
    source.error = StateError('temporarily denied');
    h.setActive(true);
    await _until(() => h.error != null && !h.capturing);
    expect(h.entries.single.content.text, 'retained');
    source.error = null;
    source.value = const ClipboardContent(text: 'available again');
    source.events.add(null);
    await _until(() => h.entries.length == 2 && !h.capturing);
    expect(h.error, isNull);
    expect(source.focusRequests, everyElement(isFalse));
  });

  for (final withEvents in [false, true]) {
    test(
      'polling backstop captures when ${withEvents ? 'the native stream is silent' : 'events are unsupported'}',
      () async {
        if (withEvents) clipboard = _EventClipboard();
        final h = history(pollInterval: const Duration(milliseconds: 25));
        h.setActive(true);
        await _until(() => clipboard.reads > 0 && !h.capturing);
        clipboard.value = const ClipboardContent(text: 'captured by timer');
        await _until(() => h.entries.isNotEmpty && !h.capturing);
        h.setActive(false);
        expect(h.entries.single.content.text, 'captured by timer');
        expect(clipboard.focusRequests, everyElement(isFalse));
        final stoppedAt = clipboard.reads;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(clipboard.reads, stoppedAt);
      },
    );
  }

  test('notification stream errors retain the polling backstop', () async {
    final source = _EventClipboard();
    clipboard = source;
    final h = history(pollInterval: const Duration(milliseconds: 25));
    h.setActive(true);
    await _until(() => source.reads > 0 && !h.capturing);
    source.events.addError(StateError('native stream unavailable'));
    source.value = const ClipboardContent(text: 'polling recovered');
    await _until(() => h.entries.isNotEmpty && !h.capturing);
    expect(h.entries.single.content.text, 'polling recovered');
    expect(h.error, isNull);
  });
}
