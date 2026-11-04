import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

/// Shows exactly what a sync will do before a byte is written: which files and
/// folders appear or go, which lines come and go inside each file, and which
/// conflicts still need a decision.
///
/// The changes are laid out by device, because that is the question someone
/// reviewing a sync is actually asking: what lands here, and what goes over
/// there. Mixing the two in one list by kind of change left that to be read off
/// a label on every row.
///
/// Pops a list of [ResolvedMerge] to apply, or null if the user backs out.
class MergePreviewPage extends StatefulWidget {
  const MergePreviewPage({
    super.key,
    required this.folderName,
    required this.deviceName,
    required this.preview,
    this.readOnly = false,
    this.title,
  });

  final String folderName;
  final String deviceName;
  final SyncPreview preview;

  /// Show the changes and settle nothing.
  ///
  /// Levelling several devices decides conflicts on its own screen, where every
  /// device's copy is laid out at once, and applies them to all of them
  /// together. What it was missing was this screen: "what will change on that
  /// device" was a list of file names, which says nothing about whether the
  /// paragraph you spent the evening on is the one arriving or the one being
  /// overwritten. Same page, same diffs, no buttons that decide anything.
  final bool readOnly;

  /// What to call the screen. Defaults to the folder under review; the
  /// levelling run names the device instead, since that is the question being
  /// asked there.
  final String? title;

  @override
  State<MergePreviewPage> createState() => _MergePreviewPageState();
}

/// The two ways of looking at the same sync: what moves where, and what the
/// folder looks like once it has.
enum _Mode { changes, tree }

class _MergePreviewPageState extends State<MergePreviewPage> {
  _Mode _mode = _Mode.changes;

  /// For each conflicting file that could be merged: one choice per hunk, where
  /// true means this device's version wins and null means the user has not said
  /// yet.
  ///
  /// Undecided is a state of its own rather than a hidden default, so the
  /// screen can show what is still waiting on the user and settle the rest
  /// without pretending they were all looked at.
  final Map<String, List<bool?>> _hunkChoices = {};

  /// For conflicts that cannot be merged at all, a single whole-file choice.
  final Map<String, bool> _keepLocal = {};

  @override
  void initState() {
    super.initState();
    for (final file in widget.preview.conflicts) {
      final merge = file.conflict!.merge;
      if (merge != null) {
        _hunkChoices[file.path] = List.filled(merge.conflicts.length, null);
      } else {
        _keepLocal[file.path] = true;
      }
    }
  }

  List<ResolvedMerge> _resolve() {
    final resolved = <ResolvedMerge>[];
    for (final file in widget.preview.files) {
      switch (file.kind) {
        case PreviewKind.merged:
          resolved.add(
              ResolvedMerge.merged(file.item, file.conflict!.merge!.clean!));
        case PreviewKind.conflict:
          final merge = file.conflict!.merge;
          if (merge == null) {
            resolved.add(
                ResolvedMerge(file.item, toLocal: !_keepLocal[file.path]!));
          } else {
            var i = 0;
            final lines = merge.resolve(
                (c) => _choiceFor(file.path, i++) ? c.ours : c.theirs);
            resolved.add(ResolvedMerge.merged(file.item, lines));
          }
        case _:
          resolved.add(ResolvedMerge.natural(file.item));
      }
    }
    return resolved;
  }

  /// What a hunk resolves to. An undecided one keeps this device's version:
  /// leaving a decision unmade must never be the thing that loses local work.
  bool _choiceFor(String path, int index) => _hunkChoices[path]![index] ?? true;

  /// Hunks in [path] the user has not settled yet.
  int _undecided(String path) =>
      _hunkChoices[path]!.where((c) => c == null).length;

  void _decide(String path, int index, bool mine) =>
      setState(() => _hunkChoices[path]![index] = mine);

  void _reopen(String path, int index) =>
      setState(() => _hunkChoices[path]![index] = null);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final preview = widget.preview;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? l10n.reviewFolder(widget.folderName)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<_Mode>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: [
                  ButtonSegment(
                    value: _Mode.changes,
                    icon: const Icon(Icons.compare_arrows, size: 18),
                    label: Text(l10n.reviewModeChanges),
                  ),
                  ButtonSegment(
                    value: _Mode.tree,
                    icon: const Icon(Icons.account_tree_outlined, size: 18),
                    label: Text(l10n.reviewModeTree),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
            ),
          ),
        ),
      ),
      body: switch (_mode) {
        _Mode.changes => _changesView(l10n),
        _Mode.tree => _ResultTree(
            preview: preview,
            deviceName: widget.deviceName,
          ),
      },
      floatingActionButton: widget.readOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: () => Navigator.pop(context, _resolve()),
              icon: const Icon(Icons.check),
              label: Text(l10n.applyCount(preview.files.length)),
            ),
    );
  }

  /// The changes, device by device, with the conflicts above them: a conflict
  /// is one question about a file that both devices hold, not a change on
  /// either of them.
  Widget _changesView(AppLocalizations l10n) {
    final conflicts = widget.preview.conflicts.toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        // Only where there is something to apply. Beside the switch it was cut
        // down to three words on a phone.
        if (!widget.readOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
            child: Text(
              l10n.nothingWrittenYet,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        if (conflicts.isNotEmpty)
          _Section(
            title: l10n.conflictsSection(conflicts.length),
            subtitle: l10n.conflictsSubtitle,
            icon: Icons.warning,
            colour: Theme.of(context).colorScheme.error,
            children: [for (final file in conflicts) _conflictPanel(file)],
          ),
        _DeviceSection(
          title: l10n.comingHere,
          icon: Icons.south,
          changes: _changesOn(PreviewSide.here),
        ),
        _DeviceSection(
          title: l10n.goingTo(widget.deviceName),
          icon: Icons.north,
          changes: _changesOn(PreviewSide.there),
          warnOnDelete: true,
        ),
      ],
    );
  }

  /// Everything that lands on one device: its own one-way changes, the folders
  /// they make or leave empty, and every merge - which lands on both, each
  /// against what that device holds now.
  List<_Change> _changesOn(PreviewSide side) {
    final changes = <_Change>[];
    for (final file in widget.preview.files) {
      switch (file.kind) {
        case PreviewKind.conflict:
          continue;
        case PreviewKind.merged:
          final conflict = file.conflict!;
          changes.add(_Change.file(
            file,
            _Group.changed,
            lines: side == PreviewSide.here
                ? file.lines
                : diffLines(conflict.theirLines, conflict.merge!.clean!),
          ));
        case _ when file.side == side:
          changes.add(_Change.file(
            file,
            switch (file.kind) {
              PreviewKind.delete => _Group.deleted,
              PreviewKind.create => _Group.added,
              _ => _Group.changed,
            },
            lines: file.lines,
          ));
        case _:
          continue;
      }
    }
    for (final folder in widget.preview.folders) {
      if (folder.side != side) continue;
      changes.add(_Change.folder(
          folder.path, folder.created ? _Group.added : _Group.deleted));
    }
    return changes;
  }

  Widget _conflictPanel(FilePreview file) {
    final l10n = AppLocalizations.of(context);
    final colours = Theme.of(context).colorScheme;
    final merge = file.conflict!.merge;
    final tone = _Tone(
      header: colours.errorContainer.withValues(alpha: 0.45),
      border: colours.error.withValues(alpha: 0.6),
    );

    if (merge == null) {
      // Nothing to line up line by line: the whole file has to go one way. The
      // versions are still shown side by side where they are readable, so the
      // choice is not made blind.
      return _Panel(
        icon: Icons.warning,
        iconColour: colours.error,
        title: file.path,
        subtitle: file.lines.isEmpty
            ? l10n.cannotBeCompared
            : l10n.cannotBeMerged,
        tone: tone,
        initiallyExpanded: true,
        body: [
          if (file.lines.isNotEmpty)
            _DiffView(file.lines,
                insertLabel: l10n.labelMine, deleteLabel: l10n.labelTheirs),
          if (!widget.readOnly)
            Padding(
              padding: const EdgeInsets.all(8),
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: true, label: Text(l10n.keepMine)),
                  ButtonSegment(value: false, label: Text(l10n.takeTheirs)),
                ],
                selected: {_keepLocal[file.path]!},
                onSelectionChanged: (s) =>
                    setState(() => _keepLocal[file.path] = s.first),
              ),
            ),
        ],
      );
    }

    final hunks = merge.conflicts;
    return _Panel(
      icon: Icons.warning,
      iconColour: colours.error,
      title: file.path,
      subtitle: widget.readOnly
          ? l10n.levelConflictsCount(hunks.length)
          : _undecided(file.path) == 0
              ? l10n.allSpotsDecided(hunks.length)
              : l10n.spotsToDecide(_undecided(file.path)),
      tone: tone,
      initiallyExpanded: true,
      body: [
        if (!file.conflict!.ancestorKnown) const _GuessedBaseNote(),
        for (var i = 0; i < hunks.length; i++) _hunkView(file.path, i, hunks[i]),
      ],
    );
  }

  Widget _hunkView(String path, int index, ConflictChunk hunk) {
    final l10n = AppLocalizations.of(context);
    final choice = _hunkChoices[path]![index];

    // Decided: the diff goes away, leaving one line saying what was chosen.
    // What is left on screen is then exactly what still needs the user, which
    // is the point of deciding a spot at all. Undo keeps it a decision rather
    // than a commitment - nothing is written until Apply.
    if (choice != null) {
      return ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: Icon(Icons.check_circle,
            size: 18, color: Theme.of(context).colorScheme.primary),
        title: Text(
          choice
              ? l10n.spotKeptMine(hunk.ourStart)
              : l10n.spotTookTheirs(hunk.theirStart),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: TextButton(
          onPressed: () => _reopen(path, index),
          child: Text(l10n.undo),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A conflict is a fragment, so it is numbered from where it sits in
          // each file rather than from 1.
          _DiffView(
            [
              for (final line in hunk.theirs) DiffLine(DiffOp.delete, line),
              for (final line in hunk.ours) DiffLine(DiffOp.insert, line),
            ],
            insertLabel: l10n.labelMine,
            deleteLabel: l10n.labelTheirs,
            oldStart: hunk.theirStart,
            newStart: hunk.ourStart,
          ),
          if (!widget.readOnly)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => _decide(path, index, true),
                    icon: const Icon(Icons.arrow_circle_down, size: 18),
                    label: Text(l10n.takeMine),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _decide(path, index, false),
                    icon: const Icon(Icons.arrow_circle_up, size: 18),
                    label: Text(l10n.takeTheirs),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The colours a change is drawn in, worked out once so the panels, the diff
/// rows and the tree all agree on what green and red mean.
class _Palette {
  _Palette(BuildContext context)
      : dark = Theme.of(context).brightness == Brightness.dark,
        _error = Theme.of(context).colorScheme.error;

  final bool dark;
  final Color _error;

  Color get addBg => dark ? const Color(0xFF14351C) : const Color(0xFFE6FFEC);
  Color get delBg => dark ? const Color(0xFF3A1417) : const Color(0xFFFFEBE9);
  Color get addBorder =>
      dark ? const Color(0xFF2EA043) : const Color(0xFF4AC26B);
  Color get delBorder =>
      dark ? const Color(0xFFDA3633) : const Color(0xFFE5534B);
  Color get addText => dark ? const Color(0xFF3FB950) : const Color(0xFF1A7F37);

  /// Red text is the theme's own error colour: a deletion is the one thing on
  /// this screen that cannot be taken back, and it should read as a warning
  /// in whatever scheme the app is in.
  Color get delText => _error;
}

/// How one panel is coloured: its header strip, its frame, and the colour its
/// title is written in (null for the theme's ordinary text).
class _Tone {
  const _Tone({required this.header, required this.border, this.text});

  final Color header;
  final Color border;
  final Color? text;
}

/// Where a change sits in a device's list: what goes comes first, because it
/// is the part that cannot be undone; then what changes; then what is new.
enum _Group { deleted, changed, added }

/// One row in a device's list of changes: a file, or a folder appearing or
/// going away with the files in it.
class _Change {
  _Change.file(FilePreview this.file, this.group, {required this.lines})
      : path = file.path,
        isFolder = false;

  _Change.folder(this.path, this.group)
      : file = null,
        lines = const [],
        isFolder = true;

  final String path;
  final _Group group;
  final bool isFolder;
  final FilePreview? file;

  /// The diff as this device will see it: a merge lands on both devices, each
  /// against what that one holds now.
  final List<DiffLine> lines;

  bool get merged => file?.kind == PreviewKind.merged;
  int get added => lines.where((l) => l.op == DiffOp.insert).length;
  int get removed => lines.where((l) => l.op == DiffOp.delete).length;
}

/// Everything that lands on one device, folded under its name.
///
/// Deleted first, then changed, then new: the order of how much each one can
/// cost. The header keeps the counts in sight while the list is folded away,
/// so a sync that deletes on the other device says so even closed.
class _DeviceSection extends StatefulWidget {
  const _DeviceSection({
    required this.title,
    required this.icon,
    required this.changes,
    this.warnOnDelete = false,
  });

  final String title;
  final IconData icon;
  final List<_Change> changes;

  /// Whether a deletion here happens out of sight - on the other device, with
  /// nothing on this one keeping a copy - and so earns a line saying so.
  final bool warnOnDelete;

  @override
  State<_DeviceSection> createState() => _DeviceSectionState();
}

class _DeviceSectionState extends State<_DeviceSection> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    final palette = _Palette(context);
    final l10n = AppLocalizations.of(context);

    // By path, which also puts a folder just before the files inside it.
    List<_Change> group(_Group g) =>
        widget.changes.where((c) => c.group == g).toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    final deleted = group(_Group.deleted);
    final changed = group(_Group.changed);
    final added = group(_Group.added);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: colours.surfaceContainerHigh,
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
              child: Row(
                children: [
                  Icon(widget.icon, size: 20, color: colours.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (deleted.isNotEmpty)
                    _Count('−${deleted.length}', palette.delText),
                  if (changed.isNotEmpty)
                    _Count('~${changed.length}', colours.onSurfaceVariant),
                  if (added.isNotEmpty)
                    _Count('+${added.length}', palette.addText),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.changes.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                          child: Text(
                            l10n.nothingForDevice,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: colours.onSurfaceVariant),
                          ),
                        ),
                      if (deleted.isNotEmpty) ...[
                        _GroupLabel(l10n.groupDeleted, deleted.length,
                            palette.delText),
                        if (widget.warnOnDelete)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                            child: Text(
                              l10n.deletionsWarningBody,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: palette.delText, height: 1.35),
                            ),
                          ),
                        for (final change in deleted) _ChangePanel(change),
                      ],
                      if (changed.isNotEmpty) ...[
                        _GroupLabel(l10n.groupChanged, changed.length,
                            colours.onSurfaceVariant),
                        for (final change in changed) _ChangePanel(change),
                      ],
                      if (added.isNotEmpty) ...[
                        _GroupLabel(
                            l10n.groupNew, added.length, palette.addText),
                        for (final change in added) _ChangePanel(change),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// A count in a device's header: how many go, change or arrive.
class _Count extends StatelessWidget {
  const _Count(this.text, this.colour);

  final String text;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colour,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label, this.count, this.colour);

  final String label;
  final int count;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Text(
        '$label · $count',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colour,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// One file or folder in a device's list, coloured by what happens to it:
/// red going, green arriving, the ordinary card colour for a change.
class _ChangePanel extends StatelessWidget {
  const _ChangePanel(this.change);

  final _Change change;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colours = Theme.of(context).colorScheme;
    final palette = _Palette(context);

    final tone = switch (change.group) {
      _Group.deleted => _Tone(
          header: palette.delBg,
          border: palette.delBorder,
          text: palette.delText,
        ),
      _Group.added => _Tone(
          header: palette.addBg,
          border: palette.addBorder,
          text: palette.addText,
        ),
      _Group.changed => _Tone(
          header: colours.surfaceContainerLow,
          border: colours.outlineVariant,
        ),
    };

    final icon = change.isFolder
        ? switch (change.group) {
            _Group.added => Icons.create_new_folder_outlined,
            _ => Icons.folder_delete_outlined,
          }
        : switch (change.group) {
            _Group.deleted => Icons.delete_outline,
            _Group.added => Icons.note_add_outlined,
            _Group.changed => change.merged ? Icons.merge : Icons.edit_outlined,
          };

    // A file that goes away has nothing to show but its name, and a folder is
    // its files, listed beside it.
    final expandable = !change.isFolder && change.group != _Group.deleted;

    return _Panel(
      icon: icon,
      iconColour: tone.text,
      title: change.isFolder ? '${change.path}/' : change.path,
      tone: tone,
      trailing: [
        if (change.merged) _Tag(l10n.kindMerged),
        if (change.added > 0) _Count('+${change.added}', palette.addText),
        if (change.removed > 0) _Count('−${change.removed}', palette.delText),
      ],
      body: !expandable
          ? null
          : [
              if (change.file?.conflict?.ancestorKnown == false)
                const _GuessedBaseNote(),
              if (change.lines.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(l10n.noLinePreview,
                      style: Theme.of(context).textTheme.bodySmall),
                )
              else
                _DiffView(change.lines),
            ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final colours = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colours.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: colours.onSecondaryContainer),
      ),
    );
  }
}

/// A framed row that opens onto its detail: the header is tinted by what is
/// happening to the file, and the detail sits on the plain surface so the
/// diff's own colours stay readable.
///
/// The frame runs nearly the full width of the screen, and the diff inside it
/// starts at the frame's edge: the text of the file is the point, and every
/// pixel of indent was a pixel of it pushed off the side of a phone.
class _Panel extends StatefulWidget {
  const _Panel({
    required this.icon,
    required this.title,
    required this.tone,
    this.iconColour,
    this.subtitle,
    this.trailing = const [],
    this.body,
    this.initiallyExpanded = false,
  });

  final IconData icon;
  final Color? iconColour;
  final String title;
  final String? subtitle;
  final _Tone tone;
  final List<Widget> trailing;

  /// What opens under the header. Null for a row with nothing more to show.
  final List<Widget>? body;
  final bool initiallyExpanded;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = widget.body;

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: widget.tone.border),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: widget.tone.header,
            child: InkWell(
              onTap: body == null ? null : () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                child: Row(
                  children: [
                    Icon(widget.icon, size: 18, color: widget.iconColour),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: widget.tone.text,
                              fontWeight: widget.tone.text == null
                                  ? null
                                  : FontWeight.w600,
                            ),
                          ),
                          if (widget.subtitle != null)
                            Text(widget.subtitle!,
                                style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    ...widget.trailing,
                    if (body != null)
                      Icon(_open ? Icons.expand_less : Icons.expand_more,
                          size: 20)
                    else
                      const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          ),
          if (body != null && _open) ...[
            Divider(height: 1, color: widget.tone.border),
            ...body,
          ],
        ],
      ),
    );
  }
}

/// The folder as it will be once the sync is done, as a tree.
///
/// The list of changes answers "what moves where"; this answers the other
/// question people open a review with - "and then what does my vault look
/// like". Every file both devices will hold is here, the changed ones coloured
/// and tagged with where the change is headed; what goes away is still shown,
/// struck through, because a file that silently is not there is exactly what a
/// review is meant to catch. Folders with nothing changing inside start closed.
class _ResultTree extends StatefulWidget {
  const _ResultTree({required this.preview, required this.deviceName});

  final SyncPreview preview;
  final String deviceName;

  @override
  State<_ResultTree> createState() => _ResultTreeState();
}

enum _Mark { none, created, changed, merged, deleted, conflict }

class _Node {
  _Node(this.name, this.path, {required this.isFolder});

  final String name;
  final String path;
  final bool isFolder;
  final Map<String, _Node> children = {};

  _Mark mark = _Mark.none;
  PreviewSide? side;

  /// Changes at or under this node, so a closed folder can still say it holds
  /// some.
  int changes = 0;

  List<_Node> get sorted => children.values.toList()
    ..sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
}

class _ResultTreeState extends State<_ResultTree> {
  late final _Node _root = _build();

  /// Folders shown open. Starts with every folder that has a change in it.
  final Set<String> _open = {};

  _Node _build() {
    final root = _Node('', '', isFolder: true);

    _Node place(String path, {required bool isFolder}) {
      var node = root;
      final parts = path.split('/');
      for (var i = 0; i < parts.length; i++) {
        final last = i == parts.length - 1;
        final at = parts.take(i + 1).join('/');
        node = node.children.putIfAbsent(
          parts[i],
          () => _Node(parts[i], at, isFolder: !last || isFolder),
        );
      }
      return node;
    }

    for (final path in widget.preview.unchanged) {
      place(path, isFolder: false);
    }
    for (final file in widget.preview.files) {
      place(file.path, isFolder: false)
        ..side = file.side
        ..changes = 1
        ..mark = switch (file.kind) {
          PreviewKind.create => _Mark.created,
          PreviewKind.update => _Mark.changed,
          PreviewKind.merged => _Mark.merged,
          PreviewKind.delete => _Mark.deleted,
          PreviewKind.conflict => _Mark.conflict,
        };
    }
    for (final folder in widget.preview.folders) {
      place(folder.path, isFolder: true)
        ..side = folder.side
        ..mark = folder.created ? _Mark.created : _Mark.deleted;
    }

    int count(_Node node) {
      if (!node.isFolder) return node.changes;
      var total = 0;
      for (final child in node.children.values) {
        total += count(child);
      }
      node.changes = total;
      if (total > 0) _open.add(node.path);
      return total;
    }

    count(root);
    return root;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    final rows = <(_Node, int)>[];
    void walk(_Node node, int depth) {
      for (final child in node.sorted) {
        rows.add((child, depth));
        if (child.isFolder && _open.contains(child.path)) {
          walk(child, depth + 1);
        }
      }
    }

    walk(_root, 0);

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: rows.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Text(
              rows.isEmpty ? l10n.treeEmpty : l10n.treeCaption,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          );
        }
        final (node, depth) = rows[i - 1];
        return _treeRow(node, depth, l10n);
      },
    );
  }

  Widget _treeRow(_Node node, int depth, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final colours = theme.colorScheme;
    final palette = _Palette(context);
    final open = _open.contains(node.path);

    final (Color? background, Color? text) = switch (node.mark) {
      _Mark.created => (palette.addBg, palette.addText),
      _Mark.deleted => (palette.delBg, palette.delText),
      _Mark.changed ||
      _Mark.merged =>
        (colours.secondaryContainer.withValues(alpha: 0.5), null),
      _Mark.conflict => (
          colours.errorContainer.withValues(alpha: 0.45),
          colours.error
        ),
      _Mark.none => (null, null),
    };

    return Material(
      color: background ?? Colors.transparent,
      child: InkWell(
        onTap: node.isFolder
            ? () => setState(() {
                  if (!_open.remove(node.path)) _open.add(node.path);
                })
            : null,
        child: Padding(
          padding: EdgeInsets.fromLTRB(4.0 + depth * 16, 5, 12, 5),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                child: node.isFolder
                    ? Icon(open ? Icons.expand_more : Icons.chevron_right,
                        size: 18)
                    : null,
              ),
              Icon(
                node.isFolder
                    ? (open ? Icons.folder_open : Icons.folder)
                    : Icons.description_outlined,
                size: 18,
                color: text ??
                    (node.isFolder ? colours.primary : colours.onSurfaceVariant),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  node.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: text,
                    fontWeight: node.mark == _Mark.none ? null : FontWeight.w600,
                    decoration: node.mark == _Mark.deleted
                        ? TextDecoration.lineThrough
                        : null,
                    decorationColor: text,
                  ),
                ),
              ),
              ..._where(node, l10n, text),
            ],
          ),
        ),
      ),
    );
  }

  /// Where a change is headed, or - for a folder kept closed - how many
  /// changes it holds.
  List<Widget> _where(_Node node, AppLocalizations l10n, Color? colour) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colour ?? Theme.of(context).colorScheme.onSurfaceVariant,
        );
    switch (node.mark) {
      case _Mark.merged:
        return [_Tag(l10n.kindMerged)];
      case _Mark.conflict:
        return [Text(l10n.kindConflict, style: style)];
      case _Mark.none:
        if (node.isFolder && node.changes > 0 && !_open.contains(node.path)) {
          return [Text('${node.changes}', style: style)];
        }
        return const [];
      case _:
        final here = node.side == PreviewSide.here;
        return [
          Icon(here ? Icons.south : Icons.north, size: 12, color: style?.color),
          const SizedBox(width: 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              here ? l10n.treeToHere : widget.deviceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ];
    }
  }
}

/// Says plainly that a merge had no ancestor to work from, because the result
/// is a good guess rather than a certainty and the user is about to approve it.
class _GuessedBaseNote extends StatelessWidget {
  const _GuessedBaseNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              AppLocalizations.of(context).guessedBaseNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// One line as it will be shown: the change, and the line number it carries
/// in the file it belongs to - the old one for a removed line, the new one for
/// everything else.
class _NumberedLine {
  const _NumberedLine(this.line, this.number);
  final DiffLine line;
  final int number;
}

/// A run of unchanged lines that is not worth showing, and how many.
class _Skipped {
  const _Skipped(this.count);
  final int count;
}

/// The lines a change adds and removes, rendered like a diff: numbered, removed
/// in red with a minus, added in green with a plus.
///
/// Every changed line is shown. Long stretches of untouched text between them
/// are folded away with a note saying how many, so nothing disappears quietly.
///
/// One column of numbers, not two, and no margin: on a phone two gutters and an
/// indent took a quarter of the width before the text began.
class _DiffView extends StatelessWidget {
  const _DiffView(
    this.lines, {
    this.insertLabel,
    this.deleteLabel,
    this.oldStart = 1,
    this.newStart = 1,
  });

  final List<DiffLine> lines;
  final String? insertLabel;
  final String? deleteLabel;

  /// Line number the first line carries on each side. Not always 1: a conflict
  /// is a fragment of a file, and saying so is the point of numbering it.
  final int oldStart;
  final int newStart;

  static const _style = TextStyle(fontFamily: 'monospace', fontSize: 12);

  @override
  Widget build(BuildContext context) {
    final palette = _Palette(context);
    final gutter = Theme.of(context).textTheme.bodySmall?.color?.withValues(
          alpha: 0.55,
        );

    final rows = _rows();
    // Enough room for the largest number the column will show.
    final width = _gutterWidth(rows);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (insertLabel != null || deleteLabel != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
            child: Text(
              '+ ${insertLabel ?? AppLocalizations.of(context).labelAdded}'
              '    − ${deleteLabel ?? AppLocalizations.of(context).labelRemoved}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        // Long lines scroll rather than forcing the page sideways or being
        // cut off. IntrinsicWidth lets every row stretch to the widest one, so
        // a line's colour runs the full width instead of stopping at its own
        // text - and the ConstrainedBox makes that at least the width of the
        // panel, so a short file is not a ragged strip of colour.
        LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: box.maxWidth),
              child: IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final row in rows)
                      if (row is _Skipped)
                        _skipRow(context, row, width)
                      else
                        _lineRow(row as _NumberedLine, width, palette.addBg,
                            palette.delBg, gutter),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _lineRow(_NumberedLine row, double width, Color addBg, Color delBg,
      Color? gutter) {
    return Container(
      color: switch (row.line.op) {
        DiffOp.insert => addBg,
        DiffOp.delete => delBg,
        DiffOp.equal => null,
      },
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: width,
            child: Text(
              '${row.number}',
              textAlign: TextAlign.right,
              style: _style.copyWith(color: gutter),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${switch (row.line.op) {
              DiffOp.insert => '+',
              DiffOp.delete => '−',
              DiffOp.equal => ' ',
            }} ${row.line.text}',
            style: _style,
          ),
        ],
      ),
    );
  }

  Widget _skipRow(BuildContext context, _Skipped row, double width) {
    return Container(
      color: Theme.of(context).dividerColor.withValues(alpha: 0.25),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          SizedBox(width: width + 6),
          Text(
            '⋮ ${AppLocalizations.of(context).unchangedLines(row.count)}',
            style: _style.copyWith(
              fontStyle: FontStyle.italic,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
    );
  }

  double _gutterWidth(List<Object> rows) {
    var digits = 1;
    for (final row in rows) {
      if (row is! _NumberedLine) continue;
      final length = '${row.number}'.length;
      if (length > digits) digits = length;
    }
    return digits * 7.5 + 2;
  }

  /// Numbers every line, then drops the long untouched stretches, replacing
  /// each with a note of what was folded away.
  List<Object> _rows() {
    var oldNo = oldStart;
    var newNo = newStart;
    final numbered = <_NumberedLine>[];
    for (final line in lines) {
      switch (line.op) {
        case DiffOp.equal:
          numbered.add(_NumberedLine(line, newNo));
          oldNo++;
          newNo++;
        case DiffOp.delete:
          numbered.add(_NumberedLine(line, oldNo++));
        case DiffOp.insert:
          numbered.add(_NumberedLine(line, newNo++));
      }
    }

    const context = 3;
    final keep = <int>{};
    for (var i = 0; i < numbered.length; i++) {
      if (numbered[i].line.op == DiffOp.equal) continue;
      for (var j = i - context; j <= i + context; j++) {
        if (j >= 0 && j < numbered.length) keep.add(j);
      }
    }

    final rows = <Object>[];
    var skipped = 0;
    void flushSkipped() {
      if (skipped > 0) rows.add(_Skipped(skipped));
      skipped = 0;
    }

    for (var i = 0; i < numbered.length; i++) {
      if (keep.contains(i)) {
        flushSkipped();
        rows.add(numbered[i]);
      } else {
        skipped++;
      }
    }
    flushSkipped();
    return rows;
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.colour,
    required this.children,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Color colour;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              Icon(icon, size: 18, color: colour),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(subtitle!,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ...children,
        const SizedBox(height: 4),
      ],
    );
  }
}
