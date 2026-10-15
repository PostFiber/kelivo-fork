import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../core/models/chat_input_data.dart';
import '../../../core/providers/external_mounts_provider.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/api/chat_api_helpers.dart';
import '../../../core/services/api/generation/tool_loop_runner.dart';
import '../../../core/services/api/stream/stream_chunk.dart';
import '../../../core/services/api/stream/stream_chunk_emit.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/workspace/workspace_runtime.dart';
import '../../../core/services/workspace/workspace_tools_service.dart';

/// Leading marker that turns a composer message into a shell command.
const String kComposerCommandPrefix = '!';

/// The tool a composer command runs as, and the name its transcript card
/// carries. Kept identical to the model's own shell tool so both leave the
/// same entry behind.
const String kComposerShellTool = 'shell';

/// The command [input] asks for, or null when it is an ordinary message.
///
/// Attachments keep a message a message: a command has nowhere to put them, so
/// a `!` in front of a file is text rather than a request to run something.
String? composerCommandOf(ChatInputData input) {
  if (input.imagePaths.isNotEmpty || input.documents.isNotEmpty) return null;
  return composerCommandIn(input.text);
}

/// The command [text] asks for, or null when [text] is an ordinary message.
///
/// A bare `!` is not a command: with nothing after it there is nothing to run,
/// so the message goes to the model like any other.
String? composerCommandIn(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith(kComposerCommandPrefix)) return null;
  final command = trimmed.substring(1).trim();
  return command.isEmpty ? null : command;
}

/// Whether [conversationId] has a workspace a command can run in.
///
/// Checked before the message is sent, so a conversation with nowhere to run
/// reports that while the command is still in the composer.
Future<bool> composerCommandCanRunIn(
  BuildContext context, {
  required String conversationId,
}) async {
  final resolved = await WorkspaceToolsService.resolve(
    conversationId: conversationId,
    workspaceProvider: context.read<WorkspaceProvider>(),
    runtimeProvider: context.read<WorkspaceRuntimeProvider>(),
    chatService: context.read<ChatService>(),
    externalMounts: context.read<ExternalMountsProvider?>(),
  );
  return resolved != null && !resolved.skillsOnly;
}

/// The stream a `!command` message generates from, standing in for the model.
///
/// The command is run as the client tool round a `shell` call from the model
/// would be: the same [onToolCall], the same transcript entry, the same
/// persistence. Only the request that would have asked the model for it is
/// missing, so everything downstream — the card, the live output, the stored
/// result — is the ordinary path.
Stream<StreamChunk> composerCommandStream({
  required String command,
  required ToolCallHandler onToolCall,
}) async* {
  yield* executeClientTools(
    calls: <EmitToolCall>[
      emitToolCall(
        id: 'composer_${DateTime.now().microsecondsSinceEpoch}',
        name: kComposerShellTool,
        arguments: <String, dynamic>{'command': command},
      ),
    ],
    onToolCall: onToolCall,
    emitCalls: true,
  );
  yield const Finish();
}
