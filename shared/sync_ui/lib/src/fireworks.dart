import 'dart:math';

import 'package:flutter/material.dart';

/// A short burst of fireworks over whatever is behind it.
///
/// It marks the one moment in the app worth marking: several devices that
/// disagreed now hold the same thing, and the person who pressed the button
/// waited through a network round of it. It is brief, it cannot be interacted
/// with, and it takes itself off screen when it is done - a celebration that
/// has to be dismissed is a nuisance, not a celebration.
///
/// Skipped entirely when the system asks for less motion.
class Fireworks extends StatefulWidget {
  const Fireworks({super.key, this.onDone});

  /// Called when the last spark has faded, so the caller can stop building it.
  final VoidCallback? onDone;

  @override
  State<Fireworks> createState() => _FireworksState();
}

class _FireworksState extends State<Fireworks>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  final _random = Random();
  late final List<_Burst> _bursts = _plan();

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDone?.call();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      widget.onDone?.call();
    } else if (!_controller.isAnimating && _controller.value == 0) {
      _controller.forward();
    }
  }

  /// Three bursts, staggered, at different heights - one big one in the middle
  /// looks like a bug, three at different times looks like fireworks.
  List<_Burst> _plan() => [
        for (var i = 0; i < 3; i++)
          _Burst(
            at: Offset(0.25 + _random.nextDouble() * 0.5,
                0.25 + _random.nextDouble() * 0.3),
            start: i * 0.18,
            sparks: 14 + _random.nextInt(8),
            spin: _random.nextDouble() * pi,
          ),
      ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colours = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _FireworksPainter(
            progress: _controller.value,
            bursts: _bursts,
            colours: [colours.primary, colours.tertiary, colours.secondary],
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _Burst {
  const _Burst({
    required this.at,
    required this.start,
    required this.sparks,
    required this.spin,
  });

  /// Where it goes off, as a fraction of the space available, so it lands in
  /// the same place whatever the screen.
  final Offset at;

  /// When it goes off, as a fraction of the whole animation.
  final double start;

  final int sparks;

  /// Turns the ring of sparks, so two bursts do not look stamped from the
  /// same mould.
  final double spin;
}

class _FireworksPainter extends CustomPainter {
  const _FireworksPainter({
    required this.progress,
    required this.bursts,
    required this.colours,
  });

  final double progress;
  final List<_Burst> bursts;
  final List<Color> colours;

  @override
  void paint(Canvas canvas, Size size) {
    final reach = size.shortestSide * 0.32;

    for (var b = 0; b < bursts.length; b++) {
      final burst = bursts[b];
      // Each burst has the rest of the animation to live out, so a late one is
      // quicker rather than cut off mid-air.
      final life = (progress - burst.start) / (1 - burst.start);
      if (life <= 0 || life >= 1) continue;

      final centre =
          Offset(burst.at.dx * size.width, burst.at.dy * size.height);
      final colour = colours[b % colours.length];
      // Out fast, then slowing, the way something thrown does.
      final distance = reach * (1 - pow(1 - life, 3).toDouble());
      final fade = (1 - life * life).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = colour.withValues(alpha: fade)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 3 - 1.5 * life;

      for (var i = 0; i < burst.sparks; i++) {
        final angle = burst.spin + i * 2 * pi / burst.sparks;
        final direction = Offset(cos(angle), sin(angle));
        // Sparks all thrown exactly the same distance make a compass rose, not
        // a firework: each gets its own reach, steady from frame to frame so it
        // flies rather than flickers.
        final scatter = 0.7 + 0.3 * _steadyNoise(b * 31 + i);
        final own = distance * scatter;
        // A little gravity, so they fall rather than float.
        final drop = Offset(0, reach * 0.35 * life * life);
        final tip = centre + direction * own + drop;
        final tail = centre + direction * (own * 0.78) + drop;
        canvas.drawLine(tail, tip, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_FireworksPainter old) => old.progress != progress;

  /// A number between 0 and 1 that depends only on [seed]: the same spark gets
  /// the same throw on every frame, without carrying a list of randoms around.
  static double _steadyNoise(int seed) {
    final x = sin(seed * 12.9898) * 43758.5453;
    return x - x.floorToDouble();
  }
}
