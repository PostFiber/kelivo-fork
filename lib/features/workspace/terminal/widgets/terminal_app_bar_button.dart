import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/models/workspace_binding.dart';
import 'package:Kelivo/core/providers/workspace_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/haptics.dart';
import 'package:Kelivo/core/services/workspace/workspace_runtime.dart';
import 'package:Kelivo/features/workspace/terminal/open_terminal.dart';
import 'package:Kelivo/features/workspace/workspace_layout.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/ios_tactile.dart';

/// App-bar shortcut to the conversation workspace's shell.
///
/// A terminal is a verb on a bound workspace — it has no mounts, cwd, or host
/// directory of its own — so this button stays out of the bar only while the
/// runtime can host no shell at all. Runtimes with a PTY (the mobile
/// sandboxes) push the in-app [TerminalPage]; runtimes that only shell out
/// (desktop) hand the bound directory to the platform's own terminal.
///
/// Dimmed rather than hidden while nothing is bound, so tapping it can explain
/// what is missing instead of the entry point silently not existing.
class TerminalAppBarButton extends StatelessWidget {
  const TerminalAppBarButton({super.key});

  static const Key buttonKey = ValueKey<String>('home-terminal-button');

  @override
  Widget build(BuildContext context) {
    final runtime = context.watch<WorkspaceRuntimeProvider>().runtime;
    if (runtime == null ||
        (!runtime.supportsPty && !runtime.supportsSystemTerminal)) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final desktop = useDesktopWorkspaceLayout(context);
    final system = !runtime.supportsPty;
    final label = system
        ? l10n.workspaceEntryOpenSystemTerminal
        : l10n.terminalTitle;
    final bound = _hasBoundWorkspace(context);
    final conversationId = context.select<ChatService, String?>(
      (chat) => chat.currentConversationId,
    );

    return IosIconButton(
      key: buttonKey,
      icon: Lucide.Terminal,
      size: desktop ? 20 : 22,
      padding: EdgeInsets.all(desktop ? 8 : 6),
      minSize: desktop ? 40 : 44,
      color: bound
          ? null
          : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
      semanticLabel: label,
      tooltip: desktop ? label : null,
      onTap: () {
        Haptics.light();
        if (system) {
          unawaited(
            openSystemTerminalForConversation(
              context,
              conversationId: conversationId,
            ),
          );
        } else {
          unawaited(openTerminal(context, conversationId: conversationId));
        }
      },
    );
  }

  /// True while the current conversation names a workspace that still exists.
  bool _hasBoundWorkspace(BuildContext context) {
    final workspaces = context.watch<WorkspaceProvider>();
    final chat = context.watch<ChatService>();
    final id = chat.currentConversationId;
    if (id == null) return false;
    return WorkspaceBinding.extrasHaveWorkspace(
      chat.getConversation(id)?.extras,
      (workspaceId) => workspaces.byId(workspaceId) != null,
    );
  }
}
