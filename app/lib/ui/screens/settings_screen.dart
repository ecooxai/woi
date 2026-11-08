import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_controller.dart';
import '../../platform/audio_io.dart';
import '../../platform/screen_capture.dart' show kScreenshotScales;
import '../../platform/android/android_accessibility.dart';
import '../../core/auth/auth.dart';
import '../../core/settings/settings.dart';
import '../../core/images/image_model_catalog.dart';
import '../../core/voice/backend_factory.dart';
import '../theme.dart';
import '../login/login_screen.dart';
import '../widgets/context_meter.dart';
import '../widgets/empty_state.dart' show KeyCap;
import '../widgets/usage_meter.dart';

/// Choices for the background models (a custom model id is also accepted).
const kCompressionModels = ['gpt-6-luna', 'gpt-6.1-sol'];
const kDelegateModels = ['gpt-6-luna', 'gpt-6.1-sol'];

enum _TestState { idle, testing, ok, failed }

/// Connection, models and everyday preferences, with one searchable Advanced
/// section. Changes apply immediately; text edits save after a short pause.
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
  late final _imageModel = TextEditingController(text: _s.imageModel);
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
  ImageModelCatalogResult? _imageCatalog;
  bool _loadingImageModels = false;
  int _imageCatalogRequest = 0;

  bool _advancedOpen = false;
  final _pending = <String, Object?>{};
  late AppSettings _observedSettings;
  CodexAuthInfo? _observedAuth;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _observedSettings = c.settings;
    _observedAuth = c.codexAuth;
    c.addListener(_onControllerChanged);
    unawaited(_refreshImageModels());
  }

  Map<String, TextEditingController> get _editors => {
    'apiKey': _apiKey,
    'compressionModel': _compressionModel,
    'delegateModel': _delegateModel,
    'imageModel': _imageModel,
    'workspaceDir': _workspace,
    'stopWords': _stopWords,
  };

  static bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  String _editorValue(String field, AppSettings settings) => switch (field) {
    'stopWords' => settings.stopWords.join(', '),
    _ => settings.toJson()[field] as String? ?? '',
  };

  void _onControllerChanged() {
    final settingsChanged = !identical(_observedSettings, c.settings);
    final authChanged = !identical(_observedAuth, c.codexAuth);
    if (!settingsChanged && !authChanged) return;
    final connectionChanged =
        _observedSettings.authMode != c.settings.authMode ||
        (_observedSettings.apiKey != c.settings.apiKey && c.settings.authMode == AuthMode.apiKey);
    if (settingsChanged) {
      final before = _observedSettings.toJson();
      final after = c.settings.toJson();
      _observedSettings = c.settings;
      for (final entry in _editors.entries) {
        // Only a real external change to this field replaces its text/caret.
        // Audio/auth notifications and unrelated settings leave drafts alone.
        if (!_pending.containsKey(entry.key) && !_same(before[entry.key], after[entry.key])) {
          final text = _editorValue(entry.key, c.settings);
          entry.value.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
        }
      }
      _s = AppSettings.fromJson({...after, ..._pending});
    }
    _observedAuth = c.codexAuth;
    if (connectionChanged || authChanged) _resetImageModels();
    if (mounted) setState(() {});
  }

  void _stage(AppSettings next, {String? field}) {
    final before = _s.toJson();
    final after = next.toJson();
    for (final key in after.keys) {
      if (!_same(before[key], after[key])) _pending[key] = after[key];
    }
    // A blank/whitespace draft may normalize to its old value but is still
    // being edited. Keep its controller untouched until this save completes.
    if (field != null) _pending[field] = after[field];
    setState(() => _s = AppSettings.fromJson({...c.settings.toJson(), ..._pending}));
  }

  void _apply(AppSettings next, {bool debounce = false, String? field}) {
    _stage(next, field: field);
    _debounce?.cancel();
    if (debounce) {
      _debounce = Timer(const Duration(milliseconds: 700), _flush);
    } else {
      _flush();
    }
  }

  void _preview(AppSettings next) => _stage(next);

  void _flush({AppController? controller}) {
    _debounce?.cancel();
    _debounce = null;
    if (_pending.isEmpty) return;
    final target = controller ?? c;
    final patch = Map<String, Object?>.of(_pending);
    // Merge only edited fields into the latest controller settings. Applying
    // the old whole form would erase an unrelated external update.
    final next = AppSettings.fromJson({...target.settings.toJson(), ...patch});
    final save = target.actions.updateSettings(next);
    // updateSettings publishes the new settings synchronously. Its listener
    // sees these keys as dirty and does not rewrite their text or selection.
    _pending.removeWhere((key, value) => patch.containsKey(key) && _same(patch[key], value));
    unawaited(save);
  }

  @override
  void didUpdateWidget(SettingsView old) {
    super.didUpdateWidget(old);
    if (identical(old.controller, c)) return;
    old.controller.removeListener(_onControllerChanged);
    _flush(controller: old.controller);
    _s = c.settings;
    _observedSettings = c.settings;
    _observedAuth = c.codexAuth;
    for (final entry in _editors.entries) {
      entry.value.text = _editorValue(entry.key, _s);
    }
    c.addListener(_onControllerChanged);
    _resetImageModels();
  }

  void _resetImageModels() {
    _imageCatalogRequest++;
    _loadingImageModels = false;
    _imageCatalog = null;
    unawaited(_refreshImageModels());
  }

  @override
  void dispose() {
    c.removeListener(_onControllerChanged);
    _flush();
    _apiKey.dispose();
    _compressionModel.dispose();
    _delegateModel.dispose();
    _imageModel.dispose();
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

  List<_Group> _mainGroups() => [
    _Group('connection', 'Connection', [
      _Item(
        'Backend',
        '',
        (w) => _quickChoices<AuthMode>(
          id: 'backend',
          options: AuthMode.values,
          value: _s.authMode,
          label: (v) => v == AuthMode.codex ? 'Codex login' : 'API',
          onChanged: (v) => _apply(_s.withAuthMode(v)),
        ),
        inline: true,
        keywords: 'account connection codex login api key',
      ),
      if (_s.authMode == AuthMode.codex)
        _Item(
          'Codex account',
          '',
          (w) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _codexStatus(),
              const SizedBox(height: 12),
              CodexUsageMeter(controller: c),
            ],
          ),
          keywords: 'account chatgpt authentication sign in refresh usage limits quota reset',
        )
      else
        _Item(
          'API key',
          'Stored locally. Leave empty to use OPENAI_API_KEY.',
          (w) => _apiKeyField(),
          keywords: 'credentials access authentication reveal',
        ),
    ]),
    _Group('model', 'Model', [
      _Item(
        'Audio model',
        '',
        (w) => _audioModels(),
        keywords: 'voice speech realtime live ${_s.voiceModel} ${_s.realtimeModel}',
      ),
      _Item(
        'Text model',
        'For reasoning and delegated tasks.',
        (w) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _modelControl(
              id: 'delegate-model',
              options: kDelegateModels,
              value: _s.delegateModel,
              ctl: _delegateModel,
              fallback: 'gpt-6-luna',
              set: (v, {debounce = false}) => _apply(
                _s.copyWith(delegateModel: v),
                debounce: debounce,
                field: 'delegateModel',
              ),
            ),
            _effectiveModelNotice(),
          ],
        ),
        keywords: 'delegation background reasoning usage guard effective ${_s.delegateModel}',
      ),
      _Item('Voice', '', (w) => _voices(), keywords: 'speech sound marin echo ${_s.activeVoice}'),
      _Item(
        'Image model',
        'Generate images in the background and show them in chat.',
        (w) => _imageModels(),
        keywords: 'image generation drawing picture photo flare ${_s.imageModel}',
      ),
      _Item(
        'Image size',
        'Width × height in pixels.',
        (w) => _select<String>(
          id: 'image-size',
          options: AppSettings.imageSizeChoices,
          value: _s.imageSize,
          label: (v) => v == 'auto' ? 'Auto' : v.replaceAll('x', ' × '),
          onChanged: (v) => _apply(_s.copyWith(imageSize: v)),
        ),
        keywords: 'image generation resolution dimensions square portrait landscape auto ${_s.imageSize}',
      ),
      _Item(
        'Image format',
        'Format for generated image files.',
        (w) => _quickChoices<String>(
          id: 'image-format',
          options: AppSettings.imageFormatChoices,
          value: _s.imageFormat,
          label: (v) => switch (v) {
            'jpeg' => 'JPG',
            'webp' => 'WebP',
            _ => v.toUpperCase(),
          },
          onChanged: (v) => _apply(_s.copyWith(imageFormat: v)),
        ),
        inline: true,
        keywords: 'image generation file format jpg jpeg png webp ${_s.imageFormat}',
      ),
      _Item(
        'Image quality',
        'Low uses less time and tokens.',
        (w) => _quickChoices<String>(
          id: 'image-quality',
          options: const ['low', 'medium', 'high', 'xhigh', 'max', 'auto'],
          value: _s.imageQuality,
          label: (v) => '${v[0].toUpperCase()}${v.substring(1)}',
          onChanged: (v) => _apply(_s.copyWith(imageQuality: v)),
        ),
        inline: true,
        keywords: 'image generation render quality fast low medium high xhigh max auto',
      ),
    ]),
    _Group('preferences', 'Preferences', [
      _Item(
        'Web search',
        'Let the assistant search the internet for current information.',
        (w) => _switch(w, _s.webSearchEnabled, (v) => _apply(_s.copyWith(webSearchEnabled: v))),
        keywords: 'search internet web browse online sources tools',
      ),
      _Item(
        'Luna pointer agent',
        'Use a dedicated gpt-6-luna agent for clicks and pointer movement.',
        (w) => _switch(
          w,
          _s.useLunaPointer,
          (v) => _apply(_s.copyWith(useLunaPointer: v)),
          key: const ValueKey('use-luna-pointer-switch'),
        ),
        keywords: 'pointer mouse click move luna agent control',
      ),
      _Item(
        'Theme',
        '',
        (w) => _quickChoices<AppTheme>(
          id: 'theme',
          options: AppTheme.values,
          value: _s.theme,
          label: (v) => v.label,
          onChanged: (v) => _apply(_s.copyWith(theme: v)),
        ),
        inline: true,
        keywords: 'appearance light dark system',
      ),
      _Item(
        'Echo cancellation',
        'Keep speaker audio out of the microphone.',
        (w) => _switch(w, _s.echoCancellation, (v) => _apply(_s.copyWith(echoCancellation: v))),
        keywords: 'audio speakers music videos',
      ),
      _Item(
        'Auto-screenshot',
        'Include the screen with spoken turns.',
        (w) => _switch(w, _s.autoScreenshot, (v) => _apply(_s.copyWith(autoScreenshot: v))),
        keywords: 'screen screenshot capture when I speak',
      ),
      _Item(
        'Confirm shell commands',
        'Ask before running commands.',
        (w) => _switch(w, _s.confirmBeforeBash, (v) => _apply(_s.copyWith(confirmBeforeBash: v))),
        keywords: 'bash terminal safety approval command confirmation',
      ),
    ]),
  ];

  List<_Group> _advancedGroups() => [
    _Group('audio', 'Voice & audio', [
      if (_s.backendMode != BackendMode.gptLive) ...[
        _Item(
          'Reply delay',
          'Pause before ending your turn.',
          (w) => _slider(
            value: _s.replyDelayMs.toDouble(),
            min: kMinReplyDelayMs.toDouble(),
            max: kMaxReplyDelayMs.toDouble(),
            divisions: (kMaxReplyDelayMs - kMinReplyDelayMs) ~/ 100,
            label: '${(_s.replyDelayMs / 1000).toStringAsFixed(1)} s',
            semantic: 'Reply delay',
            onChanged: (v) => _preview(_s.copyWith(replyDelayMs: v.round())),
            onChangeEnd: (v) => _apply(_s.copyWith(replyDelayMs: v.round())),
          ),
          keywords: 'silence response timing',
        ),
        _Item(
          'Idle standby',
          'Reconnect when speech starts again.',
          detail:
              'Disconnect after this much silence while the microphone keeps listening. Off keeps the session open.',
          (w) => _slider(
            value: (_s.idleStandbySeconds ~/ 15).toDouble(),
            min: 0,
            max: (kMaxIdleStandbySeconds ~/ 15).toDouble(),
            divisions: kMaxIdleStandbySeconds ~/ 15,
            label: _standbyLabel(_s.idleStandbySeconds),
            semantic: 'Idle standby',
            onChanged: (v) => _preview(_s.copyWith(idleStandbySeconds: v.round() * 15)),
            onChangeEnd: (v) => _apply(_s.copyWith(idleStandbySeconds: v.round() * 15)),
          ),
          keywords: 'connection silence timeout power',
        ),
      ],
      _Item(
        'Thinking chime',
        'Play a soft chime while a reply is prepared.',
        (w) => _switch(w, _s.thinkingEarcon, (v) => _apply(_s.copyWith(thinkingEarcon: v))),
      ),
      _Item(
        'Stop word detection',
        'Recognize interruption words on this device.',
        detail: 'Listens while Woi speaks or is paused. Its own speech is ignored, and no audio leaves the device for this.',
        (w) => _switch(w, _s.stopWordDetection, (v) => _apply(_s.copyWith(stopWordDetection: v))),
        keywords: 'kws keyword spotting stop word interrupt barge-in offline',
      ),
      _Item(
        'Stop words',
        'Comma-separated English words or phrases.',
        (w) => TextField(
          key: const ValueKey('setting-stop-words'),
          controller: _stopWords,
          style: body(14),
          decoration: const InputDecoration(hintText: 'stop', isDense: true),
          onChanged: (v) => _apply(_s.copyWith(stopWords: parseStopWords(v)), debounce: true, field: 'stopWords'),
        ),
        keywords: 'kws keyword spotting interruption',
      ),
      if (_s.backendMode == BackendMode.gptLive) ...[
        _Item(
          'Realtime fallback model',
          'Used if the live audio session falls back.',
          (w) => _select<String>(
            id: 'fallback-model',
            options: {...kRealtimeModels, _s.realtimeModel}.toList(),
            value: _s.realtimeModel,
            monoText: true,
            onChanged: (v) => _apply(_s.copyWith(realtimeModel: v)),
          ),
          keywords: 'audio model realtime ${_s.realtimeModel}',
        ),
        _Item(
          'Use realtime at the usage limit',
          'Use the fallback model until the live limit resets.',
          (w) => _switch(w, _s.fallbackToDirectOnLimit, (v) => _apply(_s.copyWith(fallbackToDirectOnLimit: v))),
          keywords: 'direct realtime fallback 429 rate usage limit',
        ),
      ],
    ]),
    _Group('screen', 'Screen & camera', [
      _Item(
        'Screenshot delay',
        'Wait for menus or pages to finish opening.',
        (w) => _slider(
          value: _s.screenshotDelayMs.clamp(0, 4000).toDouble(),
          min: 0,
          max: 4000,
          divisions: 40,
          label: '${(_s.screenshotDelayMs / 1000).toStringAsFixed(1)} s',
          semantic: 'Screenshot delay',
          onChanged: _s.autoScreenshot ? (v) => _preview(_s.copyWith(screenshotDelayMs: v.round())) : null,
          onChangeEnd: (v) => _apply(_s.copyWith(screenshotDelayMs: v.round())),
        ),
      ),
      _Item(
        'Screenshot size',
        'Scale images sent to the model.',
        detail: 'Screen width uses the device width in dp. Other choices use a share of the original pixels; images are never enlarged.',
        (w) {
          final idx = _scaleIndex(_s.screenshotScale);
          return _slider(
            value: idx.toDouble(),
            min: 0,
            max: kScreenshotScales.length - 1.0,
            divisions: kScreenshotScales.length - 1,
            label: _scaleLabel(kScreenshotScales[idx]),
            semantic: 'Screenshot size',
            onChanged: (v) => _preview(_s.copyWith(screenshotScale: kScreenshotScales[v.round()])),
            onChangeEnd: (v) => _apply(_s.copyWith(screenshotScale: kScreenshotScales[v.round()])),
          );
        },
        keywords: 'screenshot resolution scale image size downscale dp width vision screen share assist',
      ),
      _Item(
        'Screenshot JPEG quality',
        'Balance file size and text clarity.',
        (w) => _slider(
          value: _s.screenshotJpegQuality.clamp(50, 100).toDouble(),
          min: 50,
          max: 100,
          divisions: 10,
          label: '${_s.screenshotJpegQuality}',
          semantic: 'Screenshot JPEG quality',
          onChanged: (v) => _preview(_s.copyWith(screenshotJpegQuality: v.round())),
          onChangeEnd: (v) => _apply(_s.copyWith(screenshotJpegQuality: v.round())),
        ),
        keywords: 'screenshot jpeg jpg quality compression file size image',
      ),
      _Item(
        'Camera and screenshots',
        'Choose what accompanies a turn when the camera is on.',
        (w) => _select<bool>(
          id: 'camera-screenshot',
          options: const [false, true],
          value: _s.cameraReplacesScreenshot,
          label: (v) => v ? 'Camera replaces screenshot' : 'Camera and screenshot',
          onChanged: (v) => _apply(_s.copyWith(cameraReplacesScreenshot: v)),
        ),
      ),
      _Item(
        'Screenshot tiers',
        'Full images, then scaled images, then descriptions.',
        (w) => Row(
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
        keywords: 'full scaled older images history image count divisor',
      ),
    ]),
    _Group('memory', 'Memory', [
      _Item(
        'Compaction threshold',
        'Summarize older turns past this context size.',
        (w) => _slider(
          value: _s.compressionThreshold.clamp(2000, 100000).toDouble(),
          min: 2000,
          max: 100000,
          divisions: 49,
          label: '${formatTokens(_s.compressionThreshold)} tok',
          semantic: 'Compaction threshold',
          onChanged: (v) => _preview(_s.copyWith(compressionThreshold: v.round())),
          onChangeEnd: (v) => _apply(_s.copyWith(compressionThreshold: v.round())),
        ),
        keywords: 'context tokens compression summary',
      ),
      _Item(
        'Compression model',
        'Writes the context summary.',
        (w) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _modelControl(
              id: 'compression-model',
              options: kCompressionModels,
              value: _s.compressionModel,
              ctl: _compressionModel,
              fallback: 'gpt-6-luna',
              set: (v, {debounce = false}) => _apply(
                _s.copyWith(compressionModel: v),
                debounce: debounce,
                field: 'compressionModel',
              ),
            ),
            _effectiveModelNotice(compaction: true),
          ],
        ),
        keywords: 'context memory summary model ${_s.compressionModel}',
      ),
    ]),
    _Group('editing', 'Editing & terminal', [
      _Item(
        'AI edits',
        'Review the diff before an edit applies.',
        detail: 'Reject during the countdown with Esc or "reject". "Undo that" reverts the last edit.',
        (w) => _select<int>(
          id: 'edit-delay',
          options: {...kEditApplyDelays, _s.editApplyDelay}.toList(),
          value: _s.editApplyDelay,
          label: (v) => v == kRequireApproval ? 'Require approval' : (v == 0 ? 'Apply at once' : 'After $v s'),
          onChanged: (v) => _apply(_s.copyWith(editApplyDelay: v)),
        ),
        keywords: 'file note edit countdown delay approval undo',
      ),
      _Item(
        'Run in terminal',
        'Show shell commands in the Terminal tab.',
        (w) => _switch(
          w,
          _s.runBashInTerminal,
          (v) => _apply(_s.copyWith(runBashInTerminal: v)),
          key: const ValueKey('run-in-terminal-switch'),
        ),
        keywords: 'bash shell execution commands',
      ),
      _Item(
        'Workspace folder',
        'Base folder for relative paths and commands.',
        detail: 'Leave empty to use the launch folder. Current folder: ${c.platform.files.workspaceDir}',
        (w) => TextField(
          key: const ValueKey('setting-workspace'),
          controller: _workspace,
          style: mono(13.5),
          decoration: InputDecoration(hintText: c.defaultWorkspace, isDense: true),
          onChanged: (v) => _apply(_s.copyWith(workspaceDir: v.trim()), debounce: true, field: 'workspaceDir'),
        ),
        keywords: 'working directory path cwd files',
      ),
    ]),
    if (c.platform.audio is AudioRouted)
      _Group('android', 'Android', [
        _Item(
          'Screen control',
          'Accessibility and background access.',
          (w) => const AndroidAccessibilityPanel(),
          keywords: 'accessibility battery background enable permissions',
        ),
        _Item(
          'Audio route',
          'Phone uses call processing. Media keeps media volume with software echo cancellation.',
          (w) => _select<AndroidAudioRoute>(
            id: 'android-audio-route',
            options: AndroidAudioRoute.values,
            value: _s.androidAudioRoute,
            label: (v) => v == AndroidAudioRoute.phone ? 'Phone (echo cancellation)' : 'Media',
            onChanged: (v) => _apply(_s.copyWith(androidAudioRoute: v)),
          ),
          keywords: 'call media loudspeaker headset volume',
        ),
        _Item(
          'Keep connection after closing',
          'Keep an idle session ready for the next activation.',
          detail: 'The microphone stops when the assistant panel closes. Off drops the connection a few seconds later.',
          (w) => _select<int>(
            id: 'assistant-keep-alive',
            options: {...AppSettings.assistantKeepAliveChoices, _s.assistantKeepAliveSeconds}.toList(),
            value: _s.assistantKeepAliveSeconds,
            label: (v) => switch (v) {
              0 => 'Off',
              < 60 => '$v s',
              _ => '${v ~/ 60} min',
            },
            onChanged: (v) => _apply(_s.copyWith(assistantKeepAliveSeconds: v)),
          ),
          keywords: 'keep alive warm session assistant panel dismiss suspend latency background',
        ),
      ]),
    _Group('diagnostics', 'Connection & usage', [
      _Item(
        'Test connection',
        'Check credentials without starting a session.',
        (w) => _testButton(),
        keywords: 'network authentication credentials diagnostics',
      ),
    ]),
    _Group('about', 'Help & about', [
      _Item(
        'About',
        'Runtime details for troubleshooting.',
        (w) => _about(),
        full: true,
        keywords: 'backend audio data folder auth login diagnostics',
      ),
      _Item(
        'Keyboard shortcuts',
        '',
        (w) => _shortcuts(),
        full: true,
        keywords: _shortcutItems.map((e) => '${e.$1.join(' ')} ${e.$2}').join(' '),
      ),
    ]),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= _sideBySide;
      final q = _query.trim().toLowerCase();
      List<_Group> matching(List<_Group> groups) => [
        for (final g in groups)
          if (g.items.any((i) => _matches(g, i, q)))
            _Group(g.id, g.title, g.items.where((i) => _matches(g, i, q)).toList()),
      ];
      final main = matching(_mainGroups());
      final advanced = matching(_advancedGroups());
      final open = q.isNotEmpty || _advancedOpen;
      final children = <Widget>[
        for (final g in main) _section(g, wide),
        if (advanced.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: TextButton.icon(
              key: const ValueKey('advanced-settings'),
              style: TextButton.styleFrom(
                alignment: Alignment.centerLeft,
                minimumSize: const Size(double.infinity, kTouchTarget),
                padding: const EdgeInsets.symmetric(horizontal: 0),
                foregroundColor: WoiColors.text,
              ),
              onPressed: q.isNotEmpty ? null : () => setState(() => _advancedOpen = !_advancedOpen),
              icon: Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20),
              label: Text('Advanced', style: body(14, weight: FontWeight.w600)),
            ),
          ),
          if (open)
            for (final g in advanced) _section(g, wide, advanced: true),
        ],
      ];
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

  bool _matches(_Group g, _Item i, String q) =>
      q.isEmpty || '${g.title} ${i.title} ${i.hint} ${i.detail ?? ''} ${i.keywords}'.toLowerCase().contains(q);

  Widget _section(_Group g, bool wide, {bool advanced = false}) => Column(
    key: ValueKey('settings-group-${g.id}'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(0, advanced ? 16 : 20, 0, 4),
        child: Semantics(
          header: true,
          child: Text(
            g.title,
            style: body(13, weight: FontWeight.w600, color: advanced ? WoiColors.textDim : WoiColors.cyan),
          ),
        ),
      ),
      for (var i = 0; i < g.items.length; i++) ...[
        if (i > 0) const Divider(height: 1),
        g.items[i].full ? g.items[i].build(wide) : _wrap(wide, g.items[i]),
      ],
    ],
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

  Widget _wrap(bool wide, _Item i) => _row(wide, i.title, i.hint, i.build(wide), detail: i.detail, inline: i.inline);

  Widget _label(String title, String desc, String? detail) {
    final hint = Text(desc, style: body(12.5, color: WoiColors.textDim, height: 1.35));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: body(14, weight: FontWeight.w500)),
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 2),
          detail == null ? hint : Tooltip(message: '$desc\n$detail', waitDuration: WoiMotion.slow, child: hint),
        ],
      ],
    );
  }

  Widget _row(bool wide, String title, String desc, Widget control, {String? detail, bool inline = false}) {
    final isSwitch = control is _SwitchBox;
    final text = _label(title, desc, detail);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: wide || isSwitch || inline
          ? Row(
              children: [
                wide || isSwitch ? Expanded(child: text) : SizedBox(width: 76, child: text),
                SizedBox(width: wide ? 24 : 12),
                if (isSwitch) control else if (wide) SizedBox(width: 400, child: control) else Expanded(child: control),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [text, const SizedBox(height: 8), control],
            ),
    );
  }

  Widget _switch(bool wide, bool value, ValueChanged<bool> onChanged, {Key? key}) => _SwitchBox(
    child: Switch(key: key, value: value, onChanged: onChanged),
  );

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
        _kv('Codex login', c.codexAuth?.summary ?? 'Not loaded'),
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

  Widget _quickChoices<T>({
    required String id,
    required List<T> options,
    required T value,
    required ValueChanged<T> onChanged,
    String Function(T)? label,
    String Function(T)? keyFor,
    String? Function(T)? unavailable,
    bool monoText = false,
  }) => RadioGroup<T>(
    groupValue: value,
    onChanged: (v) {
      if (v != null && unavailable?.call(v) == null) onChanged(v);
    },
    child: Wrap(
      spacing: 8,
      children: [
        for (final v in options)
          Tooltip(
            message: unavailable?.call(v) ?? '',
            child: InkWell(
              key: ValueKey('radio-$id-${keyFor?.call(v) ?? (v is Enum ? v.name : v)}'),
              borderRadius: BorderRadius.circular(WoiRadii.md),
              onTap: unavailable?.call(v) == null ? () => onChanged(v) : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: kTouchTarget),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Radio<T>(value: v, enabled: unavailable?.call(v) == null, visualDensity: VisualDensity.compact),
                    Text(
                      label?.call(v) ?? '$v',
                      style: (monoText ? mono(13) : body(13.5)).copyWith(
                        color: unavailable?.call(v) == null ? WoiColors.text : WoiColors.textFaint,
                        fontWeight: v == value ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _select<T>({
    required String id,
    required List<T> options,
    required T? value,
    required ValueChanged<T> onChanged,
    String Function(T)? label,
    String? Function(T)? unavailable,
    String? hint,
    String? fieldLabel,
    bool monoText = false,
  }) {
    String name(T v) => label?.call(v) ?? '$v';
    final style = monoText ? mono(13) : body(13.5);
    return InputDecorator(
      decoration: InputDecoration(
        isDense: true,
        labelText: fieldLabel,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kTouchTarget),
          child: DropdownButton<T>(
            key: ValueKey('select-$id'),
            value: value,
            isExpanded: true,
            itemHeight: null,
            menuMaxHeight: 360,
            borderRadius: BorderRadius.circular(WoiRadii.md),
            dropdownColor: WoiColors.bg2,
            hint: hint == null ? null : Text(hint, style: style.copyWith(color: WoiColors.textDim)),
            selectedItemBuilder: (_) => [
              for (final v in options)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                    message: name(v),
                    child: Text(name(v), maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                  ),
                ),
            ],
            items: [
              for (final v in options)
                DropdownMenuItem<T>(
                  value: v,
                  enabled: unavailable?.call(v) == null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name(v),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: style.copyWith(
                            color: unavailable?.call(v) == null ? WoiColors.text : WoiColors.textFaint,
                          ),
                        ),
                        if (unavailable?.call(v) case final String reason)
                          Text(reason, style: body(11.5, color: WoiColors.textDim)),
                      ],
                    ),
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null && unavailable?.call(v) == null) onChanged(v);
            },
          ),
        ),
      ),
    );
  }

  Widget _audioModels() {
    const quick = [(AudioModelFamily.realtime, 'gpt-realtime-2.1'), (AudioModelFamily.live, 'gpt-live-1.1')];
    final current = (_s.audioModelFamily, _s.audioModel);
    final more = <(AudioModelFamily, String)>{
      for (final v in {...kRealtimeModels, _s.realtimeModel}) (AudioModelFamily.realtime, v),
      for (final v in {...kVoiceModels, _s.voiceModel}) (AudioModelFamily.live, v),
    }.where((v) => !quick.contains(v)).toList();
    String? unavailable((AudioModelFamily, String) v) =>
        _s.audioModelUnavailableReason(v.$1, liveAvailable: GptLiveHook.isRegistered);
    void select((AudioModelFamily, String) v) {
      try {
        _apply(_s.withAudioModel(v.$2, family: v.$1, liveAvailable: GptLiveHook.isRegistered));
      } on ArgumentError catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${e.message}')));
      }
    }

    final liveReason = _s.audioModelUnavailableReason(AudioModelFamily.live, liveAvailable: GptLiveHook.isRegistered);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _quickChoices<(AudioModelFamily, String)>(
          id: 'audio-model',
          options: quick,
          value: current,
          label: (v) => v.$2,
          keyFor: (v) => v.$2,
          unavailable: unavailable,
          monoText: true,
          onChanged: select,
        ),
        _select<(AudioModelFamily, String)>(
          id: 'audio-model',
          options: more,
          value: more.contains(current) ? current : null,
          label: (v) => v.$2,
          unavailable: unavailable,
          hint: 'More models',
          monoText: true,
          onChanged: select,
        ),
        if (liveReason != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(liveReason, style: body(12, color: WoiColors.textDim)),
          ),
      ],
    );
  }

  Widget _voices() {
    const quick = ['marin', 'echo'];
    final live = _s.audioModelFamily == AudioModelFamily.live;
    final more = <String>{..._s.voiceChoices, _s.activeVoice}.where((v) => live || !quick.contains(v)).toList();
    String? unavailable(String v) => _s.voiceChoices.contains(v) ? null : 'Unavailable for this audio model.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _quickChoices<String>(
          id: 'voice',
          options: quick,
          value: _s.activeVoice,
          label: _cap,
          unavailable: unavailable,
          onChanged: (v) => _apply(_s.withActiveVoice(v)),
        ),
        _select<String>(
          id: 'voice',
          options: more,
          value: more.contains(_s.activeVoice) ? _s.activeVoice : null,
          label: _cap,
          unavailable: unavailable,
          hint: 'More voices',
          onChanged: (v) => _apply(_s.withActiveVoice(v)),
        ),
        if (live)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Marin and Echo are unavailable for this audio model.',
              style: body(12, color: WoiColors.textDim),
            ),
          ),
      ],
    );
  }

  static const _custom = '\u0000custom';

  Widget _modelControl({
    required String id,
    required List<String> options,
    required String value,
    required TextEditingController ctl,
    required String fallback,
    required void Function(String v, {bool debounce}) set,
  }) {
    final custom = _customModel.contains(id) || !options.contains(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _select<String>(
          id: id,
          options: {...options, value, _custom}.toList(),
          value: value,
          label: (v) => v == _custom ? 'Custom model…' : v,
          monoText: true,
          onChanged: (v) {
            if (v == _custom) {
              setState(() => _customModel.add(id));
              return;
            }
            setState(() => _customModel.remove(id));
            ctl.text = v;
            set(v);
          },
        ),
        if (custom)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              key: ValueKey('custom-$id'),
              controller: ctl,
              style: mono(13.5),
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(hintText: 'Model ID', helperText: 'Empty uses $fallback.', isDense: true),
              onChanged: (v) => set(v.trim().isEmpty ? fallback : v.trim(), debounce: true),
            ),
          ),
      ],
    );
  }

  Future<void> _refreshImageModels() async {
    final request = ++_imageCatalogRequest;
    if (mounted) setState(() => _loadingImageModels = true);
    ImageModelCatalogResult result;
    try {
      result = await ImageModelCatalog(credentials: c.credentials).discover().timeout(const Duration(seconds: 25));
    } catch (_) {
      result = const ImageModelCatalogResult(
        models: kDocumentedImageModels,
        source: 'Documented models',
        notice: 'Could not check this account. Refresh to try again; model access is checked when generating.',
      );
    }
    if (!mounted || request != _imageCatalogRequest) return;
    setState(() {
      _loadingImageModels = false;
      _imageCatalog = result;
    });
  }

  Widget _imageModels() {
    final catalog = _imageCatalog;
    final options = <String>{
      kDefaultImageModel,
      ...?catalog?.models,
      if (catalog == null) ...kDocumentedImageModels,
    }.toList();
    final selectedListed = catalog?.models.contains(_s.imageModel) ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _modelControl(
          id: 'image-model',
          options: options,
          value: _s.imageModel,
          ctl: _imageModel,
          fallback: kDefaultImageModel,
          set: (v, {debounce = false}) => _apply(
            _s.copyWith(imageModel: v),
            debounce: debounce,
            field: 'imageModel',
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                _loadingImageModels ? 'Checking available image models…' : catalog?.source ?? 'Documented models',
                key: const ValueKey('image-model-source'),
                style: body(12, color: WoiColors.textDim),
              ),
            ),
            IconButton(
              key: const ValueKey('refresh-image-models'),
              tooltip: 'Refresh image models',
              onPressed: _loadingImageModels ? null : _refreshImageModels,
              icon: _loadingImageModels
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded, size: 18),
            ),
          ],
        ),
        if (!_loadingImageModels && catalog?.notice != null)
          Text(catalog!.notice!, style: body(12, color: WoiColors.textDim)),
        if (!_loadingImageModels && catalog != null && !selectedListed)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Availability of this model has not been verified for this account.',
              key: const ValueKey('unverified-image-model'),
              style: body(12, color: WoiColors.amber),
            ),
          ),
      ],
    );
  }

  Widget _effectiveModelNotice({bool compaction = false}) => ListenableBuilder(
    listenable: Listenable.merge([c, c.usage]),
    builder: (context, _) {
      final choice = compaction ? c.compactionChoice : c.delegationChoice;
      if (!choice.downgraded) return const SizedBox.shrink();
      return Padding(
        key: ValueKey(compaction ? 'effective-compression-model' : 'effective-text-model'),
        padding: const EdgeInsets.only(top: 8),
        child: Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Active ${compaction ? 'compression' : 'text'} model: ${choice.model}',
                style: body(12.5, color: WoiColors.amber, weight: FontWeight.w600),
              ),
              if (choice.reason != null) Text(choice.reason!, style: body(12, color: WoiColors.textDim)),
            ],
          ),
        ),
      );
    },
  );

  Widget _dropdown(String label, String value, List<String> options, ValueChanged<String> onChanged) => _select<String>(
    id: 'tier-${label.toLowerCase()}',
    options: {...options, value}.toList(),
    value: value,
    fieldLabel: label,
    onChanged: onChanged,
    monoText: true,
  );

  Widget _apiKeyField() => TextField(
    key: const ValueKey('setting-api-key'),
    controller: _apiKey,
    obscureText: !_showKey,
    obscuringCharacter: '•',
    autocorrect: false,
    enableSuggestions: false,
    style: mono(13.5),
    decoration: InputDecoration(
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
      _apply(_s.copyWith(apiKey: v.trim()), debounce: true, field: 'apiKey');
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

  Future<void> _signIn() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (loginContext) => CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(loginContext).pop()},
          child: Focus(
            autofocus: true,
            child: Scaffold(
              appBar: AppBar(
                leading: BackButton(onPressed: () => Navigator.of(loginContext).pop()),
                title: const Text('Codex login'),
              ),
              body: LoginScreen(
                createFlow: c.createLoginFlow,
                onSignedIn: () async {
                  await c.refreshCodexAuth();
                  // Signing in refreshes the account without changing the audio model.
                  if (loginContext.mounted) Navigator.of(loginContext).pop();
                },
                onApiKey: (key) async {
                  if (mounted) {
                    _apiKey.text = key;
                    _apply(_s.copyWith(apiKey: key).withAuthMode(AuthMode.apiKey), field: 'apiKey');
                  }
                  if (loginContext.mounted) Navigator.of(loginContext).pop();
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _codexStatus() {
    final info = c.codexAuth;
    final ok = info?.isAvailable ?? false;
    final color = ok ? WoiColors.mint : WoiColors.amber;
    final account = info?.accountId;
    final suffix = account == null || account.isEmpty
        ? ''
        : ' · account …${account.substring(account.length > 6 ? account.length - 6 : 0)}';
    final status = info?.error != null
        ? 'Login needs attention'
        : ok
        ? 'Signed in$suffix'
        : 'Not signed in';
    return Container(
      key: const ValueKey('codex-login-status'),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(WoiRadii.md),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.verified_user_outlined : Icons.account_circle_outlined, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(status, style: body(13))),
          if (!ok) TextButton(onPressed: _signIn, child: const Text('Sign in')),
          IconButton(
            tooltip: 'Refresh Codex login',
            onPressed: c.refreshCodexAuth,
            icon: const Icon(Icons.refresh, size: 20),
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
  _Item(this.title, this.hint, this.build, {this.detail, this.full = false, this.inline = false, this.keywords = ''});
  final String title;
  final String hint;
  final String? detail;
  final Widget Function(bool wide) build;
  final bool full;
  final bool inline;
  final String keywords;
}

class _Group {
  _Group(this.id, this.title, this.items);
  final String id;
  final String title;
  final List<_Item> items;
}

/// A switch stays on the label's row even on phones.
class _SwitchBox extends StatelessWidget {
  const _SwitchBox({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

String _standbyLabel(int s) => s == 0
    ? 'Off'
    : s % 60 == 0
    ? '${s ~/ 60} min'
    : s < 60
    ? '$s s'
    : '${s ~/ 60} min ${s % 60} s';
