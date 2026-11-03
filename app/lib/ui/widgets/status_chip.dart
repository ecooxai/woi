import 'package:flutter/material.dart';

import '../../core/pipeline/turn_pipeline.dart';
import '../../core/settings/settings.dart';
import '../theme.dart';

/// Connection state as shown to the user.
enum LinkState { connected, connecting, reconnecting, offline, error }

LinkState linkStateFor(SessionStatus s, {required bool wasConnected, bool reconnecting = false}) => switch (s) {
  SessionStatus.connected => LinkState.connected,
  _ when reconnecting => LinkState.reconnecting,
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

/// "gpt-live-1.1 · connected": a status dot, model and state, a details
/// tooltip and an inline Retry when the link is down. Static (no ticker):
/// motion lives in the voice indicator next to it.
class ConnectionStatusChip extends StatelessWidget {
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

  /// Phones: short model name (or the state when not connected).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = linkColor(state);
    final label = linkLabel(state);
    final down = state == LinkState.error || state == LinkState.offline;
    final tooltip = [
      backendShortName(backend),
      'Model: $model${voice != null ? ' · voice $voice' : ''}',
      'Status: $label',
      if (detail != null && detail!.isNotEmpty) detail!,
    ].join('\n');

    final dot = Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );

    final text = compact
        ? Text(
            state == LinkState.connected ? shortModelName(model) : label,
            style: _style(state == LinkState.connected ? WoiColors.textDim : color),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          )
        : Text.rich(
            TextSpan(
              children: [
                TextSpan(text: model, style: _style(WoiColors.textDim)),
                TextSpan(text: ' · ', style: _style(WoiColors.textFaint)),
                TextSpan(text: label, style: _style(state == LinkState.connected ? WoiColors.textDim : color)),
              ],
            ),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          );

    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Connection: $model, $label',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Tooltip(
              message: tooltip,
              child: Row(
                key: const ValueKey('connection-status'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  dot,
                  const SizedBox(width: 6),
                  Flexible(child: text),
                ],
              ),
            ),
          ),
          if (down && onRetry != null) ...[
            const SizedBox(width: 4),
            _RetryButton(color: color, onTap: onRetry!, large: compact),
          ],
        ],
      ),
    );
  }

  TextStyle _style(Color c) => body(12, weight: FontWeight.w500, color: c).copyWith(fontFeatures: kTabular);
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.color, required this.onTap, this.large = false});
  final Color color;
  final VoidCallback onTap;

  /// Phone: full 48dp hit target.
  final bool large;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Retry connection',
    excludeSemantics: true,
    child: Tooltip(
      message: 'Retry connection',
      child: InkWell(
        key: const ValueKey('retry-connection'),
        borderRadius: BorderRadius.circular(WoiRadii.sm),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: large ? kTouchTarget : 28, minWidth: large ? kTouchTarget : 0),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.refresh_rounded, size: 14, color: color),
                const SizedBox(width: 3),
                Text('Retry', style: body(12, weight: FontWeight.w600, color: color)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Compact model label for tight headers: "gpt-live-1.1" -> "live-1.1".
String shortModelName(String model) => model.replaceFirst(RegExp(r'^gpt-'), '');
