import 'dart:typed_data';

import '../../tools/tool_registry.dart';
import '../responses/responses_client.dart';
import 'delegate_backend.dart';

const kDelegateInstructions = '''
You are the background worker of Woi, a voice assistant on the user's Linux desktop.
You receive one complex task and complete it yourself, step by step, using the tools when useful
(read/list files, run bash, write or edit files, keyboard/mouse, screenshots).
File writes and edits are shown to the user as a diff and need their approval; if they reject one, do not retry it.
Prefer doing the work over describing it. Do not ask questions; make reasonable assumptions.
When the task asks for a script, program, document or any file to be written or created, save it with write_file
(a sensible name in the workspace dir unless a path is given) and say where. Only say a file was saved or changed when
the tool result shows written=true; if the user declined or a tool failed, say so plainly. Never invent results.
Use only the real paths from the environment below; never guess home directories.
Your final message is read aloud by the voice assistant, so make it short and speakable:
at most 80 words, plain sentences, no markdown, no code blocks, no lists; mention any file paths you created
or changed and the key result.
''';

/// Runs complex tasks with a stronger text model (default gpt-6-luna; gpt-6.1-sol is optional and expensive)
/// through the Responses API, in a function-calling loop over the app's
/// [ToolRegistry] (edits still go through user confirmation).
class ResponsesDelegate implements DelegateBackend {
  ResponsesDelegate(
    this.client, {
    required this.tools,
    this.latestScreenshot,
    this.maxSteps = 12,
    this.reasoningEffort = 'medium',
    this.excludedTools = const {'delegate_task'},
    this.onStep,
    this.environment,
  });

  final ResponsesClient client;

  /// Late-bound: the registry is built after the delegate.
  final ToolRegistry Function() tools;

  /// PNG of the screenshot just taken by `take_screenshot`, passed to the model.
  final Uint8List? Function()? latestScreenshot;
  final int maxSteps;
  final String? reasoningEffort;
  final Set<String> excludedTools;

  /// Progress callback (tool name, args) for UI/tests.
  final void Function(String tool, String args)? onStep;

  /// Real user, \$HOME and workspace dir (appended to the instructions).
  final String? Function()? environment;

  String get _instructions {
    final env = environment?.call()?.trim();
    return env == null || env.isEmpty ? kDelegateInstructions : '$kDelegateInstructions\n$env';
  }

  @override
  Future<DelegateResult> runTask(String task, {required String model, String? context}) async {
    final registry = tools();
    final specs = [
      for (final s in registry.specs)
        if (!excludedTools.contains(s.name)) s.toJson(),
    ];
    final input = <Map<String, Object?>>[
      userMessage([
        inputText(context == null || context.trim().isEmpty ? 'Task: $task' : 'Task: $task\n\nContext: $context'),
      ]),
    ];
    var tokens = 0;
    for (var step = 0; step < maxSteps; step++) {
      final r = await client.create(
        model: model,
        instructions: _instructions,
        input: input,
        tools: specs,
        reasoning: reasoningEffort == null ? null : {'effort': reasoningEffort},
      );
      tokens += r.totalTokens;
      input.addAll(r.outputAsInput);
      if (r.functionCalls.isEmpty) {
        final out = r.text.trim();
        return DelegateResult(
          output: out.isEmpty ? 'The task finished without a summary.' : out,
          model: model,
          tokensUsed: tokens,
        );
      }
      for (final call in r.functionCalls) {
        onStep?.call(call.name, call.arguments);
        final String output;
        if (excludedTools.contains(call.name)) {
          output = '{"ok":false,"error":"tool not available to the delegate"}';
        } else {
          output = (await registry.dispatch(call.name, call.arguments, callId: call.callId)).json;
        }
        input.add({'type': 'function_call_output', 'call_id': call.callId, 'output': output});
        if (call.name == 'take_screenshot') {
          final png = latestScreenshot?.call();
          if (png != null) {
            input.add(userMessage([inputImage(png), inputText('Screenshot from take_screenshot.')]));
          }
        }
      }
    }
    return DelegateResult(
      success: false,
      output: 'I stopped after $maxSteps steps without finishing the task.',
      model: model,
      tokensUsed: tokens,
    );
  }
}
