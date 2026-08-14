import 'dart:math' show atan2, cos, pi, sin;

import 'package:flutter/material.dart';

import 'rolling_square.dart';

/// The closed path several devices roll around while they are being worked
/// out: a triangle for three of them, a square for four, a circle for more.
///
/// Two devices roll at each other along a line, which is what a sync between
/// two is - one thing meeting another. Three or more is a round: every copy has
/// to reach every other, and a shape with a corner per device says so without a
/// word. Past four the corners stop being countable at a glance, so it becomes
/// a circle - the same statement without the claim about how many.
///
/// The geometry is out here, apart from the widget, because the fold that
/// arrives at it has to land the squares on the very spots the roll starts
/// from. Two descriptions of the same circle would drift apart at the first
/// change to either.
class Circuit {
  const Circuit(this.count, {this.radius = defaultRadius});

  /// How many squares are on it, three at the least.
  final int count;
  final double radius;

  static const double defaultRadius = 42;

  /// Corners while they can still be counted at a glance.
  bool get isPolygon => count <= 4;

  /// How much room the whole thing needs, the squares included.
  double get extent => radius * 2 + RollingSquare.side;

  double get _edge => 2 * radius * sin(pi / count);
  double get perimeter => isPolygon ? count * _edge : 2 * pi * radius;

  /// How long one lap takes, at the pace the search screen's square rolls:
  /// a quarter turn per side of travel.
  Duration get lap => Duration(
      milliseconds: (perimeter / RollingSquare.side * 383).round());

  /// The corner a polygon's [k]th edge starts at, about the middle of the box.
  Offset _corner(int k) {
    // Starting at the top, so with three devices this one is at the apex and
    // the others sit under it - the same reading as the list of names above.
    final angle = 2 * pi * (k % count) / count - pi / 2;
    return Offset(cos(angle), sin(angle)) * radius;
  }

  /// Where the square that is [u] of the way round sits, and which way it is
  /// facing. The centre of the box is the origin.
  ///
  /// The square rides on the outside of the path, touching it, and turns a
  /// quarter for every side-length it travels: that is what rolling is, and
  /// anything else reads as sliding.
  ({Offset centre, double angle}) at(double u) {
    final t = u % 1;
    final tumble = t * perimeter / RollingSquare.side * (pi / 2);

    if (!isPolygon) {
      final around = 2 * pi * t - pi / 2;
      final out = Offset(cos(around), sin(around));
      return (
        centre: out * (radius + RollingSquare.side / 2),
        angle: around + pi / 2 + tumble,
      );
    }

    final travelled = t * count;
    final k = travelled.floor();
    final f = travelled - k;
    final point = Offset.lerp(_corner(k), _corner(k + 1), f)!;
    final facing = _facing(k, f);
    final out = Offset(cos(facing - pi / 2), sin(facing - pi / 2));
    return (
      centre: point + out * (RollingSquare.side / 2),
      angle: facing + tumble,
    );
  }

  /// Which way the square is travelling, with the turn at a corner spread over
  /// a little of the edges either side of it.
  ///
  /// A square rolling round a real corner pivots on it: the turn takes time and
  /// the path rounds off. Snapping the whole exterior angle over in one frame
  /// is the one thing on this screen that would look broken.
  double _facing(int k, double f) {
    final start = _edgeAngle(0);
    final turn = 2 * pi / count;
    const spread = 0.22;

    if (f < spread / 2) {
      return start + turn * (k - 1 + (f + spread / 2) / spread);
    }
    if (f > 1 - spread / 2) {
      return start + turn * (k + (f - 1 + spread / 2) / spread);
    }
    return start + turn * k;
  }

  double _edgeAngle(int k) {
    final from = _corner(k);
    final to = _corner(k + 1);
    return atan2(to.dy - from.dy, to.dx - from.dx);
  }

  /// Where square [index] stands before anything moves, measured from the
  /// top-left of the box rather than its middle. This is what the folding
  /// cards aim at, so the roll begins without a step.
  Offset parked(int index) =>
      at(index / count).centre + Offset(extent / 2, extent / 2);
}

/// The squares of several devices, rolling round their circuit.
///
/// One widget for all of them rather than one each: they share a lap, and two
/// clocks that are meant to agree eventually do not.
class RollingCircuit extends StatefulWidget {
  const RollingCircuit({
    super.key,
    required this.circuit,
    this.rolling = true,
    this.squareKeys = const [],
  });

  final Circuit circuit;
  final bool rolling;

  /// Keys for the squares, in the order the devices are listed, so a test can
  /// watch one of them go round.
  final List<Key> squareKeys;

  @override
  State<RollingCircuit> createState() => _RollingCircuitState();
}

class _RollingCircuitState extends State<RollingCircuit>
    with SingleTickerProviderStateMixin {
  late final AnimationController _lap =
      AnimationController(vsync: this, duration: widget.circuit.lap);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(RollingCircuit old) {
    super.didUpdateWidget(old);
    if (old.rolling != widget.rolling) _sync();
  }

  void _sync() {
    // Someone who has asked the system for less motion gets the shape, still.
    final wanted = widget.rolling && !MediaQuery.disableAnimationsOf(context);
    if (wanted == _lap.isAnimating) return;
    if (wanted) {
      // Round and round, never back: a closed path played in reverse is a
      // detour, and there is nothing on this one to come back from.
      _lap.repeat();
    } else {
      _lap.stop();
      _lap.value = 0;
    }
  }

  @override
  void dispose() {
    _lap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final circuit = widget.circuit;
    final middle = circuit.extent / 2;

    return SizedBox(
      width: circuit.extent,
      height: circuit.extent,
      child: AnimatedBuilder(
        animation: _lap,
        builder: (context, _) {
          return Stack(
            children: [
              for (var i = 0; i < circuit.count; i++)
                Builder(builder: (context) {
                  final spot = circuit.at(i / circuit.count + _lap.value);
                  return Positioned(
                    left: middle + spot.centre.dx - RollingSquare.side / 2,
                    top: middle + spot.centre.dy - RollingSquare.side / 2,
                    width: RollingSquare.side,
                    height: RollingSquare.side,
                    child: Transform.rotate(
                      angle: spot.angle,
                      child: Container(
                        key: i < widget.squareKeys.length
                            ? widget.squareKeys[i]
                            : null,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius:
                              const BorderRadius.all(Radius.circular(3)),
                        ),
                      ),
                    ),
                  );
                }),
            ],
          );
        },
      ),
    );
  }
}
