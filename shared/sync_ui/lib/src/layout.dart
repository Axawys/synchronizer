import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

/// The measurements every screen shares.
///
/// They were the same numbers written out again on each screen, which is how a
/// 16 becomes a 14 somewhere and the app starts looking assembled rather than
/// designed. One card corner, one avatar, one rhythm of spaces.
abstract final class Layout {
  /// The corner of every card, panel and row that reads as a surface.
  static const double cardRadius = 18;

  /// The corner of the small square behind an icon inside a card.
  static const double badgeRadius = 14;
  static const double badgeSize = 44;

  /// Spacing steps. Anything in a layout should be one of these.
  static const double tight = 4;
  static const double snug = 8;
  static const double gap = 12;
  static const double gutter = 16;
  static const double section = 24;

  /// How wide a column of text and rows is allowed to get.
  ///
  /// A window three thousand pixels across should not put a folder name at one
  /// end of the desk and the button that changes it at the other. Reading stops
  /// working long before that, and every list here is a column of short lines.
  static const double readableWidth = 640;

  /// The widest a single card in a grid gets before another column appears.
  static const double gridCardWidth = 460;

  static const BorderRadius cardCorners =
      BorderRadius.all(Radius.circular(cardRadius));
  static const BorderRadius badgeCorners =
      BorderRadius.all(Radius.circular(badgeRadius));
}

/// Keeps a screen's content to a readable column, centred, however wide the
/// window gets. Narrow windows and phones are unaffected.
class ContentPane extends StatelessWidget {
  const ContentPane({
    super.key,
    required this.child,
    this.maxWidth = Layout.readableWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// The one card the app uses: a rounded surface with a hairline, an accent
/// border when it is the thing you came for, and a ripple when it does
/// something.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.accented = false,
    this.padding = const EdgeInsets.symmetric(
      horizontal: Layout.gutter,
      vertical: Layout.gap,
    ),
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Draws the border in the accent colour, for a card that is the obvious
  /// thing to press on its screen.
  final bool accented;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainer,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: Layout.cardCorners,
        side: accented
            ? BorderSide(
                color: colors.primary.withValues(alpha: 0.55), width: 1.5)
            : BorderSide(color: colors.outlineVariant),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// The rounded square an icon sits in at the head of a card.
class IconBadge extends StatelessWidget {
  const IconBadge({super.key, required this.icon, this.accented = false});

  final IconData icon;
  final bool accented;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: Layout.badgeSize,
      height: Layout.badgeSize,
      decoration: BoxDecoration(
        color:
            accented ? colors.primaryContainer : colors.surfaceContainerHighest,
        borderRadius: Layout.badgeCorners,
      ),
      child: Icon(
        icon,
        size: 22,
        color: accented ? colors.onPrimaryContainer : colors.onSurfaceVariant,
      ),
    );
  }
}

/// A small pill of text, optionally with an icon: paired, offline, a count.
class Tag extends StatelessWidget {
  const Tag({
    super.key,
    required this.label,
    this.icon,
    this.filled = false,
  });

  final String label;
  final IconData? icon;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground =
        filled ? colors.onPrimaryContainer : colors.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: filled ? colors.primaryContainer : Colors.transparent,
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        border: filled ? null : Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// What a device looks like at a glance. One icon per platform, in one place:
/// the device list, the waiting screen and anything else showing a device
/// should not each have their own idea of what a phone looks like.
IconData deviceIcon(DevicePlatform platform) => switch (platform) {
      DevicePlatform.android => Icons.smartphone,
      DevicePlatform.linux => Icons.computer,
      DevicePlatform.unknown => Icons.devices_other,
    };

/// A path as a person reads it: the end, which says which folder this is, and
/// as much of the front as fits.
///
/// The full path is worth having somewhere - it is the answer to "where did my
/// files go" - but not at the cost of pushing everything else off the row. The
/// home directory becomes `~`, Android's storage prefix goes entirely (every
/// path on the phone starts with it, so it distinguishes nothing), and what is
/// still too long keeps its last segments, because the end of a path is the
/// part that names the folder.
///
/// Somebody else's home counts as one too: a path this device did not write -
/// `/home/axawys/Documents/Obsidian` read on a phone - matches no home here and
/// would otherwise be shown in full, four segments of which two say only "a
/// Linux machine, somebody's account".
String prettyPath(
  String path, {
  int keepSegments = 3,
  int softLimit = 44,
  String? home,
}) {
  var text = path;

  const androidStorage = '/storage/emulated/0';
  if (text.startsWith(androidStorage)) {
    final rest = text.substring(androidStorage.length);
    text = rest.isEmpty ? androidStorage : rest;
  } else {
    final userHome = home ?? _home;
    if (userHome != null && userHome.isNotEmpty && text.startsWith(userHome)) {
      text = '~${text.substring(userHome.length)}';
    } else {
      // Any `/home/<somebody>`, whoever they are and whichever device said so.
      // The segment boundary matters: `/homework` is not a home.
      text = text.replaceFirst(RegExp(r'^/home/[^/]+(?=/|$)'), '~');
    }
  }

  if (text.length <= softLimit) return text;

  final segments = text.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.length <= keepSegments) return text;
  return '…/${segments.sublist(segments.length - keepSegments).join('/')}';
}

String? get _home {
  try {
    return Platform.environment['HOME'];
  } catch (_) {
    // No environment to read, as in a browser or a locked-down host.
    return null;
  }
}

/// A size a person can judge at a glance.
///
/// Weight says what a count cannot: "1240 files" and "3 files" leave it open
/// which is the vault and which is a stub, while "1.2 GB" and "8 kB" settle it.
/// One decimal below ten units and none above, because the difference between
/// 1.2 GB and 1.24 GB is not a difference anyone is acting on.
///
/// Kilobytes run all the way to a hundred megabytes, which is further than a
/// unit table would take them. A vault of notes lives in that range from one
/// end of its life to the other, and "24500 kB" against "3800 kB" is two
/// numbers on the same scale, where "24 MB" against "3.8 MB" asks the reader to
/// do the conversion before they can compare the two devices in front of them.
String formatSize(AppLocalizations l10n, int bytes) {
  if (bytes <= 0) return l10n.sizeEmpty;
  if (bytes < 1000) return l10n.sizeBytes('$bytes');
  if (bytes < 100 * 1000 * 1000) {
    return l10n.sizeKilobytes(_round(bytes / 1000));
  }

  final megabytes = bytes / (1000 * 1000);
  if (megabytes < 1000) return l10n.sizeMegabytes(_round(megabytes));

  return l10n.sizeGigabytes(_round(megabytes / 1000));
}

String _round(double value) =>
    value < 10 ? value.toStringAsFixed(1) : value.round().toString();
