import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/message.dart';
import '../../platform/audio_io.dart';
import '../theme.dart';

/// Play/stop control for a recorded clip, with an animated progress ring.
class AudioClipButton extends StatefulWidget {
  const AudioClipButton({super.key, required this.clip, required this.audio, this.color = WoiColors.cyan});

  final AudioClip clip;
  final AudioIO audio;
  final Color color;

  @override
  State<AudioClipButton> createState() => _AudioClipButtonState();
}

class _AudioClipButtonState extends State<AudioClipButton> with SingleTickerProviderStateMixin {
  ClipPlayback? _playing;
  late final AnimationController _progress = AnimationController(vsync: this);

  Future<void> _toggle() async {
    final cur = _playing;
    if (cur != null) {
      await cur.stop();
      return;
    }
    try {
      final pb = await widget.audio.playFile(widget.clip.path);
      setState(() => _playing = pb);
      _progress.duration = Duration(milliseconds: widget.clip.durationMs.clamp(1, 1 << 30));
      _progress.forward(from: 0);
      await pb.done;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cannot play audio: $e')));
      }
    } finally {
      if (mounted) {
        _progress.stop();
        _progress.value = 0;
        setState(() => _playing = null);
      }
    }
  }

  @override
  void dispose() {
    unawaited(_playing?.stop());
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secs = (widget.clip.durationMs / 1000).toStringAsFixed(1);
    final playing = _playing != null;
    return Tooltip(
      message: playing ? 'Stop' : 'Play recording',
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: _toggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 2, 10, 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 28,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _progress,
                      builder: (context, _) => CircularProgressIndicator(
                        value: playing ? _progress.value : 0,
                        strokeWidth: 2,
                        color: widget.color,
                        backgroundColor: widget.color.withValues(alpha: 0.2),
                      ),
                    ),
                    Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 18, color: widget.color),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text('${secs}s', style: mono(11, color: widget.color.withValues(alpha: 0.85))),
            ],
          ),
        ),
      ),
    );
  }
}
