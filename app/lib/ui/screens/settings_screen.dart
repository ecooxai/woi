import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../platform/audio_io.dart';
import '../../platform/screen_capture.dart' show kScreenshotScales;
import '../../platform/android/android_accessibility.dart';
import '../../core/auth/auth.dart';
import '../../core/settings/settings.dart';
import '../../core/voice/backend_factory.dart';
import '../theme.dart';
import '../widgets/context_meter.dart';
import '../widgets/empty_state.dart' show KeyCap;
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
  late final _stopWords = TextEditingController(text: _s.stopWords.join(', '));

  /// Model choices showing the custom-id field.
  final _customModel = <String>{};
  final _scroll = ScrollController();
  bool _showKey = false;
  Timer? _debounce;
  _TestState _test = _TestState.idle;
  String? _testMessage;
  final _search = TextEditingController();
  String _query = '';

  /// Groups whose "Advanced" rows are shown.
  final _open = <String>{};

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
    _stopWords.dispose();
    _search.dispose();
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

  /// Rows narrower than this stack the control under the label (phones).
  static const _sideBySide = 600.0;

  /// The groups, most used first. Rare settings sit behind each group's
  /// "Advanced" expander; a search shows every match, expanded.
  List<_Group> _groups() => [
    _Group('voice', 'Voice & connection', [
      _Item(
        'Voice',
        'How Woi sounds. The current session reconnects.',
        (w) => _choices<String>(
          w,
          id: 'voice',
          title: 'Voice',
          desc: 'How Woi sounds. The current session reconnects.',
          options: {..._s.voiceChoices, _s.activeVoice}.toList(),
          value: _s.activeVoice,
          label: _cap,
          columns: w ? 4 : 2,
          onChanged: (v) =>
              _apply(_s.backendMode == BackendMode.gptLive ? _s.copyWith(liveVoice: v) : _s.copyWith(voice: v)),
        ),
      ),
      if (_s.backendMode == BackendMode.gptLive)
        _Item(
          'Voice model',
          'Speech-to-speech model used over WebRTC.',
          (w) => _choices<String>(
            w,
            id: 'voice-model',
            title: 'Voice model',
            desc: 'Speech-to-speech model used over WebRTC.',
            options: {...kVoiceModels, _s.voiceModel}.toList(),
            value: _s.voiceModel,
            hint: (v) => kModelHints[v],
            monoText: true,
            onChanged: (v) => _apply(_s.copyWith(voiceModel: v)),
          ),
        ),
      _Item(
        'Backend',
        'Where the voice session runs. Switching reconnects.',
        (w) => _choices<BackendMode>(
          w,
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
      ),
      _Item(
        _s.backendMode == BackendMode.gptLive ? 'Realtime model (fallback)' : 'Realtime model',
        'Used by the WebSocket realtime backends.',
        advanced: true,
        (w) => _choices<String>(
          w,
          id: 'realtime-model',
          title: _s.backendMode == BackendMode.gptLive ? 'Realtime model (fallback)' : 'Realtime model',
          desc: 'Used by the WebSocket realtime backends.',
          options: {...kRealtimeModels, _s.realtimeModel}.toList(),
          value: _s.realtimeModel,
          hint: (v) => kModelHints[v],
          monoText: true,
          onChanged: (v) => _apply(_s.copyWith(realtimeModel: v)),
        ),
      ),
      if (_s.backendMode == BackendMode.gptLive)
        _Item(
          'Direct realtime at the usage limit',
          'Switch to Direct realtime while gpt-live is rate limited.',
          detail:
              'When gpt-live reports the ChatGPT usage limit (HTTP 429), connect with Direct realtime until it resets.',
          advanced: true,
          (w) => _switch(w, _s.fallbackToDirectOnLimit, (v) => _apply(_s.copyWith(fallbackToDirectOnLimit: v))),
        ),
    ]),
    _Group('audio', 'Audio', [
      _Item(
        'Echo cancellation',
        'Keep speaker audio from being heard as you.',
        detail: 'Remove what the speakers play (Woi, music, videos) from the microphone so it is not heard as you.',
        (w) => _switch(w, _s.echoCancellation, (v) => _apply(_s.copyWith(echoCancellation: v))),
      ),
      _Item(
        'Thinking chime',
        'A soft chime while Woi works on the reply.',
        (w) => _switch(w, _s.thinkingEarcon, (v) => _apply(_s.copyWith(thinkingEarcon: v))),
      ),
      _Item(
        'Stop word detection',
        'Saying "stop" cuts Woi right away, detected on this device.',
        detail:
            'An offline keyword spotter listens to the microphone only while Woi speaks or is paused; '
            "Woi's own voice is ignored. No audio leaves the device for this.",
        advanced: true,
        keywords: 'kws keyword spotting stop word interrupt barge-in offline',
        (w) => _switch(w, _s.stopWordDetection, (v) => _apply(_s.copyWith(stopWordDetection: v))),
      ),
      _Item(
        'Stop words',
        'Comma-separated English words or phrases.',
        detail: 'Words the stop word detection listens for. Default: stop. More words can add false stops.',
        advanced: true,
        keywords: 'kws keyword spotting stop word interrupt',
        (w) => TextField(
          controller: _stopWords,
          style: mono(13.5),
          decoration: const InputDecoration(labelText: 'Stop words', hintText: 'stop', isDense: true),
          onChanged: (v) => _apply(_s.copyWith(stopWords: parseStopWords(v)), debounce: true),
        ),
      ),
    ]),
    _Group('screen', 'Screen & camera', [
      _Item(
        'Auto-screenshot when I speak',
        'Sends a screenshot with each spoken turn.',
        detail: 'Captures the screen shortly after speech starts and sends it with your turn.',
        (w) => _switch(w, _s.autoScreenshot, (v) => _apply(_s.copyWith(autoScreenshot: v))),
      ),
      _Item(
        'Screenshot delay',
        'Lets menus you just opened render first.',
        detail: 'Wait after you start speaking, so menus or pages you just opened have rendered.',
        (w) => _slider(
          value: _s.screenshotDelayMs.clamp(0, 4000).toDouble(),
          min: 0,
          max: 4000,
          divisions: 40,
          label: '${(_s.screenshotDelayMs / 1000).toStringAsFixed(1)} s',
          semantic: 'Screenshot delay',
          onChanged: _s.autoScreenshot ? (v) => setState(() => _s = _s.copyWith(screenshotDelayMs: v.round())) : null,
          onChangeEnd: (v) => _apply(_s.copyWith(screenshotDelayMs: v.round())),
        ),
      ),
      _Item(
        'Screenshot size',
        'Smaller is cheaper and faster; larger shows small text.',
        detail:
            'Screenshots sent to the model (spoken turns, the assistant, screen share, the screenshot tool) '
            'are scaled to the screen\'s width in dp (default; about a third of the pixels on a phone, full size '
            'on a 1x desktop) or to this share of the screen\'s pixels. Never enlarged.',
        keywords: 'screenshot resolution scale image size downscale dp width vision screen share assist',
        (w) {
          final idx = _scaleIndex(_s.screenshotScale);
          return _slider(
            value: idx.toDouble(),
            min: 0,
            max: kScreenshotScales.length - 1.0,
            divisions: kScreenshotScales.length - 1,
            label: _scaleLabel(kScreenshotScales[idx]),
            semantic: 'Screenshot size',
            onChanged: (v) => setState(() => _s = _s.copyWith(screenshotScale: kScreenshotScales[v.round()])),
            onChangeEnd: (v) => _apply(_s.copyWith(screenshotScale: kScreenshotScales[v.round()])),
          );
        },
      ),
      _Item(
        'Screenshot JPEG quality',
        'Lower makes smaller files; higher keeps text crisp.',
        detail: 'JPEG quality of screenshots sent to the model (50-100). Default 80.',
        keywords: 'screenshot jpeg jpg quality compression file size image',
        (w) => _slider(
          value: _s.screenshotJpegQuality.clamp(50, 100).toDouble(),
          min: 50,
          max: 100,
          divisions: 10,
          label: '${_s.screenshotJpegQuality}',
          semantic: 'Screenshot JPEG quality',
          onChanged: (v) => setState(() => _s = _s.copyWith(screenshotJpegQuality: v.round())),
          onChangeEnd: (v) => _apply(_s.copyWith(screenshotJpegQuality: v.round())),
        ),
      ),
      _Item(
        'Camera and screenshots',
        'While the camera is on, a frame goes with every turn.',
        (w) => _choices<bool>(
          w,
          id: 'camera-screenshot',
          title: 'Camera and screenshots',
          desc: 'While the camera is on, a frame goes with every turn.',
          options: const [false, true],
          value: _s.cameraReplacesScreenshot,
          label: (v) => v ? 'Camera replaces the screenshot' : 'Camera adds to the screenshot',
          hint: (v) => v ? 'Only the camera frame is sent' : 'Both the screen and the camera frame are sent',
          columns: 1,
          onChanged: (v) => _apply(_s.copyWith(cameraReplacesScreenshot: v)),
        ),
      ),
      _Item(
        'Screenshot tiers',
        'Full ${_s.imageFullCount}, scaled ${_s.imageScaledCount} at 1/${_s.imageScaleDivisor}, older described.',
        detail:
            'Newest ${_s.imageFullCount} sent in full, next ${_s.imageScaledCount} at 1/${_s.imageScaleDivisor} '
            'size, older ones replaced by a short description.',
        advanced: true,
        (w) => Row(
          children: [
            for (final (label, value, options, set) in [
              ('Full', _s.imageFullCount, const [1, 2, 3, 4, 5, 8], (int v) => _s.copyWith(imageFullCount: v)),
              ('Scaled', _s.imageScaledCount, const [0, 3, 5, 8, 10], (int v) => _s.copyWith(imageScaledCount: v)),
              (
                'Scale 1/',
                _s.imageScaleDivisor,
                const [2, 3, 4, 5, 8],
                (int v) => _s.copyWith(imageScaleDivisor: v),
              ),
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
      ),
    ]),
    _Group('context', 'Context & models', [
      _Item(
        'Compaction threshold',
        'Older turns are summarized past this many tokens.',
        detail: 'When the estimated context passes this many tokens, older turns are summarized into a short memory.',
        (w) => _slider(
          value: _s.compressionThreshold.clamp(2000, 100000).toDouble(),
          min: 2000,
          max: 100000,
          divisions: 49,
          label: '${formatTokens(_s.compressionThreshold)} tok',
          semantic: 'Compaction threshold',
          onChanged: (v) => setState(() => _s = _s.copyWith(compressionThreshold: v.round())),
          onChangeEnd: (v) => _apply(_s.copyWith(compressionThreshold: v.round())),
        ),
      ),
      _Item(
        'Compression model',
        'Writes the summary when the context is compacted.',
        advanced: true,
        (w) => _modelChoices(
          w,
          id: 'compression-model',
          title: 'Compression model',
          desc: 'Writes the summary when the context is compacted.',
          options: kCompressionModels,
          value: _s.compressionModel,
          ctl: _compressionModel,
          fallback: 'gpt-6-luna',
          set: (v, {debounce = false}) => _apply(_s.copyWith(compressionModel: v), debounce: debounce),
        ),
      ),
      _Item(
        'Delegate model',
        'Runs longer tasks Woi hands off in the background.',
        advanced: true,
        (w) => _modelChoices(
          w,
          id: 'delegate-model',
          title: 'Delegate model',
          desc: 'Runs longer tasks Woi hands off in the background.',
          options: kDelegateModels,
          value: _s.delegateModel,
          ctl: _delegateModel,
          fallback: 'gpt-6-luna',
          set: (v, {debounce = false}) => _apply(_s.copyWith(delegateModel: v), debounce: debounce),
        ),
      ),
    ]),
    _Group('editing', 'Editing & safety', [
      _Item(
        'AI edits',
        'Edits show a diff first, then apply after the countdown.',
        (w) => _choices<int>(
          w,
          id: 'edit-delay',
          title: 'AI edits',
          desc: 'Edits show a diff first, then apply after the countdown.',
          detail:
              'Note and file edits show an inline diff first. They apply after the countdown unless you reject them '
              '(Esc, "reject"); "undo that" reverts the last one.',
          options: kEditApplyDelays,
          value: _s.editApplyDelay,
          onChanged: (v) => _apply(_s.copyWith(editApplyDelay: v)),
          label: (v) => v == kRequireApproval ? 'Require approval' : (v == 0 ? 'Apply at once' : 'After $v s'),
          columns: w ? 3 : 2,
        ),
      ),
      _Item(
        'Confirm shell commands',
        'Ask before running any bash command.',
        detail: 'Ask before running any bash command (and commands typed into terminal tabs by voice).',
        (w) => _switch(w, _s.confirmBeforeBash, (v) => _apply(_s.copyWith(confirmBeforeBash: v))),
      ),
      _Item(
        'Run in terminal',
        'Show the AI\'s shell commands in the Terminal tab.',
        detail:
            'Show the AI\'s shell commands in the Terminal tab (Ctrl+3, "AI" sub-tab). The output is still '
            'returned to the AI.',
        (w) => _switch(
          w,
          _s.runBashInTerminal,
          (v) => _apply(_s.copyWith(runBashInTerminal: v)),
          key: const ValueKey('run-in-terminal-switch'),
        ),
      ),
      _Item(
        'Workspace folder',
        'Relative paths and shell commands start here.',
        detail:
            'Empty: the folder Woi was started from (or home when started from home or /). '
            'Now: ${c.platform.files.workspaceDir}',
        advanced: true,
        (w) => TextField(
          controller: _workspace,
          style: mono(13.5),
          decoration: InputDecoration(labelText: 'Workspace folder', hintText: c.defaultWorkspace, isDense: true),
          onChanged: (v) => _apply(_s.copyWith(workspaceDir: v.trim()), debounce: true),
        ),
      ),
    ]),
    _Group('appearance', 'Appearance', [
      _Item(
        'Theme',
        'Light is the default; System follows the desktop.',
        (w) => _choices<AppTheme>(
          w,
          id: 'theme',
          title: 'Theme',
          desc: 'Light is the default; System follows the desktop.',
          options: AppTheme.values,
          value: _s.theme,
          label: (t) => t.label,
          columns: 3,
          onChanged: (v) => _apply(_s.copyWith(theme: v)),
        ),
      ),
    ]),
    _Group('account', 'Account', [
      if (_s.authMode == AuthMode.codex)
        _Item(
          'Codex login',
          'From ~/.codex/auth.json, refreshed automatically.',
          (w) => _codexStatus(),
        )
      else
        _Item(
          'API key',
          'Stored locally. Empty: uses \$OPENAI_API_KEY.',
          (w) => _apiKeyField(),
        ),
      _Item(
        'ChatGPT usage',
        '5-hour and weekly limits of your plan.',
        detail:
            'Below ${_s.usageGuardPercent}% left in either limit, delegation and compaction use gpt-6-luna.',
        (w) => CodexUsageMeter(controller: widget.controller),
      ),
      _Item(
        'Test connection',
        'Checks the credentials without starting a session.',
        advanced: true,
        (w) => _testButton(),
      ),
    ]),
    if (c.platform.audio is AudioRouted)
      _Group('android', 'Android', [
        _Item(
          'Screen control',
          'Accessibility service for clicking, typing and reading other apps.',
          (w) => const AndroidAccessibilityPanel(),
          keywords: 'accessibility battery background',
        ),
        _Item(
          'Audio route',
          'Phone uses the call path with echo cancellation.',
          (w) => _choices<AndroidAudioRoute>(
            w,
            id: 'android-audio-route',
            title: 'Audio route',
            desc: 'Phone uses the call path with echo cancellation.',
            options: AndroidAudioRoute.values,
            value: _s.androidAudioRoute,
            label: (r) => r == AndroidAudioRoute.phone ? 'Phone (echo cancellation, default)' : 'Media',
            hint: (r) => r == AndroidAudioRoute.phone
                ? 'Call audio: loudspeaker or headset, call volume'
                : 'Media audio and volume; weaker echo cancellation',
            columns: 1,
            onChanged: (v) => _apply(_s.copyWith(androidAudioRoute: v)),
          ),
        ),
      ]),
    _Group('about', 'Help & about', moreLabel: 'Keyboard shortcuts', [
      _Item('About', 'Runtime details for troubleshooting.', (w) => _about(), full: true),
      _Item(
        'Keyboard shortcuts',
        'Desktop keyboard controls.',
        advanced: true,
        full: true,
        (w) => _shortcuts(),
        keywords: _shortcutItems.map((e) => '${e.$1.join(' ')} ${e.$2}').join(' '),
      ),
    ]),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= _sideBySide;
      final q = _query.trim().toLowerCase();
      final children = <Widget>[];
      for (final g in _groups()) {
        bool match(_Item i) =>
            q.isEmpty || '${g.title} ${i.title} ${i.hint} ${i.detail ?? ''} ${i.keywords}'.toLowerCase().contains(q);
        final basic = [for (final i in g.items.where((i) => !i.advanced)) if (match(i)) i];
        final adv = [for (final i in g.items.where((i) => i.advanced)) if (match(i)) i];
        if (basic.isEmpty && adv.isEmpty) continue;
        final open = q.isNotEmpty || _open.contains(g.id);
        final shown = [...basic, if (open) ...adv];
        children.add(
          Column(
            key: ValueKey('settings-group-${g.id}'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(0, children.isEmpty ? 8 : 28, 0, 4),
                child: Semantics(
                  header: true,
                  child: Text(g.title, style: body(13, weight: FontWeight.w600, color: WoiColors.cyan)),
                ),
              ),
              for (var k = 0; k < shown.length; k++) ...[
                if (k > 0) const Divider(height: 1),
                shown[k].full ? shown[k].build(wide) : _wrap(wide, shown[k]),
              ],
              if (adv.isNotEmpty && q.isEmpty) ...[
                if (shown.isNotEmpty) const Divider(height: 1),
                _advancedToggle(g, adv.length, open),
              ],
            ],
          ),
        );
      }
      if (children.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Text('No settings match "$_query"', style: body(13, color: WoiColors.textDim)),
            ),
          ),
        );
      }
      final hPad = wide ? 24.0 : 16.0;
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            children: [
              Padding(padding: EdgeInsets.fromLTRB(hPad, wide ? 12 : 8, hPad, 4), child: _searchField()),
              Expanded(
                child: ListView(
                  key: const ValueKey('settings-list'),
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 24),
                  children: [
                    ...children,
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Center(
                        child: Text('Changes save automatically', style: body(12, color: WoiColors.textFaint)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _searchField() => TextField(
    key: const ValueKey('settings-search'),
    controller: _search,
    onChanged: (v) => setState(() => _query = v),
    style: body(14),
    decoration: InputDecoration(
      isDense: true,
      hintText: 'Search settings',
      prefixIcon: const Icon(Icons.search_rounded, size: 18),
      suffixIcon: _query.isEmpty
          ? null
          : IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => setState(() {
                _search.clear();
                _query = '';
              }),
            ),
    ),
  );

  Widget _advancedToggle(_Group g, int n, bool open) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      key: ValueKey('advanced-${g.id}'),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, kTouchTarget),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        foregroundColor: WoiColors.textDim,
      ),
      onPressed: () => setState(() => open ? _open.remove(g.id) : _open.add(g.id)),
      icon: AnimatedRotation(
        turns: open ? 0.5 : 0,
        duration: WoiMotion.fast,
        child: const Icon(Icons.expand_more_rounded, size: 18),
      ),
      label: Text(
        open ? 'Hide ${g.moreLabel.toLowerCase()}' : '${g.moreLabel} ($n)',
        style: body(13, weight: FontWeight.w500),
      ),
    ),
  );

  /// Choice lists lay themselves out; other items get a [_row].
  Widget _wrap(bool wide, _Item i) {
    final w = i.build(wide);
    if (w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('choices-')) return w;
    return _row(wide, i.title, i.hint, w, detail: i.detail);
  }

  /// The label and its one-line hint (full text in a tooltip when there is more).
  Widget _label(String title, String desc, String? detail) {
    final hint = Text(
      desc,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: body(12.5, color: WoiColors.textDim, height: 1.35),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: body(14, weight: FontWeight.w500)),
        const SizedBox(height: 2),
        detail == null ? hint : Tooltip(message: '$desc\n$detail', waitDuration: WoiMotion.slow, child: hint),
      ],
    );
  }

  /// Label + hint on the left, control right-aligned (stacked on phone).
  Widget _row(bool wide, String title, String desc, Widget control, {String? detail}) {
    final isSwitch = control is _SwitchBox;
    final text = _label(title, desc, detail);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: wide || isSwitch
          ? Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: 24),
                isSwitch ? control : SizedBox(width: 320, child: control),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [text, const SizedBox(height: 8), control],
            ),
    );
  }

  Widget _switch(bool wide, bool value, ValueChanged<bool> onChanged, {Key? key}) =>
      _SwitchBox(child: Switch(key: key, value: value, onChanged: onChanged));

  static const _shortcutItems = [
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

  Widget _shortcuts() => Padding(
    key: const ValueKey('settings-shortcuts'),
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      children: [
        for (final (keys, label) in _shortcutItems)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(width: 130, child: Wrap(spacing: 4, children: [for (final k in keys) KeyCap(k)])),
                Expanded(
                  child: Text(label, style: body(13, color: WoiColors.textDim)),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  Widget _about() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      children: [
        _kv('Voice backend', c.pipeline.backend?.runtimeType.toString() ?? '—'),
        _kv('Audio', c.platform.audio.description),
        _kv('Data folder', c.platform.paths.dataDir),
      ],
    ),
  );


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
    String? detail,
    List<Widget> extra = const [],
  }) {
    final cols = wide ? (columns ?? 1) : (columns ?? 1).clamp(1, 2);
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
    final radios = RadioGroup<T>(
      groupValue: value,
      onChanged: (v) => v == null ? null : onChanged(v),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...rows, ...extra]),
    );
    final text = Semantics(header: true, child: _label(title, desc, detail));
    return Padding(
      key: ValueKey('choices-$id'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(padding: const EdgeInsets.only(top: 8), child: text),
                ),
                const SizedBox(width: 24),
                SizedBox(width: 400, child: radios),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [text, const SizedBox(height: 4), radios],
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
      columns: 1,
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

/// Index of the [kScreenshotScales] entry nearest [scale].
int _scaleIndex(double scale) {
  var best = 0;
  for (var i = 1; i < kScreenshotScales.length; i++) {
    if ((kScreenshotScales[i] - scale).abs() < (kScreenshotScales[best] - scale).abs()) best = i;
  }
  return best;
}

String _scaleLabel(double scale) => scale <= 0 ? 'Screen width (dp)' : '${(scale * 100).round()} %';

class _Item {
  _Item(
    this.title,
    this.hint,
    this.build, {
    this.detail,
    this.advanced = false,
    this.full = false,
    this.keywords = '',
  });
  final String title;

  /// One line under the title; [detail] adds the rest in a tooltip.
  final String hint;
  final String? detail;
  final Widget Function(bool wide) build;

  /// Behind the group's expander.
  final bool advanced;

  /// Builds its own full-width layout (no label row).
  final bool full;

  /// Extra search terms.
  final String keywords;
}

class _Group {
  _Group(this.id, this.title, this.items, {this.moreLabel = 'Advanced'});
  final String id;
  final String title;
  final List<_Item> items;
  final String moreLabel;
}

/// A switch stays on the label's row even on phones.
class _SwitchBox extends StatelessWidget {
  const _SwitchBox({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}
