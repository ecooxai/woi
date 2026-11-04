import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/edits/edit_review.dart';
import '../theme.dart';
import 'diff_view.dart';
import 'glass.dart';

/// Inline preview of the pending AI edit: diff, countdown ring, "Apply now"
/// and "Reject". Enter / Esc and the voice words "apply" / "reject" decide
/// it too (handled by the home screen and the pipeline).
class EditReviewCard extends StatefulWidget {
  const EditReviewCard({super.key, required this.review, this.maxDiffHeight = 220});

  final EditReview review;
  final double maxDiffHeight;

  @override
  State<EditReviewCard> createState() => _EditReviewCardState();
}

class _EditReviewCardState extends State<EditReviewCard> with SingleTickerProviderStateMixin {
  late final AnimationController _ring = AnimationController(vsync: this);
  int? _shownId;

  EditReview get review => widget.review;

  @override
  void initState() {
    super.initState();
    review.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(EditReviewCard old) {
    super.didUpdateWidget(old);
    if (!identical(old.review, review)) {
      old.review.removeListener(_sync);
      review.addListener(_sync);
      _sync();
    }
  }

  @override
  void dispose() {
    review.removeListener(_sync);
    _ring.dispose();
    super.dispose();
  }

  /// Restarts the ring for a newly shown edit, from the time left on it.
  void _sync() {
    final e = review.current;
    if (e?.id != _shownId) {
      _shownId = e?.id;
      _ring.stop();
      final total = e?.countdown;
      final left = review.remaining(e);
      if (e != null && total != null && left != null && total > Duration.zero) {
        _ring.duration = total;
        _ring.value = 1 - left.inMicroseconds / total.inMicroseconds;
        _ring.forward();
      } else {
        _ring.value = 0;
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final e = review.current;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.bottomCenter,
      child: e == null ? const SizedBox(width: double.infinity) : _card(e),
    );
  }

  Widget _card(PendingEdit e) {
    final file = e.target == EditTarget.file;
    final accent = e.requireApproval ? WoiColors.red : WoiColors.cyan;
    final more = review.pendingCount - 1;
    final destructive = e.requireApproval && e.newText.isEmpty;
    return GlassPanel(
      key: ValueKey('edit-review-${e.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      glow: accent,
      elevated: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                destructive
                    ? Icons.delete_outline_rounded
                    : file
                    ? (e.isNewFile ? Icons.note_add_outlined : Icons.edit_document)
                    : Icons.edit_note_rounded,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: file ? e.title : (e.requireApproval ? e.title : 'Note edit'),
                        style: body(13, weight: FontWeight.w600, color: WoiColors.text),
                      ),
                      if (e.summary != null)
                        TextSpan(text: '  ${e.summary}', style: body(12, color: WoiColors.textDim)),
                      if (more > 0) TextSpan(text: '  (+$more queued)', style: body(12, color: WoiColors.textFaint)),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              if (e.deadline != null)
                _CountdownRing(animation: _ring, total: e.countdown!, color: accent)
              else
                Text('needs approval', style: body(11.5, color: WoiColors.textDim)),
            ],
          ),
          if (!destructive && !e.diff.isEmpty) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(WoiRadii.sm),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.min(widget.maxDiffHeight, 21.0 * e.diff.withContext(2).length + 4),
                ),
                child: DiffView(diff: e.diff, path: file ? e.title : 'note.md', contextLines: 2),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  e.deadline != null ? 'Applies automatically. Enter or "apply" now, Esc or "reject" to cancel.' : 'Enter or "apply" to confirm, Esc or "reject" to cancel.',
                  style: body(11.5, color: WoiColors.textFaint),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                key: const ValueKey('edit-review-reject'),
                onPressed: () => review.reject(e.id),
                child: Text(destructive ? 'Keep' : 'Reject'),
              ),
              const SizedBox(width: 6),
              FilledButton(
                key: const ValueKey('edit-review-apply'),
                style: destructive ? FilledButton.styleFrom(backgroundColor: WoiColors.red) : null,
                onPressed: () => review.apply(e.id),
                child: Text(destructive ? 'Delete' : (e.deadline != null ? 'Apply now' : 'Apply')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shrinking ring with the seconds left in the middle.
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({required this.animation, required this.total, required this.color});

  /// 0 → 1 over [total], started from the time left on the edit's deadline.
  final Animation<double> animation;
  final Duration total;
  final Color color;

  /// Whole seconds left, to the nearest second (ceil showed up to a second
  /// more than was left: "3" with 2.1 s to go).
  static int secondsLeft(Duration left) => (left.inMilliseconds / 1000).round();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final left = secondsLeft(total * (1 - animation.value));
        return SizedBox.square(
          key: const ValueKey('edit-review-countdown'),
          dimension: 28,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: 1 - animation.value,
                strokeWidth: 2.5,
                color: color,
                backgroundColor: WoiColors.stroke,
              ),
              Text('$left', style: body(11, weight: FontWeight.w600, color: WoiColors.text)),
            ],
          ),
        );
      },
    );
  }
}
