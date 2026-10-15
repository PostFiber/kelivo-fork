import 'dart:io';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/extension_entity_store.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/models/workspace.dart';
import 'package:Kelivo/core/models/workspace_binding.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/providers/workspace_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/workspace/workspace_runtime.dart';
import 'package:Kelivo/features/workspace/terminal/terminal_session_manager.dart';
import 'package:Kelivo/features/workspace/terminal/widgets/terminal_app_bar_button.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';
import 'package:Kelivo/theme/theme_factory.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import '../../../support/business_test_harness.dart';
import 'fake_workspace_runtime.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => p.join(path, 'cache');

  @override
  Future<String?> getTemporaryPath() async => p.join(path, 'tmp');
}

class _FakeChatService extends ChatService {
  _FakeChatService(this.conversation);

  final Conversation? conversation;

  @override
  String? get currentConversationId => conversation?.id;

  @override
  Conversation? getConversation(String id) {
    if (conversation == null) return null;
    return conversation!.id == id ? conversation : null;
  }
}

/// A runtime that hosts no shell at all, so the button has nothing to offer.
class _NoShellRuntime extends FakeWorkspaceRuntime {
  @override
  bool get supportsPty => false;

  @override
  bool get supportsSystemTerminal => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase database;
  late WorkspaceProvider workspaces;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('kelivo_terminal_button_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    database = AppDatabase(NativeDatabase.memory());
    await database.customSelect('SELECT 1;').getSingle();
    workspaces = WorkspaceProvider(store: ExtensionEntityStore(database));
    await workspaces.loaded;
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    await database.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<void> pumpButton(
    WidgetTester tester, {
    required Conversation? conversation,
    required WorkspaceRuntime? runtime,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final runtimeProvider = WorkspaceRuntimeProvider();
    if (runtime != null) {
      runtimeProvider.register(runtime);
    }
    final manager = TerminalSessionManager(setWakelock: (_) async {});
    addTearDown(() async {
      await manager.closeAll();
      manager.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(
            create: (_) => SettingsProvider(createBusinessTestPreferences()),
          ),
          ChangeNotifierProvider<WorkspaceProvider>.value(value: workspaces),
          ChangeNotifierProvider<ChatService>.value(
            value: _FakeChatService(conversation),
          ),
          ChangeNotifierProvider<WorkspaceRuntimeProvider>.value(
            value: runtimeProvider,
          ),
          ChangeNotifierProvider<TerminalSessionManager>.value(value: manager),
        ],
        child: MaterialApp(
          theme: buildLightTheme(null),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AppSnackBarOverlay(
            child: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: TerminalAppBarButton(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('renders nothing when the runtime hosts no shell', (
    tester,
  ) async {
    await pumpButton(
      tester,
      conversation: Conversation(id: 'conv', title: 'Chat'),
      runtime: _NoShellRuntime(),
    );

    expect(find.byKey(TerminalAppBarButton.buttonKey), findsNothing);
  });

  testWidgets('warns instead of opening while no workspace is bound', (
    tester,
  ) async {
    await pumpButton(
      tester,
      conversation: Conversation(id: 'conv', title: 'Chat'),
      runtime: FakeWorkspaceRuntime(),
    );

    final button = find.byKey(TerminalAppBarButton.buttonKey);
    expect(button, findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(button);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));

    expect(find.text('Bind a workspace first'), findsOneWidget);
  });

  testWidgets('opens the bound workspace cwd in the system terminal', (
    tester,
  ) async {
    final hostRoot = p.join(tempDir.path, 'linked-ws');
    Directory(hostRoot).createSync(recursive: true);
    late Workspace workspace;
    await tester.runAsync(() async {
      workspace = await workspaces.create(
        name: 'Linked',
        kind: WorkspaceKind.linked,
        hostPath: hostRoot,
      );
    });

    final conversation = Conversation(
      id: 'conv-bound',
      title: 'Chat',
      extras: {
        WorkspaceBinding.keyId: workspace.id,
        WorkspaceBinding.keyCwd: 'sub',
      },
    );
    final runtime = FakeWorkspaceRuntime(ptySupported: false);

    await pumpButton(tester, conversation: conversation, runtime: runtime);
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.byKey(TerminalAppBarButton.buttonKey));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(runtime.lastSystemDir, p.join(p.canonicalize(hostRoot), 'sub'));
  });
}
