import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:woi/core/edits/edit_review.dart';
import 'package:woi/core/notes/note_controller.dart';
import 'package:woi/core/notes/note_store.dart';
import 'package:woi/core/notes/note_text_ops.dart';
import 'package:woi/core/settings/settings.dart';
import 'package:woi/platform/linux/linux_files.dart';

import 'fakes/fakes.dart';

PendingEdit _edit({String newText = 'b\n', bool approval = false}) =>
    PendingEdit(target: EditTarget.note, title: 'Note', oldText: 'a\n', newText: newText, requireApproval: approval);

void main() {
  group('EditReview countdown', () {
    test('auto-applies after the delay (fake clock)', () {
      fakeAsync((fa) {
        final start = DateTime(2026, 1, 1);
        final r = EditReview(delaySeconds: () => 5, now: () => start.add(fa.elapsed));
        bool? result;
        r.review(_edit()).then((v) => result = v);
        fa.flushMicrotasks();
        expect(r.hasPending, isTrue);
        expect(r.remaining(), const Duration(seconds: 5));
        fa.elapse(const Duration(milliseconds: 4900));
        expect(result, isNull);
        expect(r.remaining(), const Duration(milliseconds: 100));
        fa.elapse(const Duration(milliseconds: 200));
        expect(result, isTrue);
        expect(r.hasPending, isFalse);
      });
    });

    test('reject before the deadline; queued edit starts its own countdown', () {
      fakeAsync((fa) {
        final start = DateTime(2026, 1, 1);
        final r = EditReview(delaySeconds: () => 3, now: () => start.add(fa.elapsed));
        bool? a, b;
        r.review(_edit(newText: 'x\n')).then((v) => a = v);
        fa.elapse(const Duration(seconds: 1));
        r.review(_edit(newText: 'y\n')).then((v) => b = v);
        expect(r.pendingCount, 2);
        expect(r.reject(), isTrue);
        fa.flushMicrotasks();
        expect(a, isFalse);
        expect(r.current!.newText, 'y\n');
        expect(r.remaining(), const Duration(seconds: 3));
        fa.elapse(const Duration(seconds: 3));
        expect(b, isTrue);
      });
    });

    test('apply now, delay 0 and require approval', () {
      fakeAsync((fa) {
        var delay = 0;
        final r = EditReview(delaySeconds: () => delay);
        bool? v0;
        r.review(_edit()).then((v) => v0 = v);
        fa.flushMicrotasks();
        expect(v0, isTrue);
        expect(r.hasPending, isFalse);

        delay = kRequireApproval;
        bool? v1;
        r.review(_edit()).then((v) => v1 = v);
        fa.elapse(const Duration(minutes: 5));
        expect(v1, isNull);
        expect(r.remaining(), isNull);
        expect(r.apply(), isTrue);
        fa.flushMicrotasks();
        expect(v1, isTrue);

        delay = 5; // a destructive edit never counts down
        bool? v2;
        r.review(_edit(newText: '', approval: true)).then((v) => v2 = v);
        fa.elapse(const Duration(seconds: 30));
        expect(v2, isNull);
        r.rejectAll();
        fa.flushMicrotasks();
        expect(v2, isFalse);
        expect(r.apply(), isFalse);
      });
    });
  });

  group('file edit undo', () {
    late Directory dir;
    late FakePlatform fp;
    late NoteController notes;
    late EditHistory history;
    late EditReview review;
    late ReviewingConfirmations conf;
    late LocalFiles files;

    setUp(() async {
      fp = await FakePlatform.create();
      dir = Directory('${fp.root.path}/ws')..createSync();
      notes = NoteController(store: NoteStore('${fp.root.path}/data'));
      await notes.open('conv1');
      review = EditReview(delaySeconds: () => 0);
      history = EditHistory(backupRoot: '${fp.root.path}/backups', notes: notes, conversationId: () => 'conv1');
      conf = ReviewingConfirmations(inner: FakeConfirmations(), review: review, history: history);
      files = LocalFiles(homeDir: fp.root.path);
    });
    tearDown(() async {
      review.dispose();
      notes.dispose();
      await fp.dispose();
    });

    test('backs up before the write and restores on undo', () async {
      final f = File('${dir.path}/a.txt')..writeAsStringSync('one\n');
      final out = await files.write(f.path, 'two\n', approve: conf.confirmFileWrite);
      expect(out.written, isTrue);
      expect(f.readAsStringSync(), 'two\n');
      final last = history.last as AppliedFileEdit;
      expect(File(last.backupPath!).readAsStringSync(), 'one\n');
      expect(last.backupPath, contains('/backups/conv1/'));
      expect(await history.undoLast(), contains('restored'));
      expect(f.readAsStringSync(), 'one\n');
      expect(history.last, isNull);
      expect(await history.undoLast(), isNull);
    });

    test('undo of a created file deletes it; a rejected write leaves no trace', () async {
      final f = File('${dir.path}/new.txt');
      await files.write(f.path, 'hello\n', approve: conf.confirmFileWrite);
      expect(f.existsSync(), isTrue);
      expect(await history.undoLast(), contains('removed'));
      expect(f.existsSync(), isFalse);

      final g = File('${dir.path}/b.txt')..writeAsStringSync('keep\n');
      final r2 = EditReview(delaySeconds: () => kRequireApproval);
      final c2 = ReviewingConfirmations(inner: FakeConfirmations(), review: r2, history: history);
      final pending = files.write(g.path, 'gone\n', approve: c2.confirmFileWrite);
      for (var i = 0; i < 200 && !r2.hasPending; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(r2.current?.title, g.path);
      expect(r2.reject(), isTrue);
      final out = await pending;
      expect(out.written, isFalse);
      expect(g.readAsStringSync(), 'keep\n');
      expect(history.last, isNull);
      r2.dispose();
    });

    test('history is per conversation', () async {
      var conv = 'conv1';
      final h = EditHistory(backupRoot: '${fp.root.path}/bk', notes: notes, conversationId: () => conv);
      h.record(AppliedFileEdit('conv1', 'x', path: '/tmp/none'));
      conv = 'conv2';
      expect(h.last, isNull);
      conv = 'conv1';
      expect(h.last, isNotNull);
    });
  });

  group('parseEditCommand', () {
    test('apply / reject only while pending; undo always', () {
      expect(parseEditCommand('apply', pending: true), EditVoiceCommand.apply);
      expect(parseEditCommand('OK, apply it.', pending: true), EditVoiceCommand.apply);
      expect(parseEditCommand('looks good', pending: true), EditVoiceCommand.apply);
      expect(parseEditCommand('cancel', pending: true), EditVoiceCommand.reject);
      expect(parseEditCommand('reject that', pending: true), EditVoiceCommand.reject);
      expect(parseEditCommand('cancel', pending: false), isNull);
      expect(parseEditCommand('apply', pending: false), isNull);
      expect(parseEditCommand('undo that', pending: false), EditVoiceCommand.undo);
      expect(parseEditCommand('oops, undo your last edit', pending: false), EditVoiceCommand.undo);
      expect(parseEditCommand('apply the patch to main.dart', pending: true), isNull);
      expect(parseEditCommand('undo the git commit', pending: false), isNull);
    });
  });

  group('note text ops', () {
    const note = '# Shopping\n- eggs\n- buy milk today\n\n## Ideas\n- a\n';
    test('insert after / before / top', () {
      expect(insertNoteText(note, '- bread', after: 'eggs').text, '# Shopping\n- eggs\n- bread\n- buy milk today\n\n## Ideas\n- a\n');
      expect(insertNoteText(note, '- z', before: 'ideas').text, contains('\n- z\n## Ideas'));
      expect(insertNoteText('x', 'top').text, 'top\nx');
      expect(() => insertNoteText(note, 'q', after: 'nope'), throwsA(isA<Exception>()));
    });
    test('replace and delete', () {
      expect(replaceNoteText(note, 'EGGS', 'apples').text, contains('- apples\n'));
      expect(replaceNoteText('a a a', 'a', 'b', all: true).text, 'b b b');
      expect(deleteNoteText(note, 'buy milk today').text, '# Shopping\n- eggs\n\n## Ideas\n- a\n');
      expect(deleteNoteText(note, 'today').text, contains('- buy milk\n'));
      expect(deleteNoteText('a\nlast', 'last').text, 'a');
    });
  });
}
