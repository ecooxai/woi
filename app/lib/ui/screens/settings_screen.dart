import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../platform/audio_io.dart';
import '../../core/auth/auth.dart';
import '../../core/settings/settings.dart';
import '../../core/voice/backend_factory.dart';
import '../theme.dart';
import '../widgets/context_meter.dart';
import '../widgets/empty_state.dart' show KeyCap;
import '../widgets/glass.dart';
import '../widgets/usage_meter.dart';

/// Choices for the background models (a custom model id is also accepted).
const kCompressionModels = ['gpt-6-luna', 'gpt-6.1-sol'];
const kDelegateModels = ['gpt-6-luna', 'gpt-6.1-sol'];

/// Short descriptions shown under the model radio buttons.
const kModelHints = <String, String>{
  'gpt-live-1.1': 'Latest; best turn-taking',
  'gpt-live-1': 'Previous release',
  'gpt-live-1-codex': 'Tuned for coding tasks',
  'gpt-realtime-2.1': 'Latest realtime model',
  'gpt-realtime-2.1-mini': 'Latest, faster and cheaper',
  'gpt-realtime-2': 'Previous release',
  'gpt-realtime-1.5': 'Older release',
  'gpt-realtime': 'Original release',
  'gpt-realtime-mini': 'Fastest, lowest cost',
  'gpt-6-luna': 'Fast and inexpensive',
  'gpt-6.1-sol': 'Strongest reasoning, slower, expensive',
};

enum _TestState { idle, testing, ok, failed }

/// All user settings, shown inline in the Settings tab: sections with
/// descriptions, a section rail on wide layouts, a single column on phones.
/// Changes apply immediately (text fields after a short pause) and persist
/// to ~/.local/share/woi/settings.json.
class SettingsView extends StatefulWidget {
  const SettingsView({super.key, required this.controller});
  final AppController controller;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late AppSettings _s = widget.controller.settings;
  late final _apiKey = TextEditingController(text: _s.apiKey);
  late final _compressionModel = TextEditingController(text: _s.compressionModel);
  late final _delegateModel = TextEditingController(text: _s.delegateModel);
  late final _workspace = TextEditingController(text: _s.workspaceDir);

  /// Model choices showing the custom-id field.
  final _customModel = <String>{};
  final _scroll = ScrollController();
  bool _showKey = false;
  Timer? _debounce;
  _TestState _test = _TestState.idle;
  String? _testMessage;
  int _active = 0;
  late final List<GlobalKey> _keys = List.generate(7, (_) => GlobalKey());

  AppController get c => widget.controller;

  void _apply(AppSettings next, {bool debounce = false}) {
    setState(() => _s = next);
    _debounce?.cancel();
    if (debounce) {
      _debounce = Timer(const Duration(milliseconds: 700), () => c.actions.updateSettings(_s));
    } else {
      c.actions.updateSettings(next);
    }
  }

  @override
  void dispose() {
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      c.actions.updateSettings(_s);
    }
    _apiKey.dispose();
    _compressionModel.dispose();
    _delegateModel.dispose();
    _workspace.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // --------------------------------------------------------- test connection

  Future<void> _testConnection() async {
    setState(() {
      _test = _TestState.testing;
      _testMessage = null;
    });
    String msg;
    var ok = false;
    try {
      if (_s.authMode == AuthMode.codex) {
        final creds = await c.authManager.credentials(forceRefresh: false).timeout(const Duration(seconds: 15));
        await c.refreshCodexAuth();
        if (creds == null || creds.bearerToken.isEmpty) {
          msg = 'No Codex login found. Run `codex login` first.';
        } else {
          final exp = creds.expiresAt;
          ok = exp == null || exp.isAfter(DateTime.now());
          msg = ok
              ? 'Codex credentials OK${exp != null ? ' · token valid until ${_hm(exp.toLocal())}' : ''}'
              : 'Codex token expired; refresh failed.';
        }
      } else {
        final creds = await resolveCredentials(AuthMode.apiKey, _apiKey.text);
        if (creds == null) {
          msg = 'No API key. Paste one above or set \$OPENAI_API_KEY.';
        } else {
          final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
          try {
            final req = await client.getUrl(Uri.parse('https://api.openai.com/v1/models'));
            req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${creds.bearerToken}');
            final res = await req.close().timeout(const Duration(seconds: 15));
            final text = await res.transform(utf8.decoder).join();
            if (res.statusCode == 200) {
              ok = true;
              final n = (jsonDecode(text) as Map)['data'];
              msg = 'Connected · ${n is List ? '${n.length} models available' : 'key accepted'}';
            } else {
              String? err;
              try {
                err = ((jsonDecode(text) as Map)['error'] as Map?)?['message'] as String?;
              } catch (_) {}
              msg = 'HTTP ${res.statusCode}${err != null ? ' · $err' : ''}';
            }
          } finally {
            client.close(force: true);
          }
        }
      }
    } on TimeoutException {
      msg = 'Timed out. Check your network.';
    } catch (e) {
      msg = '$e';
    }
    if (!mounted) return;
    setState(() {
      _test = ok ? _TestState.ok : _TestState.failed;
      _testMessage = msg;
    });
  }

  static String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // ------------------------------------------------------------------ build

  static const _sections = [
    (Icons.cloud_outlined, 'Connection', 'How Woi reaches the voice model, and with which credentials.'),
    (Icons.graphic_eq_rounded, 'Voice', 'The speech model and the voice Woi answers with.'),
    (
      Icons.memory_rounded,
      'Context & models',
      'When long conversations get summarized, and which models do background work.',
    ),
    (Icons.shield_outlined, 'Screen & safety', 'Screenshots sent with your turns and what needs your approval.'),
    (Icons.contrast_rounded, 'Appearance', 'How Woi looks.'),
    (Icons.keyboard_alt_outlined, 'Shortcuts', 'Keyboard controls on desktop.'),
    (Icons.info_outline_rounded, 'About', 'Runtime details for troubleshooting.'),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= 900;
      final bodies = [
        _connection(wide),
        _voice(wide),
        _context(wide),
        _screen(wide),
        _appearance(wide),
        _shortcuts(),
        _about(),
      ];
      final list = ListView(
        key: const ValueKey('settings-list'),
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(wide ? 8 : 0, wide ? 0 : 4, wide ? 8 : 0, 24),
        children: [
          for (var i = 0; i < bodies.length; i++)
            Padding(key: _keys[i], padding: const EdgeInsets.only(bottom: 16), child: _section(i, bodies[i], wide)),
          Center(
            child: Text('Changes save automatically', style: body(12, color: WoiColors.textFaint)),
          ),
        ],
      );
      if (!wide) return list;
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(right: 12), child: _rail()),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (_) {
                    _syncSection();
                    return false;
                  },
                  child: list,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  void _syncSection() {
    final view = context.findRenderObject() as RenderBox?;
    if (view == null || !view.attached) return;
    final top = view.localToGlobal(Offset.zero).dy;
    var best = 0;
    for (var i = 0; i < _keys.length; i++) {
      final box = _keys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      if (box.localToGlobal(Offset.zero).dy - top < 120) best = i;
    }
    if (best != _active) setState(() => _active = best);
  }

  void _jump(int i) {
    setState(() => _active = i);
    final ctx = _keys[i].currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: WoiMotion.slow, curve: WoiMotion.emphasized);
    }
  }

  Widget _rail() => SizedBox(
    width: 220,
    child: GlassPanel(
      padding: const EdgeInsets.all(8),
      radius: WoiRadii.lg,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _sections.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(WoiRadii.md),
                  onTap: () => _jump(i),
                  child: AnimatedContainer(
                    duration: WoiMotion.fast,
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(WoiRadii.md),
                      color: i == _active ? WoiColors.cyan.withValues(alpha: 0.12) : Colors.transparent,
                      border: Border.all(
                        color: i == _active ? WoiColors.cyan.withValues(alpha: 0.35) : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(_sections[i].$1, size: 18, color: i == _active ? WoiColors.cyan : WoiColors.textDim),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _sections[i].$2,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: body(
                              14,
                              weight: i == _active ? FontWeight.w600 : FontWeight.w400,
                              color: i == _active ? WoiColors.text : WoiColors.textDim,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _section(int i, List<Widget> children, bool wide) {
    final (icon, title, desc) = _sections[i];
    return GlassPanel(
      padding: wide ? const EdgeInsets.fromLTRB(22, 20, 22, 14) : const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: WoiColors.cyan.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: WoiColors.cyan),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(header: true, child: Text(title, style: display(17))),
                    const SizedBox(height: 2),
                    Text(desc, style: body(12.5, color: WoiColors.textDim)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (var k = 0; k < children.length; k++) ...[
            if (k > 0) Divider(height: 1, color: WoiColors.stroke),
            children[k],
          ],
        ],
      ),
    );
  }

  /// Label + description on the left, control on the right (stacked on phone).
  Widget _row(bool wide, String title, String desc, Widget control, {double controlWidth = 300}) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: body(14, weight: FontWeight.w500)),
        const SizedBox(height: 3),
        Text(desc, style: body(12.5, color: WoiColors.textDim, height: 1.35)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: wide
          ? Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: 24),
                SizedBox(width: controlWidth, child: control),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [text, const SizedBox(height: 10), control],
            ),
    );
  }

  // --------------------------------------------------------------- sections

  List<Widget> _connection(bool wide) => [
    _choices<BackendMode>(
      wide,
      id: 'backend',
      title: 'Backend',
      desc: 'Where the voice session runs. Switching reconnects.',
      options: BackendMode.values,
      value: _s.backendMode,
      label: (m) => m.label,
      hint: _backendHint,
      columns: 1,
      onChanged: (v) => _apply(_s.copyWith(backendMode: v)),
    ),
    if (_s.backendMode == BackendMode.gptLive)
      _row(
        wide,
        'Use Direct realtime at the usage limit',
        'When gpt-live reports the ChatGPT usage limit (HTTP 429), connect with Direct realtime until it resets.',
        Align(
          alignment: wide ? Alignment.centerRight : Alignment.centerLeft,
          child: Switch(
            value: _s.fallbackToDirectOnLimit,
            onChanged: (v) => _apply(_s.copyWith(fallbackToDirectOnLimit: v)),
          ),
        ),
        controlWidth: 120,
      ),
    if (_s.authMode == AuthMode.codex)
      _row(
        wide,
        'Codex login',
        'Read from ~/.codex/auth.json and refreshed automatically.',
        _codexStatus(),
        controlWidth: 340,
      )
    else
      _row(
        wide,
        'API key',
        'Stored locally in settings.json. Leave empty to use \$OPENAI_API_KEY.',
        _apiKeyField(),
        controlWidth: 340,
      ),
    _row(
      wide,
      'Test connection',
      'Checks the credentials against the API without starting a session.',
      _testButton(),
      controlWidth: 340,
    ),
  ];

  List<Widget> _voice(bool wide) => [
    if (_s.backendMode == BackendMode.gptLive)
      _choices<String>(
        wide,
        id: 'voice-model',
        title: 'Voice model',
        desc: 'Speech-to-speech model used over WebRTC.',
        options: {...kVoiceModels, _s.voiceModel}.toList(),
        value: _s.voiceModel,
        hint: (v) => kModelHints[v],
        monoText: true,
        onChanged: (v) => _apply(_s.copyWith(voiceModel: v)),
      ),
    _choices<String>(
      wide,
      id: 'realtime-model',
      title: _s.backendMode == BackendMode.gptLive ? 'Realtime model (fallback)' : 'Realtime model',
      desc: 'Used by the WebSocket realtime backends.',
      options: {...kRealtimeModels, _s.realtimeModel}.toList(),
      value: _s.realtimeModel,
      hint: (v) => kModelHints[v],
      monoText: true,
      onChanged: (v) => _apply(_s.copyWith(realtimeModel: v)),
    ),
    _choices<String>(
      wide,
      id: 'voice',
      title: 'Voice',
      desc: 'How Woi sounds. Applies from the next session; the current one reconnects.',
      options: {..._s.voiceChoices, _s.activeVoice}.toList(),
      value: _s.activeVoice,
      label: _cap,
      columns: wide ? 5 : 2,
      onChanged: (v) =>
          _apply(_s.backendMode == BackendMode.gptLive ? _s.copyWith(liveVoice: v) : _s.copyWith(voice: v)),
    ),
  ];

  List<Widget> _context(bool wide) => [
    _row(
      wide,
      'ChatGPT usage',
      'Your plan\'s 5-hour and weekly limits. Below ${_s.usageGuardPercent}% left in either, delegation and '
          'compaction use gpt-6-luna.',
      CodexUsageMeter(controller: widget.controller),
      controlWidth: 340,
    ),
    _row(
      wide,
      'Compaction threshold',
      'When the estimated context passes this many tokens, older turns are summarized into a short memory.',
      _slider(
        value: _s.compressionThreshold.clamp(2000, 100000).toDouble(),
        min: 2000,
        max: 100000,
        divisions: 49,
        label: '${formatTokens(_s.compressionThreshold)} tok',
        semantic: 'Compaction threshold',
        onChanged: (v) => setState(() => _s = _s.copyWith(compressionThreshold: v.round())),
        onChangeEnd: (v) => _apply(_s.copyWith(compressionThreshold: v.round())),
      ),
      controlWidth: 340,
    ),
    _modelChoices(
      wide,
      id: 'compression-model',
      title: 'Compression model',
      desc: 'Writes the summary when the context is compacted.',
      options: kCompressionModels,
      value: _s.compressionModel,
      ctl: _compressionModel,
      fallback: 'gpt-6-luna',
      set: (v, {debounce = false}) => _apply(_s.copyWith(compressionModel: v), debounce: debounce),
    ),
    _modelChoices(
      wide,
      id: 'delegate-model',
      title: 'Delegate model',
      desc: 'Runs longer multi-step tasks Woi hands off in the background.',
      options: kDelegateModels,
      value: _s.delegateModel,
      ctl: _delegateModel,
      fallback: 'gpt-6-luna',
      set: (v, {debounce = false}) => _apply(_s.copyWith(delegateModel: v), debounce: debounce),
    ),
    _row(
      wide,
      'Screenshot tiers',
      'Newest ${_s.imageFullCount} sent in full, next ${_s.imageScaledCount} at 1/${_s.imageScaleDivisor} size, '
          'older ones replaced by a short description.',
      Row(
        children: [
          for (final (label, value, options, set) in [
            ('Full', _s.imageFullCount, const [1, 2, 3, 4, 5, 8], (int v) => _s.copyWith(imageFullCount: v)),
            ('Scaled', _s.imageScaledCount, const [0, 3, 5, 8, 10], (int v) => _s.copyWith(imageScaledCount: v)),
            ('Scale 1/', _s.imageScaleDivisor, const [2, 3, 4, 5, 8], (int v) => _s.copyWith(imageScaleDivisor: v)),
          ])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _dropdown(label, '$value', [
                  for (final o in {...options, value}) '$o',
                ], (v) => _apply(set(int.parse(v)))),
              ),
            ),
        ],
      ),
      controlWidth: 340,
    ),
    _row(
      wide,
      'Workspace folder',
      'Relative paths and shell commands start here. Empty: the folder Woi was started from '
          '(or home when started from home or /). Now: ${c.platform.files.workspaceDir}',
      TextField(
        controller: _workspace,
        style: mono(13.5),
        decoration: InputDecoration(labelText: 'Workspace folder', hintText: c.defaultWorkspace),
        onChanged: (v) => _apply(_s.copyWith(workspaceDir: v.trim()), debounce: true),
      ),
    ),
  ];

  List<Widget> _screen(bool wide) => [
    _row(
      wide,
      'Auto-screenshot when I speak',
      'Captures the screen shortly after speech starts and sends it with your turn.',
      Align(
        alignment: wide ? Alignment.centerRight : Alignment.centerLeft,
        child: Switch(
          value: _s.autoScreenshot,
          onChanged: (v) => _apply(_s.copyWith(autoScreenshot: v)),
        ),
      ),
      controlWidth: 120,
    ),
    _row(
      wide,
      'Screenshot delay',
      'Wait after you start speaking, so menus or pages you just opened have rendered.',
      _slider(
        value: _s.screenshotDelayMs.clamp(0, 4000).toDouble(),
        min: 0,
        max: 4000,
        divisions: 40,
        label: '${(_s.screenshotDelayMs / 1000).toStringAsFixed(1)} s',
        semantic: 'Screenshot delay',
        onChanged: _s.autoScreenshot ? (v) => setState(() => _s = _s.copyWith(screenshotDelayMs: v.round())) : null,
        onChangeEnd: (v) => _apply(_s.copyWith(screenshotDelayMs: v.round())),
      ),
      controlWidth: 340,
    ),
    _choices<bool>(
      wide,
      id: 'camera-screenshot',
      title: 'Camera and screenshots',
      desc: 'While the camera is on, a camera frame goes with every turn.',
      options: const [false, true],
      value: _s.cameraReplacesScreenshot,
      label: (v) => v ? 'Camera replaces the screenshot' : 'Camera adds to the screenshot',
      hint: (v) => v ? 'Only the camera frame is sent' : 'Both the screen and the camera frame are sent',
      onChanged: (v) => _apply(_s.copyWith(cameraReplacesScreenshot: v)),
    ),
    _row(
      wide,
      'Echo cancellation',
      'Remove what the speakers play (Woi, music, videos) from the microphone so it is not heard as you.',
      Align(
        alignment: wide ? Alignment.centerRight : Alignment.centerLeft,
        child: Switch(
          value: _s.echoCancellation,
          onChanged: (v) => _apply(_s.copyWith(echoCancellation: v)),
        ),
      ),
      controlWidth: 120,
    ),
    if (c.platform.audio is AudioRouted)
      _choices<AndroidAudioRoute>(
        wide,
        id: 'android-audio-route',
        title: 'Audio route on Android',
        desc: 'Phone uses the call path with its built-in echo cancellation; Media plays at media volume.',
        options: AndroidAudioRoute.values,
        value: _s.androidAudioRoute,
        label: (r) => r == AndroidAudioRoute.phone ? 'Phone (echo cancellation, default)' : 'Media',
        hint: (r) => r == AndroidAudioRoute.phone
            ? 'Call audio: loudspeaker or headset, call volume'
            : 'Media audio and volume; weaker echo cancellation',
        onChanged: (v) => _apply(_s.copyWith(androidAudioRoute: v)),
      ),
    _row(
      wide,
      'Thinking chime',
      'A soft chime when you stop speaking, while Woi works on the reply.',
      Align(
        alignment: wide ? Alignment.centerRight : Alignment.centerLeft,
        child: Switch(
          value: _s.thinkingEarcon,
          onChanged: (v) => _apply(_s.copyWith(thinkingEarcon: v)),
        ),
      ),
      controlWidth: 120,
    ),
    _row(
      wide,
      'Confirm shell commands',
      'Ask before running any bash command (and commands typed into terminal tabs by voice).',
      Align(
        alignment: wide ? Alignment.centerRight : Alignment.centerLeft,
        child: Switch(
          value: _s.confirmBeforeBash,
          onChanged: (v) => _apply(_s.copyWith(confirmBeforeBash: v)),
        ),
      ),
      controlWidth: 120,
    ),
    _choices<int>(
      wide,
      id: 'edit-delay',
      title: 'AI edits',
      desc:
          'Note and file edits show an inline diff first. They apply after the countdown unless you reject them '
          '(Esc, "reject"); "undo that" reverts the last one.',
      options: kEditApplyDelays,
      value: _s.editApplyDelay,
      onChanged: (v) => _apply(_s.copyWith(editApplyDelay: v)),
      label: (v) => v == kRequireApproval ? 'Require approval' : (v == 0 ? 'Apply at once' : 'After $v s'),
      columns: 5,
    ),
    _row(
      wide,
      'Run in terminal',
      'Show the AI\'s shell commands in the Terminal tab (Ctrl+3, "AI" sub-tab). The output is still returned to the AI.',
      Align(
        alignment: wide ? Alignment.centerRight : Alignment.centerLeft,
        child: Switch(
          key: const ValueKey('run-in-terminal-switch'),
          value: _s.runBashInTerminal,
          onChanged: (v) => _apply(_s.copyWith(runBashInTerminal: v)),
        ),
      ),
      controlWidth: 120,
    ),
  ];

  List<Widget> _appearance(bool wide) => [
    _choices<AppTheme>(
      wide,
      id: 'theme',
      title: 'Theme',
      desc: 'Light is the default; System follows the desktop setting.',
      options: AppTheme.values,
      value: _s.theme,
      label: (t) => t.label,
      hint: (t) => switch (t) {
        AppTheme.light => 'Bright, high-contrast surfaces',
        AppTheme.dark => 'Dim surfaces for low light',
        AppTheme.system => 'Match the system appearance',
      },
      columns: wide ? 3 : 1,
      onChanged: (v) => _apply(_s.copyWith(theme: v)),
    ),
  ];

  List<Widget> _shortcuts() {
    const items = [
      (['Space'], 'Hold to talk (push-to-talk mode, when not typing)'),
      (['Esc'], 'Interrupt Woi · reject a confirmation · close dialogs'),
      (['Enter'], 'Approve a confirmation · send a message'),
      (['Shift', 'Enter'], 'New line in the message box'),
      (['Ctrl', '1'], 'Note tab'),
      (['Ctrl', '2'], 'Chat tab'),
      (['Ctrl', '3'], 'Terminal tab'),
      (['Ctrl', '4'], 'Settings tab (also Ctrl+,; Esc goes back)'),
      (['Ctrl', '\\'], 'Note and chat side by side (wide windows)'),
      (['Ctrl', 'K'], 'Focus the message box'),
      (['Ctrl', 'N'], 'New note / conversation'),
      (['Ctrl', 'R'], 'Run the note line or selection as a message'),
      (['Ctrl', 'Shift', 'T'], 'New terminal tab (Ctrl+Shift+W closes it)'),
      (['Ctrl', 'Shift', 'C'], 'Copy in the terminal (Ctrl+Shift+V pastes)'),
    ];
    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: [
            for (final (keys, label) in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(width: 130, child: Wrap(spacing: 4, children: [for (final k in keys) KeyCap(k)])),
                    Expanded(
                      child: Text(label, style: body(13.5, color: WoiColors.textDim)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _about() => [
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        children: [
          _kv('Voice backend', c.pipeline.backend?.runtimeType.toString() ?? '—'),
          _kv('Audio', c.platform.audio.description),
          _kv('Data folder', c.platform.paths.dataDir),
        ],
      ),
    ),
  ];

  // ---------------------------------------------------------------- widgets

  Widget _slider({
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required String semantic,
    required ValueChanged<double>? onChanged,
    required ValueChanged<double> onChangeEnd,
  }) => Row(
    children: [
      Expanded(
        child: Slider(
          min: min,
          max: max,
          divisions: divisions,
          value: value,
          label: label,
          semanticFormatterCallback: (_) => '$semantic $label',
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ),
      Container(
        width: 84,
        padding: const EdgeInsets.symmetric(vertical: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: WoiColors.cyan.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: WoiColors.cyan.withValues(alpha: 0.25)),
        ),
        child: Text(
          label,
          style: mono(13, color: WoiColors.cyan).copyWith(fontFeatures: kTabular),
        ),
      ),
    ],
  );

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(k, style: body(13, color: WoiColors.textDim)),
        ),
        Expanded(child: SelectableText(v, style: mono(12.5))),
      ],
    ),
  );

  static String _cap(String v) => v.isEmpty ? v : '${v[0].toUpperCase()}${v.substring(1)}';

  /// A titled radio list: one row per option (with an optional hint), laid
  /// out in [columns] on wide screens and one per row (48dp) on phones.
  Widget _choices<T>(
    bool wide, {
    required String id,
    required String title,
    required String desc,
    required List<T> options,
    required T value,
    required ValueChanged<T> onChanged,
    String Function(T)? label,
    String? Function(T)? hint,
    int? columns,
    bool monoText = false,
    List<Widget> extra = const [],
  }) {
    final cols = wide ? (columns ?? 2) : (columns ?? 1).clamp(1, 2);
    String name(T v) => label?.call(v) ?? '$v';
    Widget item(T v) {
      final h = hint?.call(v);
      final on = v == value;
      return Semantics(
        inMutuallyExclusiveGroup: true,
        child: InkWell(
          key: ValueKey('radio-$id-${v is Enum ? v.name : v}'),
          borderRadius: BorderRadius.circular(WoiRadii.md),
          onTap: () => onChanged(v),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kTouchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Radio<T>(value: v),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name(v),
                          style: (monoText ? mono(13.5) : body(14)).copyWith(
                            fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                            color: WoiColors.text,
                          ),
                        ),
                        if (h != null && h.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(h, style: body(12.5, color: WoiColors.textDim, height: 1.3)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final rows = <Widget>[];
    for (var i = 0; i < options.length; i += cols) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var k = i; k < i + cols; k++)
              Expanded(child: k < options.length ? item(options[k]) : const SizedBox()),
          ],
        ),
      );
    }
    return Padding(
      key: ValueKey('choices-$id'),
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: body(14, weight: FontWeight.w600)),
          ),
          const SizedBox(height: 3),
          Text(desc, style: body(12.5, color: WoiColors.textDim, height: 1.35)),
          const SizedBox(height: 6),
          RadioGroup<T>(
            groupValue: value,
            onChanged: (v) => v == null ? null : onChanged(v),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
          ),
          ...extra,
        ],
      ),
    );
  }

  static const _custom = '\u0000custom';

  /// Model radio list plus a "Custom" choice with a free-text model id.
  Widget _modelChoices(
    bool wide, {
    required String id,
    required String title,
    required String desc,
    required List<String> options,
    required String value,
    required TextEditingController ctl,
    required String fallback,
    required void Function(String v, {bool debounce}) set,
  }) {
    final custom = _customModel.contains(id) || !options.contains(value);
    return _choices<String>(
      wide,
      id: id,
      title: title,
      desc: desc,
      options: [...options, _custom],
      value: custom ? _custom : value,
      label: (v) => v == _custom ? 'Custom' : v,
      hint: (v) => v == _custom ? 'Any model id' : kModelHints[v],
      monoText: true,
      columns: wide ? 3 : 1,
      onChanged: (v) {
        if (v == _custom) {
          setState(() => _customModel.add(id));
          return;
        }
        setState(() => _customModel.remove(id));
        ctl.text = v;
        set(v);
      },
      extra: [
        if (custom)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 0, 0),
            child: TextField(
              key: ValueKey('custom-$id'),
              controller: ctl,
              style: mono(13.5),
              decoration: InputDecoration(labelText: '$title id', hintText: fallback, isDense: true),
              onChanged: (v) => set(v.trim().isEmpty ? fallback : v.trim(), debounce: true),
            ),
          ),
      ],
    );
  }

  Widget _dropdown(String label, String value, List<String> options, ValueChanged<String> onChanged) {
    final items = {...options, value}.toList();
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      borderRadius: BorderRadius.circular(WoiRadii.md),
      dropdownColor: WoiColors.bg2,
      items: [
        for (final o in items)
          DropdownMenuItem(
            value: o,
            child: Text(o, style: mono(13.5)),
          ),
      ],
      onChanged: (v) => v == null ? null : onChanged(v),
    );
  }

  String _backendHint(BackendMode m) => switch (m) {
    BackendMode.gptLive =>
      GptLiveHook.isRegistered
          ? 'Lowest latency, over WebRTC. Uses your Codex login.'
          : 'Lowest latency. Codex login. Not in this build yet: falls back to Direct realtime.',
    BackendMode.direct => 'WebSocket realtime with tools, images and token usage. Codex login.',
    BackendMode.apiKey => 'WebSocket realtime billed to your OpenAI API key.',
  };

  Widget _apiKeyField() => TextField(
    controller: _apiKey,
    obscureText: !_showKey,
    obscuringCharacter: '•',
    autocorrect: false,
    enableSuggestions: false,
    style: mono(13.5),
    decoration: InputDecoration(
      labelText: 'API key',
      hintText: 'sk-…',
      prefixIcon: const Icon(Icons.key_rounded, size: 18),
      suffixIcon: IconButton(
        tooltip: _showKey ? 'Hide key' : 'Show key',
        onPressed: () => setState(() => _showKey = !_showKey),
        icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
      ),
    ),
    onChanged: (v) {
      _test = _TestState.idle;
      _apply(_s.copyWith(apiKey: v.trim()), debounce: true);
    },
  );

  Widget _testButton() {
    final (color, icon) = switch (_test) {
      _TestState.idle => (WoiColors.cyan, Icons.network_check_rounded),
      _TestState.testing => (WoiColors.cyan, null),
      _TestState.ok => (WoiColors.mint, Icons.check_circle_rounded),
      _TestState.failed => (WoiColors.red, Icons.error_outline_rounded),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, kTouchTarget),
            foregroundColor: color,
            side: BorderSide(color: color.withValues(alpha: 0.5)),
          ),
          onPressed: _test == _TestState.testing ? null : _testConnection,
          icon: icon == null
              ? SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: color))
              : Icon(icon, size: 18),
          label: Text(_test == _TestState.testing ? 'Testing…' : 'Test connection'),
        ),
        AnimatedSize(
          duration: WoiMotion.medium,
          child: _testMessage == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(_testMessage!, style: body(12.5, color: color)),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _codexStatus() {
    final info = c.codexAuth;
    final ok = info?.isAvailable ?? false;
    final color = ok ? WoiColors.mint : WoiColors.amber;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(WoiRadii.md),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.verified_user_outlined : Icons.warning_amber_rounded, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(info?.summary ?? 'Codex auth not loaded', style: body(13))),
          IconButton(
            tooltip: 'Reload ~/.codex/auth.json',
            onPressed: () async {
              await c.refreshCodexAuth();
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }
}
