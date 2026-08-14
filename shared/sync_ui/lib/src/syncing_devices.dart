import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

import 'layout.dart';
import 'rolling_circuit.dart';
import 'rolling_square.dart';

/// The two devices folding down into squares and rolling towards each other,
/// for as long as the sync between them is being worked out.
///
/// It starts as the pair of cards the device list is made of, because that is
/// what was on screen a moment ago, and it takes them apart in the order a
/// person can follow: the writing that no longer matters fades, the cards close
/// down onto squares, the names rise into a list, the squares come to one line,
/// and only then does anything start moving on its own.
///
/// Doing all of that at once - which is what this did at first - reads as a
/// glitch rather than as a transition. Each step has to finish before the next
/// begins, or there is nothing to follow.
///
/// The squares are the ones from the search screen, deliberately: it is the
/// same wait - the app is off talking to something - and a person who has
/// watched one of them knows what the other means.
class SyncingDevices extends StatefulWidget {
  const SyncingDevices({
    super.key,
    required this.self,
    required this.peers,
    required this.caption,
    this.onCancel,
    this.unfold = false,
    this.onUnfolded,
  });

  /// This device, and everything it is waiting on.
  ///
  /// Usually one - a sync is a conversation between two - but levelling
  /// several devices is the same wait with more of them in it, and it would be
  /// strange for that one to look like something else entirely. This device
  /// takes the left of the line and the others roll at it from the right,
  /// which is what a hub run actually does: every copy comes here first.
  final DeviceInfo self;
  final List<DeviceInfo> peers;

  /// What is happening right now: connecting, scanning, comparing, applying.
  final String caption;

  /// Offered while there is still something to call off.
  final VoidCallback? onCancel;

  /// Run the whole thing backwards: the squares grow back into the two
  /// devices. For the wait that ends with nothing to do - two folders already
  /// in sync - where opening a screen of folders would be answering a question
  /// nobody asked. The wait undoes itself and leaves things as they were.
  final bool unfold;

  /// Called once the squares are devices again, so the screen can step aside.
  final VoidCallback? onUnfolded;

  /// The shapes, so a test can watch them move. The peers are numbered from
  /// the one nearest this device.
  static const Key selfShape = Key('syncing-shape-self');
  static const Key peerShape = Key('syncing-shape-peer-0');
  static Key shapeOf(int index) =>
      index == 0 ? selfShape : Key('syncing-shape-peer-${index - 1}');

  @override
  State<SyncingDevices> createState() => _SyncingDevicesState();
}

class _SyncingDevicesState extends State<SyncingDevices>
    with SingleTickerProviderStateMixin {
  /// One clock for the whole sequence, with each step given a slice of it.
  /// Separate controllers per step would overlap sooner or later, which is
  /// exactly what this is getting away from.
  late final AnimationController _fold = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    // Coming back is quicker: by then the person has seen it once, and the
    // news it carries is that there was nothing to do.
    reverseDuration: const Duration(milliseconds: 800),
  );

  /// The slices. Nothing overlaps: each begins where the one before ends.
  static const _fadeStep = (0.0, 0.16);
  static const _shrinkStep = (0.16, 0.52);
  static const _liftStep = (0.52, 0.88);
  static const _revealStep = (0.88, 1.0);

  /// A device card: the badge, and the space the name and its second line take
  /// beside it. The numbers match the cards on the device list, so this starts
  /// where the tap left off.
  static const double _cardHeight = 72;
  static const double _cardPad = Layout.gap + 2;
  static const double _nameLeft = _cardPad + Layout.badgeSize + _cardPad;
  static const double _nameTop = 12;
  static const double _nameHeight = 24;

  /// Where the card ends up as a square: the middle of where its badge was, so
  /// the card closes onto the thing that stood for the device all along.
  static const double _squareInCard =
      _cardPad + (Layout.badgeSize - RollingSquare.side) / 2;

  /// The list the names become, and the track the squares roll along. All of it
  /// grows with the number of devices: two is the usual answer, but levelling
  /// several is the same picture with more cards in it.
  static const double _listLine = 26;
  int get _count => widget.peers.length + 1;

  /// Two devices meet along a line; three or more go round a circuit, because
  /// a sync between two is one thing meeting another and a levelling run is a
  /// round trip.
  Circuit? get _circuit => _count > 2 ? Circuit(_count) : null;

  double get _boxHeight =>
      _cardHeight * _count + Layout.gap * (_count - 1);
  double get _trackHeight =>
      _circuit?.extent ?? RollingSquare.trackHeight;
  double get _endBlock =>
      _listLine * _count + Layout.section + _trackHeight;
  double get _listTop => (_boxHeight - _endBlock) / 2;
  double get _trackTop => _listTop + _listLine * _count + Layout.section;
  double get _squareTop =>
      _listTop + _endBlock - RollingSquare.side;

  /// Where the circuit sits in the box.
  Rect _circuitBox(double width, Circuit circuit) => Rect.fromLTWH(
        (width - circuit.extent) / 2,
        _trackTop,
        circuit.extent,
        circuit.extent,
      );

  /// How wide the line of squares is: a run each, and room in the middle for
  /// them to roll into. Never wider than there is room for.
  double _lineSpan(double width) {
    final wanted = RollingSquare.trackWidth * _count + Layout.section;
    return wanted < width ? wanted : width;
  }

  /// Whether the screen has been told the unfolding is over, so it is told
  /// once however the animation got there.
  bool _told = false;

  @override
  void initState() {
    super.initState();
    _fold.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && widget.unfold) _finish();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.unfold) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      // Asked for less motion: the squares are simply there, and they roll no
      // more than the search screen's does.
      _fold.value = 1;
    } else if (!_fold.isAnimating && _fold.value == 0) {
      _fold.forward();
    }
  }

  @override
  void didUpdateWidget(SyncingDevices old) {
    super.didUpdateWidget(old);
    if (widget.unfold && !old.unfold) _unfold();
  }

  void _unfold() {
    if (_fold.value == 0 || MediaQuery.disableAnimationsOf(context)) {
      // Nothing to play backwards: the wait was over before the fold had
      // begun, or motion is not wanted.
      _fold.value = 0;
      _finish();
      return;
    }
    _fold.reverse();
  }

  void _finish() {
    if (_told || !mounted) return;
    _told = true;
    // Never in the middle of a frame. This is reached from a status listener,
    // and a widget rebuilt straight into unfolding fires one during the build
    // - which is no time for the screen above to be taking itself down.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onUnfolded?.call();
    });
  }

  @override
  void dispose() {
    _fold.dispose();
    super.dispose();
  }

  /// How far through one step of the sequence the clock is.
  double _step((double, double) slice, [Curve curve = Curves.easeInOutCubic]) {
    final (begin, end) = slice;
    return curve.transform(((_fold.value - begin) / (end - begin)).clamp(0, 1));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Layout.section),
        child: ConstrainedBox(
          // The pair belongs together on the screen. Across a desktop window
          // they would be two devices at opposite ends of a desk.
          constraints: const BoxConstraints(maxWidth: 360),
          child: AnimatedBuilder(
            animation: _fold,
            builder: (context, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: _boxHeight,
                    child: LayoutBuilder(
                      builder: (context, box) => Stack(
                        children: [
                          ..._device(0, widget.self, l10n.thisDeviceCard,
                              box.maxWidth),
                          for (var i = 0; i < widget.peers.length; i++)
                            ..._device(i + 1, widget.peers[i],
                                l10n.pairedLabel, box.maxWidth),
                          // Several devices roll as one thing, round one
                          // circuit: separate clocks meant to agree do not.
                          if (_fold.isCompleted && _circuit != null)
                            Positioned.fromRect(
                              rect: _circuitBox(box.maxWidth, _circuit!),
                              child: RollingCircuit(
                                circuit: _circuit!,
                                squareKeys: [
                                  for (var i = 0; i < _count; i++)
                                    SyncingDevices.shapeOf(i),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: Layout.section),
                  // The caption belongs to the waiting, so it arrives with it
                  // rather than sitting over the cards from the first frame.
                  // It keeps its room throughout: nothing below it moves.
                  Opacity(
                    opacity: _step(_revealStep, Curves.easeIn),
                    // The caption changes as the work moves on, and the way
                    // out of it stops being offered part-way through. Growing
                    // into the new size beats snapping to it: nothing else on
                    // this screen moves in jumps.
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeInOut,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.caption,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium,
                          ),
                          if (widget.onCancel != null) ...[
                            const SizedBox(height: Layout.gap),
                            TextButton(
                              onPressed: widget.onCancel,
                              child: Text(l10n.connectCancel),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// One device, as two things that move on their own schedule: the shape that
  /// ends up rolling, and the name that ends up in the list above it.
  List<Widget> _device(
    int index,
    DeviceInfo device,
    String subtitle,
    double width,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // This device holds the left of the line; everyone else rolls at it.
    final toLeft = index > 0;
    final key = SyncingDevices.shapeOf(index);

    final fade = _step(_fadeStep, Curves.easeOut);
    final shrink = _step(_shrinkStep);
    final lift = _step(_liftStep);

    final cardTop = index * (_cardHeight + Layout.gap);
    final card = Rect.fromLTWH(0, cardTop, width, _cardHeight);
    final folded = Rect.fromLTWH(
      _squareInCard,
      cardTop + (_cardHeight - RollingSquare.side) / 2,
      RollingSquare.side,
      RollingSquare.side,
    );
    // Where the roll starts. Two devices take an end of the line each; three or
    // more take a corner of the circuit, in the order they are named above it,
    // so this device is at the top of the shape as it is at the top of the
    // list. Either way the fold lands on the very spot the roll begins from,
    // which is what makes the hand-over invisible.
    final circuit = _circuit;
    final Rect lined;
    if (circuit != null) {
      final box = _circuitBox(width, circuit);
      final centre = box.topLeft + circuit.parked(index);
      lined = Rect.fromCenter(
        center: centre,
        width: RollingSquare.side,
        height: RollingSquare.side,
      );
    } else {
      final span = _lineSpan(width);
      final lineLeft = (width - span) / 2;
      final fromRight = widget.peers.length - index;
      lined = Rect.fromLTWH(
        toLeft
            ? lineLeft + span - fromRight * RollingSquare.trackWidth -
                RollingSquare.side
            : lineLeft,
        _squareTop,
        RollingSquare.side,
        RollingSquare.side,
      );
    }
    // Two moves, one after the other: down onto the badge, then across to the
    // line. The second cannot have started while the first is running.
    final shape = Rect.lerp(Rect.lerp(card, folded, shrink)!, lined, lift)!;

    final nameStyle = TextStyle.lerp(
      theme.textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w600),
      theme.textTheme.bodyMedium!.copyWith(color: colors.onSurfaceVariant),
      lift,
    );

    return [
      // On a circuit the squares are handed over together, above; there is
      // nothing to draw here once the fold has finished.
      if (_fold.isCompleted && circuit != null)
        const SizedBox.shrink()
      else if (_fold.isCompleted)
        // The hand-over is invisible because the roll begins exactly where the
        // square was left: its track starts at the square's own corner.
        Positioned(
          left: toLeft ? shape.right - RollingSquare.trackWidth : shape.left,
          top: shape.bottom - RollingSquare.trackHeight,
          width: RollingSquare.trackWidth,
          height: RollingSquare.trackHeight,
          child: RollingSquare(key: key, rolling: true, toLeft: toLeft),
        )
      else
        Positioned.fromRect(
          rect: shape,
          child: Container(
            key: key,
            decoration: BoxDecoration(
              color: Color.lerp(colors.surfaceContainer, colors.primary,
                  shrink),
              borderRadius: BorderRadius.all(
                Radius.circular(lerpDouble(Layout.cardRadius, 3, shrink)!),
              ),
              border: Border.all(
                color: Color.lerp(colors.outlineVariant, colors.primary,
                    shrink)!,
              ),
            ),
            // Dropped the moment the card starts closing: what is inside it
            // has faded by then, and laying a card's worth of content out
            // inside sixteen pixels is asking for an overflow.
            child: shrink > 0
                ? null
                : Opacity(
                    opacity: 1 - fade,
                    child: Padding(
                      // Down the sides as a card is padded; top and bottom
                      // only as much as leaves room for the badge.
                      padding: const EdgeInsets.symmetric(
                          horizontal: _cardPad, vertical: Layout.gap),
                      child: Row(
                        children: [
                          IconBadge(
                              icon: deviceIcon(device.platform),
                              accented: true),
                          const SizedBox(width: _cardPad),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // The name is drawn over this space, not in
                                // it: it has to outlive the card.
                                const SizedBox(height: _nameHeight),
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      Positioned(
        // Out of the card and into a list: two names, one under the other,
        // above the squares rather than beside them. Beside them they read as
        // labels on two moving objects; above them they are simply who is
        // taking part.
        left: lerpDouble(_nameLeft, 0, lift)!,
        top: lerpDouble(cardTop + _nameTop, _listTop + index * _listLine,
            lift)!,
        width: lerpDouble(width - _nameLeft - _cardPad, width, lift)!,
        height: _nameHeight,
        child: Align(
          alignment: Alignment(lerpDouble(-1, 0, lift)!, 0),
          child: Text(
            device.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: nameStyle,
          ),
        ),
      ),
    ];
  }
}
