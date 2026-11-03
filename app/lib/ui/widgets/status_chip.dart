import 'package:flutter/material.dart';

import '../../core/pipeline/turn_pipeline.dart';
import '../../core/settings/settings.dart';
import '../theme.dart';

/// Connection state as shown to the user.
enum LinkState { connected, connecting, reconnecting, offline, error }

LinkState linkStateFor(SessionStatus s, {required bool wasConnected}) => switch (s) {
  SessionStatus.connected => LinkState.connected,
  SessionStatus.connecting => wasConnected ? LinkState.reconnecting : LinkState.connecting,
  SessionStatus.disconnected => LinkState.offline,
  SessionStatus.error => LinkState.error,
};

String linkLabel(LinkState s) => switch (s) {
  LinkState.connected => 'connected',
  LinkState.connecting => 'connecting…',
  LinkState.reconnecting => 'reconnecting…',
  LinkState.offline => 'offline',
  LinkState.error => 'error',
};

Color linkColor(LinkState s) => switch (s) {
  LinkState.connected => WoiColors.mint,
  LinkState.connecting || LinkState.reconnecting => WoiColors.amber,
  LinkState.offline => WoiColors.textDim,
  LinkState.error => WoiColors.red,
};

String backendShortName(BackendMode m) => switch (m) {
  BackendMode.gptLive => 'gpt-live · WebRTC',
  BackendMode.direct => 'Realtime · WebSocket',
  BackendMode.apiKey => 'Realtime · API key',
};

/// "gpt-live-1.1 · connected" with a pulsing dot, a details tooltip and an
/// inline retry button when the link is down.
class ConnectionStatusChip extends StatefulWidget {
  const ConnectionStatusChip({
    super.key,
    required this.state,
    required this.model,
    required this.backend,
    this.voice,
    this.detail,
    this.onRetry,
    this.compact = false,
  });

  final LinkState state;
  final String model;
  final BackendMode backend;
  final String? voice;
  final String? detail;
  final VoidCallback? onRetry;

  /// Phone header: dot + short label only.
  final bool compact;

  @override
  State<ConnectionStatusChip> createState() => _ConnectionStatusChipState();
}

class _ConnectionStatusChipState extends State<ConnectionStatusChip> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  bool get _busy => widget.state == LinkState.connecting || widget.state == LinkState.reconnecting;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ConnectionStatusChip old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final want = _busy || widget.state == LinkState.connected;
    if (want && !_pulse.isAnimating) _pulse.repeat();
    if (!want && _pulse.isAnimating) _pulse.stop();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = linkColor(widget.state);
    final label = linkLabel(widget.state);
    final down = widget.state == LinkState.error || widget.state == LinkState.offline;
    final tooltip = [
      backendShortName(widget.backend),
      'Model: ${widget.model}${widget.voice != null ? ' · voice ${widget.voice}' : ''}',
      'Status: $label',
      if (widget.detail != null && widget.detail!.isNotEmpty) widget.detail!,
      if (down && widget.onRetry != null) 'Click to retry',
    ].join('\n');

    final dot = AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final v = _pulse.value;
        return SizedBox.square(
          dimension: 14,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (!down)
                Container(
                  width: 6 + 8 * v,
                  height: 6 + 8 * v,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: (1 - v) * (_busy ? 0.6 : 0.35)),
                  ),
                ),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: [BoxShadow(color: color.withValues(alpha: 0.8), blurRadius: 6)],
                ),
              ),
            ],
          ),
        );
      },
    );

    final text = widget.compact
        ? Text(
            widget.state == LinkState.connected ? shortModelName(widget.model) : label,
            style: _style(color, widget.compact),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          )
        : Text.rich(
            TextSpan(
              children: [
                TextSpan(text: widget.model, style: _style(WoiColors.text, false)),
                TextSpan(text: '  ·  ', style: _style(WoiColors.textFaint, false)),
                TextSpan(text: label, style: _style(color, false)),
              ],
            ),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          );

    final chip = AnimatedContainer(
      duration: WoiMotion.medium,
      padding: EdgeInsets.fromLTRB(8, 5, down && widget.onRetry != null ? 4 : 12, 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot,
          const SizedBox(width: 7),
          Flexible(child: text),
          if (down && widget.onRetry != null) ...[
            const SizedBox(width: 6),
            _RetryButton(color: color, onTap: widget.onRetry!),
          ],
        ],
      ),
    );

    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Connection: ${widget.model}, $label',
      child: Tooltip(message: tooltip, child: chip),
    );
  }

  TextStyle _style(Color c, bool compact) =>
      body(compact ? 12 : 12.5, weight: FontWeight.w600, color: c).copyWith(fontFeatures: kTabular);
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.color, required this.onTap});
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Retry connection',
    child: Material(
      color: color.withValues(alpha: 0.16),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.refresh_rounded, size: 14, color: color),
              const SizedBox(width: 4),
              Text('Retry', style: body(12, weight: FontWeight.w700, color: color)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Compact model label for tight headers: "gpt-live-1.1" -> "live-1.1".
String shortModelName(String model) => model.replaceFirst(RegExp(r'^gpt-'), '');
