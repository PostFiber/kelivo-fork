import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/services/workspace/host_file_tools.dart';
import 'package:Kelivo/core/services/workspace/workspace_paths.dart';
import 'package:Kelivo/core/services/workspace/workspace_runtime.dart';

void main() {
  late Directory root;
  late WorkspacePaths paths;
  late List<Mount> mounts;
  const guest = '/root/My Notes';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('kelivo_mounts_');
    for (final dir in ['ws', 'chat', 'skills', 'external', 'output']) {
      Directory('${root.path}/$dir').createSync();
    }
    mounts = [
      Mount(host: '${root.path}/external', guest: guest, readOnly: true),
      Mount(host: '${root.path}/output', guest: '/opt/Output'),
    ];
    paths = WorkspacePaths.sandboxed(
      workspaceHostRoot: '${root.path}/ws',
      sessionHostDir: '${root.path}/chat',
      skillsHostDir: '${root.path}/skills',
      externalMounts: mounts,
      loadExternalMounts: () async => mounts,
    );
    File('${root.path}/external/note.txt').writeAsStringSync('original');
  });
  tearDown(() => root.delete(recursive: true));

  test('maps multiple external roots and preserves the workspace', () async {
    final resolved = paths.resolve('$guest/note.txt', cwd: '/workspace');
    expect(resolved.zone, WorkspaceZone.external);
    expect(paths.toModelPath(resolved.hostPath), '$guest/note.txt');
    expect(paths.modelRoot, '/workspace');
    expect(paths.resolve('note.txt', cwd: guest).hostPath, resolved.hostPath);
    expect(paths.mounts, hasLength(6));
    final result = await HostFileTools(paths).listDir(guest, depth: 2);
    expect(result.entries.map((e) => e.path), contains('$guest/note.txt'));
    // Only the four zones and the mount roots are addressable: a mount's own
    // parent is not, which is why the prompt spells the mount paths out.
    for (final outside in ['/root', '/root/Missing/file', '/opt']) {
      expect(
        () => paths.resolve(outside, cwd: '/workspace'),
        throwsA(isA<PathResolutionException>()),
        reason: outside,
      );
    }
    expect(
      () => paths.resolve('$guest/../Output/file', cwd: '/workspace'),
      throwsA(isA<PathResolutionException>()),
    );
  });

  test(
    'read-only denies edits, new files and symlink aliases; reads and writable mounts work',
    () async {
      final tools = HostFileTools(paths);
      expect(
        (await tools.readFile('$guest/note.txt')).text,
        contains('original'),
      );
      await expectLater(
        tools.writeFile('$guest/new.txt', 'bad'),
        throwsA(isA<HostFileException>()),
      );
      await expectLater(
        tools.editFile('$guest/note.txt', 'original', 'bad'),
        throwsA(isA<HostFileException>()),
      );
      Link('${root.path}/ws/alias').createSync('${root.path}/external');
      await expectLater(
        tools.writeFile('/workspace/alias/note.txt', 'bad'),
        throwsA(isA<HostFileException>()),
      );
      expect(
        File('${root.path}/external/note.txt').readAsStringSync(),
        'original',
      );
      await tools.writeFile('/opt/Output/result.txt', 'ok');
      expect(File('${root.path}/output/result.txt').readAsStringSync(), 'ok');
    },
  );

  test(
    'existing tools refresh permission changes and fail closed after unmount',
    () async {
      final tools = HostFileTools(paths);
      mounts = [Mount(host: '${root.path}/external', guest: guest)];
      await tools.writeFile('$guest/note.txt', 'allowed');
      mounts = [
        Mount(host: '${root.path}/external', guest: guest, readOnly: true),
      ];
      await expectLater(
        tools.writeFile('$guest/note.txt', 'bad'),
        throwsA(isA<HostFileException>()),
      );
      mounts = [];
      await expectLater(
        tools.listDir(guest),
        throwsA(isA<PathResolutionException>()),
      );
      await expectLater(
        tools.readFile('$guest/note.txt'),
        throwsA(isA<PathResolutionException>()),
      );
      expect(
        File('${root.path}/external/note.txt').readAsStringSync(),
        'allowed',
      );
    },
  );
}
