import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/extension_entity_store.dart';
import 'package:Kelivo/core/models/external_mount.dart';
import 'package:Kelivo/core/models/workspace_directory_access.dart';
import 'package:Kelivo/core/providers/external_mounts_provider.dart';
import 'package:Kelivo/core/services/sandbox/workspace_channel.dart';
import '../services/sandbox/sandbox_channel_harness.dart';

Matcher rejects(String code) => throwsA(
  isA<WorkspaceChannelException>().having((error) => error.code, 'code', code),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ExtensionEntityStore store;
  late SandboxChannelHarness harness;
  late ExternalMountsProvider provider;
  late Map<String, String> sources;
  late List<Map<dynamic, dynamic>> native;
  late String? rootfs;
  late List<String> reserved;
  late List<String> released;
  var failNextMount = false;

  WorkspaceDirectory directory(String token) => WorkspaceDirectory(
    path: sources[token]!,
    access: WorkspaceDirectoryAccess(platform: 'android', token: token),
  );

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    db = AppDatabase(NativeDatabase.memory());
    store = ExtensionEntityStore(db);
    sources = {'a': '/storage/A', 'b': '/storage/B'};
    native = [];
    rootfs = null;
    reserved = [];
    released = [];
    failNextMount = false;
    harness = SandboxChannelHarness();
    harness.handler = (call) {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'resolveDirectory':
          final token = args['token'] as String;
          if (!sources.containsKey(token)) {
            throw PlatformException(code: 'external_folder_unavailable');
          }
          return {'path': sources[token], 'token': token};
        case 'setExternalMounts':
          if (failNextMount) {
            failNextMount = false;
            throw PlatformException(code: 'mount_failed');
          }
          native = [for (final item in args['mounts'] as List) item as Map];
          rootfs = args['rootfsDir'] as String?;
          reserved = (args['reservedPaths'] as List).cast<String>();
          return null;
        case 'releaseDirectory':
          released.add(args['token'] as String);
          return null;
      }
      return null;
    };
    harness.install();
    provider = ExternalMountsProvider(store: store, channel: harness.channel);
    await provider.loaded;
  });

  tearDown(() async {
    provider.dispose();
    harness.dispose();
    await db.close();
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'mounts are independent, persistent, path-addressed and individually writable',
    () async {
      await provider.add(
        directory('a'),
        guestPath: '/root/Notes',
        readOnly: true,
      );
      await provider.add(
        directory('b'),
        guestPath: '/opt/data',
        readOnly: false,
      );
      expect(native.map((m) => m['guest']), ['/root/Notes', '/opt/data']);
      expect(native.first['readOnly'], true);
      expect(native.last['readOnly'], isNot(true));
      // Without a known rootfs the native side cannot check mount targets.
      expect(rootfs, isNull);
      // The reserved-path policy travels with the mounts; the runners apply it.
      expect(reserved, ExternalMount.reservedGuestPaths);
      expect(
        await store.listByKind(ExtensionEntityStore.kindWorkspace),
        isEmpty,
      );
      provider.dispose();
      provider = ExternalMountsProvider(store: store, channel: harness.channel);
      await provider.loaded;
      expect(provider.entries.map((m) => m.guestPath), [
        '/root/Notes',
        '/opt/data',
      ]);
      expect(provider.entries.map((m) => m.name), ['Notes', 'data']);
      expect(provider.activeMounts.first.readOnly, true);
    },
  );

  test('reports the rootfs location so targets can be checked', () async {
    provider.dispose();
    provider = ExternalMountsProvider(
      store: store,
      channel: harness.channel,
      rootfsDir: () => '/data/kelivo/rootfs',
    );
    await provider.loaded;
    await provider.add(
      directory('a'),
      guestPath: '/root/Notes',
      readOnly: false,
    );
    expect(rootfs, '/data/kelivo/rootfs');
  });

  test(
    'rename and toggle replace native snapshot; unmount releases only its grant',
    () async {
      await provider.add(
        directory('a'),
        guestPath: '/root/Notes',
        readOnly: false,
      );
      await provider.add(
        directory('b'),
        guestPath: '/opt/data',
        readOnly: false,
      );
      final id = provider.entries.first.id;
      await provider.update(id, guestPath: '/srv/reference', readOnly: true);
      expect(native.first['guest'], '/srv/reference');
      expect(native.first['readOnly'], true);
      expect(released, isEmpty);
      await provider.remove(id);
      expect(native.single['guest'], '/opt/data');
      expect(released, ['a']);
      expect(sources['a'], '/storage/A');
    },
  );

  test('revoked access removes live binding and can be reselected', () async {
    await provider.add(
      directory('a'),
      guestPath: '/root/Notes',
      readOnly: true,
    );
    final id = provider.entries.single.id;
    sources.remove('a');
    expect(await provider.resolveMounts(), isEmpty);
    expect(native, isEmpty);
    expect(provider.entries, hasLength(1));
    expect(provider.errorFor(id), isNotNull);
    await provider.update(
      id,
      guestPath: '/root/Notes',
      readOnly: true,
      directory: directory('b'),
    );
    expect(native.single['host'], '/storage/B');
    expect(provider.errorFor(id), isNull);
    expect(released, ['a']);
  });

  test(
    'failed runtime update rolls back the registry and persisted permission',
    () async {
      await provider.add(
        directory('a'),
        guestPath: '/root/Notes',
        readOnly: true,
      );
      failNextMount = true;
      await expectLater(
        provider.update(
          provider.entries.single.id,
          guestPath: '/root/Changed',
          readOnly: false,
        ),
        throwsA(isA<WorkspaceChannelException>()),
      );
      expect(provider.entries.single.guestPath, '/root/Notes');
      expect(provider.entries.single.readOnly, true);
      expect(native.single['readOnly'], true);
      final stored = await store.get(ExternalMountsProvider.kind, 'global');
      expect(
        (stored!.payload['mounts'] as List).single['guestPath'],
        '/root/Notes',
      );
      expect(released, isEmpty);
    },
  );

  test('moved folders stay manageable when saved mounts now overlap', () async {
    sources['c'] = '/storage/C';
    await provider.add(directory('a'), guestPath: '/root/A', readOnly: false);
    await provider.add(directory('b'), guestPath: '/root/B', readOnly: true);
    await provider.add(directory('c'), guestPath: '/root/C', readOnly: false);
    final a = provider.entries[0].id;
    final b = provider.entries[1].id;
    final c = provider.entries[2].id;
    provider.dispose();
    sources['b'] = '/storage/A/B';
    sources['c'] = '/storage/A/C';
    provider = ExternalMountsProvider(store: store, channel: harness.channel);
    await provider.loaded;
    expect(provider.entries, hasLength(3));
    expect(native, isEmpty);
    for (final id in [a, b, c]) {
      expect(provider.errorFor(id), contains('external_mount_overlap'));
    }
    // Removing one conflict must work even while another remains.
    await provider.remove(b);
    expect(provider.entries, hasLength(2));
    expect(native, isEmpty);
    sources['new'] = '/storage/New';
    await provider.update(
      c,
      guestPath: '/root/C',
      readOnly: false,
      directory: directory('new'),
    );
    expect(native.map((m) => m['host']), ['/storage/A', '/storage/New']);
    expect(provider.errorFor(a), isNull);
    expect(provider.errorFor(c), isNull);
  });

  test('application writes check symlinks and parents of new files', () async {
    final root = await Directory.systemTemp.createTemp('kelivo-mount-guard-');
    addTearDown(() => root.delete(recursive: true));
    final locked = Directory('${root.path}/locked')..createSync();
    final writable = Directory('${root.path}/writable')..createSync();
    sources['a'] = locked.path;
    sources['b'] = writable.path;
    await provider.add(
      directory('a'),
      guestPath: '/root/locked',
      readOnly: true,
    );
    await provider.add(
      directory('b'),
      guestPath: '/root/writable',
      readOnly: false,
    );
    Link('${writable.path}/alias').createSync(locked.path);
    await expectLater(
      provider.requireWritableHostPaths(['${writable.path}/alias/sub/new.txt']),
      throwsA(isA<WorkspaceChannelException>()),
    );
    await provider.requireWritableHostPaths(['${writable.path}/new.txt']);
    await provider.update(
      provider.entries.first.id,
      guestPath: '/root/locked',
      readOnly: false,
    );
    await provider.requireWritableHostPaths([
      '${writable.path}/alias/sub/new.txt',
    ]);
  });

  test('rejects unusable guest paths', () async {
    await provider.add(
      directory('a'),
      guestPath: '/root/Notes',
      readOnly: true,
    );
    for (final path in [
      'root/Notes', // relative
      '/root/Notes/', // trailing slash
      '/root/../Notes', // not normalized
      '/root/./Notes', // not normalized
      '/root//Notes', // empty segment
      '/root/No:tes', // PRoot's own -b delimiter
      '/', // the guest root
      '', // empty
    ]) {
      await expectLater(
        provider.add(directory('b'), guestPath: path, readOnly: false),
        rejects('external_mount_name'),
        reason: path,
      );
    }
    for (final path in ['/workspace', '/proc', '/dev/pts', '/etc/nginx']) {
      await expectLater(
        provider.add(directory('b'), guestPath: path, readOnly: false),
        rejects('external_mount_reserved'),
        reason: path,
      );
    }
    expect(provider.entries, hasLength(1));
  });

  test('rejects duplicate and nested mounts', () async {
    await provider.add(
      directory('a'),
      guestPath: '/root/Notes',
      readOnly: true,
    );
    await expectLater(
      provider.add(directory('b'), guestPath: '/root/Notes', readOnly: false),
      rejects('external_mount_duplicate'),
    );
    await expectLater(
      provider.add(directory('b'), guestPath: '/ROOT/notes', readOnly: false),
      rejects('external_mount_duplicate'),
    );
    for (final path in ['/root/Notes/inner', '/root']) {
      await expectLater(
        provider.add(directory('b'), guestPath: path, readOnly: false),
        rejects('external_mount_overlap'),
        reason: path,
      );
    }
    // Renaming onto another mount's path is rejected too.
    await provider.add(directory('b'), guestPath: '/opt/data', readOnly: false);
    await expectLater(
      provider.update(
        provider.entries.first.id,
        guestPath: '/opt/data/inner',
        readOnly: false,
      ),
      rejects('external_mount_overlap'),
    );
    // Saving a mount under its own path is not a conflict with itself.
    await provider.update(
      provider.entries.first.id,
      guestPath: '/root/Notes',
      readOnly: false,
    );
    expect(provider.entries.map((m) => m.guestPath), [
      '/root/Notes',
      '/opt/data',
    ]);
  });

  test('rejects overlapping sources and keeps any number of mounts', () async {
    await provider.add(
      directory('a'),
      guestPath: '/root/Notes',
      readOnly: true,
    );
    sources['child'] = '/storage/A/child';
    await expectLater(
      provider.add(
        directory('child'),
        guestPath: '/root/Alias',
        readOnly: false,
      ),
      throwsA(isA<WorkspaceChannelException>()),
    );
    expect(provider.entries, hasLength(1));
    for (var i = 1; i < 15; i++) {
      sources['$i'] = '/storage/folder$i';
      await provider.add(
        directory('$i'),
        guestPath: '/opt/folder$i',
        readOnly: false,
      );
    }
    expect(provider.entries, hasLength(15));
    expect(native, hasLength(15));
  });

  test('rows that no longer parse are dropped, not fatal', () async {
    await store.upsert(ExternalMountsProvider.kind, 'global', {
      'mounts': [
        // Pre-path rows carry a name instead of a guest path.
        {
          'id': 'legacy',
          'name': 'Notes',
          'access': const WorkspaceDirectoryAccess(
            platform: 'android',
            token: 'a',
          ).toJson(),
          'sourcePath': '/storage/A',
          'readOnly': false,
        },
        {'id': 'truncated'},
        {
          'id': 'kept',
          'guestPath': '/opt/data',
          'access': const WorkspaceDirectoryAccess(
            platform: 'android',
            token: 'b',
          ).toJson(),
          'sourcePath': '/storage/B',
          'readOnly': false,
        },
      ],
    });
    provider.dispose();
    provider = ExternalMountsProvider(store: store, channel: harness.channel);
    await provider.loaded;
    expect(provider.entries.map((m) => m.guestPath), ['/opt/data']);
    expect(native.single['guest'], '/opt/data');
  });
}
