import 'package:flutter_test/flutter_test.dart';
import 'package:woi/platform/files.dart';
import 'package:woi/platform/linux/linux_files.dart';

void main() {
  test('default workspace is the launch dir unless it is HOME or /', () {
    expect(defaultWorkspaceDir('/home/u', '/home/u/proj'), '/home/u/proj');
    expect(defaultWorkspaceDir('/home/u', '/home/u'), '/home/u');
    expect(defaultWorkspaceDir('/home/u', '/home/u/'), '/home/u');
    expect(defaultWorkspaceDir('/home/u', '/'), '/home/u');
    expect(defaultWorkspaceDir('/home/u', ''), '/home/u');
  });

  test('resolve expands ~ and \$HOME and joins relative paths to the workspace', () {
    final f = LocalFiles(homeDir: '/home/u', workspaceDir: '/work');
    expect(f.resolve('~'), '/home/u');
    expect(f.resolve('~/a.txt'), '/home/u/a.txt');
    expect(f.resolve(r'$HOME/a.txt'), '/home/u/a.txt');
    expect(f.resolve(r'${HOME}/b'), '/home/u/b');
    expect(f.resolve(r'$HOMEDIR/x'), '/work/\$HOMEDIR/x');
    expect(f.resolve('"~/q.txt"'), '/home/u/q.txt');
    expect(f.resolve('notes.txt'), '/work/notes.txt');
    expect(f.resolve('../x'), '/x');
    expect(f.resolve(''), '/work');
    expect(f.resolve('/etc/hosts'), '/etc/hosts');
  });
}
