import 'dart:math' show pi;

import 'package:flutter/material.dart';

/// A square that rolls a few steps and then back again.
///
/// A spinner says "something is happening"; this says the same thing without
/// the app's waiting screens looking like every other app's. It tumbles the way
/// a die would - each step pivots on the corner it is about to land on -
/// because a square that slides rather than rolls looks like a bug.
///
/// One implementation for both places that wait: looking for devices, and two
/// devices working out a sync. They are the same wait and they should not be
/// two different animations.
class RollingSquare extends StatefulWidget {
  const RollingSquare({super.key, required this.rolling, this.toLeft = false});

  /// False parks it flat: the wait is over, and motion would say otherwise.
  final bool rolling;

  /// Rolls right to left instead. Two devices working with each other roll
  /// towards each other, which is the whole of what the screen is saying.
  final bool toLeft;

  /// The size of the square and how far it travels, so a widget shrinking into
  /// one can land on exactly the same shape in exactly the same place.
  static const double side = 16;
  static const int steps = 3;
  static const double trackWidth = side * (steps + 1);
  static const double trackHeight = side * 1.5;

  @override
  State<RollingSquare> createState() => _RollingSquareState();
}

class _RollingSquareState extends State<RollingSquare>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(RollingSquare old) {
    super.didUpdateWidget(old);
    if (old.rolling != widget.rolling) _sync();
  }

  void _sync() {
    // Someone who has asked the system for less motion gets a still square
    // rather than a livelier spinner.
    final wanted = widget.rolling && !MediaQuery.disableAnimationsOf(context);
    if (wanted == _controller.isAnimating) return;
    if (wanted) {
      // Reversing is the roll back: played backwards, the same tumble unwinds
      // step by step to where it started.
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SizedBox(
      // Room for the whole run, plus the height a corner reaches mid-tumble.
      width: RollingSquare.trackWidth,
      height: RollingSquare.trackHeight,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // Parked: the middle of the run, sitting flat. The end of the track
          // is where a roll starts, not where a square belongs when it is not
          // rolling at all.
          if (!_controller.isAnimating) {
            return Align(alignment: Alignment.bottomCenter, child: child);
          }

          final progress = _controller.value * RollingSquare.steps;
          final step = progress.floor().clamp(0, RollingSquare.steps - 1);
          final turn = progress - step;
          final travel = step * RollingSquare.side;

          return Align(
            alignment: widget.toLeft
                ? Alignment.bottomRight
                : Alignment.bottomLeft,
            child: Transform.translate(
              offset: Offset(widget.toLeft ? -travel : travel, 0),
              child: Transform.rotate(
                // Pivot on the corner it is rolling over: a quarter turn about
                // it lands the square exactly one side further along.
                alignment: widget.toLeft
                    ? Alignment.bottomLeft
                    : Alignment.bottomRight,
                angle: (widget.toLeft ? -turn : turn) * (pi / 2),
                child: child,
              ),
            ),
          );
        },
        child: Container(
          width: RollingSquare.side,
          height: RollingSquare.side,
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: const BorderRadius.all(Radius.circular(3)),
          ),
        ),
      ),
    );
  }
}
