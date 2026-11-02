import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../../core/auth/auth.dart';
import '../../core/settings/settings.dart';
import '../theme.dart';
import '../widgets/context_meter.dart';
import '../widgets/glass.dart';

/// All user settings. Changes apply immediately (text fields after a short
/// pause) and persist to ~/.local/share/woi/settings.json.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _s = widget.controller.settings;
  late final _apiKey = TextEditingController(text: _s.apiKey);
  late final _compressionModel = TextEditingController(text: _s.compressionModel);
  late final _delegateModel = TextEditingController(text: _s.delegateModel);
  bool _showKey = false;
  Timer? _debounce;

  void _apply(AppSettings next, {bool debounce = false}) {
    setState(() => _s = next);
    _debounce?.cancel();
    if (debounce) {
      _debounce = Timer(const Duration(milliseconds: 700), () => widget.controller.updateSettings(_s));
    } else {
      widget.controller.updateSettings(next);
    }
  }

  @override
  void dispose() {
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      widget.controller.updateSettings(_s);
    }
    _apiKey.dispose();
    _compressionModel.dispose();
    _delegateModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final sections = [
      _section('Connection', Icons.cloud_outlined, [
        _label('Authentication'),
        SegmentedButton<AuthMode>(
          showSelectedIcon: false,
          segments: [for (final m in AuthMode.values) ButtonSegment(value: m, label: Text(m.label))],
          selected: {_s.authMode},
          onSelectionChanged: (v) => _apply(_s.copyWith(authMode: v.first)),
        ),
        const SizedBox(height: 12),
        if (_s.authMode == AuthMode.codex) _codexStatus() else _apiKeyField(),
        const SizedBox(height: 18),
        _dropdown('Voice model', _s.voiceModel, kVoiceModels, (v) => _apply(_s.copyWith(voiceModel: v))),
        const SizedBox(height: 14),
        _dropdown('Voice', _s.voice, kVoices, (v) => _apply(_s.copyWith(voice: v))),
      ]),
      _section('Context & models', Icons.memory, [
        _label('Compaction threshold'),
        Row(
          children: [
            Expanded(
              child: Slider(
                min: 2000,
                max: 100000,
                divisions: 49,
                value: _s.compressionThreshold.clamp(2000, 100000).toDouble(),
                label: formatTokens(_s.compressionThreshold),
                onChanged: (v) => setState(() => _s = _s.copyWith(compressionThreshold: v.round())),
                onChangeEnd: (v) => _apply(_s.copyWith(compressionThreshold: v.round())),
              ),
            ),
            SizedBox(
              width: 72,
              child: Text(
                '${formatTokens(_s.compressionThreshold)} tok',
                textAlign: TextAlign.right,
                style: mono(13, color: WoiColors.cyan),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _textField(
          'Compression model',
          _compressionModel,
          'gpt-6-luna',
          (v) => _apply(_s.copyWith(compressionModel: v.trim().isEmpty ? 'gpt-6-luna' : v.trim()), debounce: true),
        ),
        const SizedBox(height: 14),
        _textField(
          'Delegate model',
          _delegateModel,
          'gpt-6.1-sol',
          (v) => _apply(_s.copyWith(delegateModel: v.trim().isEmpty ? 'gpt-6.1-sol' : v.trim()), debounce: true),
        ),
      ]),
      _section('Screen & safety', Icons.shield_outlined, [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Auto-screenshot when I speak', style: body(14)),
          subtitle: Text(
            'Captures the screen shortly after speech starts and sends it with your turn.',
            style: body(12, color: WoiColors.textDim),
          ),
          value: _s.autoScreenshot,
          onChanged: (v) => _apply(_s.copyWith(autoScreenshot: v)),
        ),
        _label('Screenshot delay'),
        Row(
          children: [
            Expanded(
              child: Slider(
                min: 0,
                max: 4000,
                divisions: 40,
                value: _s.screenshotDelayMs.clamp(0, 4000).toDouble(),
                label: '${(_s.screenshotDelayMs / 1000).toStringAsFixed(1)} s',
                onChanged: _s.autoScreenshot
                    ? (v) => setState(() => _s = _s.copyWith(screenshotDelayMs: v.round()))
                    : null,
                onChangeEnd: (v) => _apply(_s.copyWith(screenshotDelayMs: v.round())),
              ),
            ),
            SizedBox(
              width: 72,
              child: Text(
                '${(_s.screenshotDelayMs / 1000).toStringAsFixed(1)} s',
                textAlign: TextAlign.right,
                style: mono(13, color: WoiColors.cyan),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Confirm before running shell commands', style: body(14)),
          subtitle: Text(
            'File writes always require approval with a diff preview.',
            style: body(12, color: WoiColors.textDim),
          ),
          value: _s.confirmBeforeBash,
          onChanged: (v) => _apply(_s.copyWith(confirmBeforeBash: v)),
        ),
      ]),
      _section('About', Icons.info_outline, [
        _kv('Voice backend', widget.controller.pipeline.backend?.runtimeType.toString() ?? '—'),
        _kv('Audio', widget.controller.platform.audio.description),
        _kv('Data folder', widget.controller.platform.paths.dataDir),
      ]),
    ];

    return Scaffold(
      appBar: AppBar(title: Text('Settings', style: display(20))),
      body: WoiBackdrop(
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: wide ? 32 : 12, vertical: 12),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: wide
                      ? Wrap(
                          spacing: 20,
                          runSpacing: 20,
                          children: [for (final s in sections) SizedBox(width: 520, child: s)],
                        )
                      : Column(
                          children: [
                            for (final s in sections) Padding(padding: const EdgeInsets.only(bottom: 14), child: s),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(String title, IconData icon, List<Widget> children) => GlassPanel(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: WoiColors.cyan),
            const SizedBox(width: 10),
            Text(title, style: display(16)),
          ],
        ),
        const SizedBox(height: 16),
        ...children,
      ],
    ),
  );

  Widget _label(String s) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      s.toUpperCase(),
      style: body(11, weight: FontWeight.w700, color: WoiColors.textFaint).copyWith(letterSpacing: 1.4),
    ),
  );

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
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

  Widget _dropdown(String label, String value, List<String> options, ValueChanged<String> onChanged) {
    final items = {...options, value}.toList();
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final o in items)
          DropdownMenuItem(
            value: o,
            child: Text(o, style: body(14)),
          ),
      ],
      onChanged: (v) => v == null ? null : onChanged(v),
    );
  }

  Widget _textField(String label, TextEditingController c, String hint, ValueChanged<String> onChanged) => TextField(
    controller: c,
    style: mono(13.5),
    decoration: InputDecoration(labelText: label, hintText: hint),
    onChanged: onChanged,
  );

  Widget _apiKeyField() => TextField(
    controller: _apiKey,
    obscureText: !_showKey,
    autocorrect: false,
    enableSuggestions: false,
    style: mono(13.5),
    decoration: InputDecoration(
      labelText: 'API key',
      hintText: 'sk-…  (or leave empty to use \$OPENAI_API_KEY)',
      suffixIcon: IconButton(
        onPressed: () => setState(() => _showKey = !_showKey),
        icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
      ),
    ),
    onChanged: (v) => _apply(_s.copyWith(apiKey: v.trim()), debounce: true),
  );

  Widget _codexStatus() {
    final info = widget.controller.codexAuth;
    final ok = info?.isAvailable ?? false;
    final color = ok ? WoiColors.mint : WoiColors.amber;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.verified_user_outlined : Icons.warning_amber_rounded, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(info?.summary ?? 'Codex auth not loaded', style: body(13, color: WoiColors.text)),
          ),
          IconButton(
            tooltip: 'Reload ~/.codex/auth.json',
            onPressed: () async {
              await widget.controller.refreshCodexAuth();
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }
}
