import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

/// Shows exactly what a sync will do before a byte is written: which files and
/// folders appear or go, which lines come and go inside each file, and which
/// conflicts still need a decision.
///
/// Pops a list of [ResolvedMerge] to apply, or null if the user backs out.
class MergePreviewPage extends StatefulWidget {
  const MergePreviewPage({
    super.key,
    required this.folderName,
    required this.deviceName,
    required this.preview,
  });

  final String folderName;
  final String deviceName;
  final SyncPreview preview;

  @override
  State<MergePreviewPage> createState() => _MergePreviewPageState();
}

class _MergePreviewPageState extends State<MergePreviewPage> {
  /// For each conflicting file that could be merged: one choice per hunk,
  /// true meaning this device's version wins. Defaults to ours so a stray tap
  /// on Apply never silently discards local work.
  final Map<String, List<bool>> _hunkChoices = {};

  /// For conflicts that cannot be merged at all, a single whole-file choice.
  final Map<String, bool> _keepLocal = {};

  @override
  void initState() {
    super.initState();
    for (final file in widget.preview.conflicts) {
      final merge = file.conflict!.merge;
      if (merge != null) {
        _hunkChoices[file.path] = List.filled(merge.conflicts.length, true);
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
            final choices = _hunkChoices[file.path]!;
            var i = 0;
            final lines =
                merge.resolve((c) => choices[i++] ? c.ours : c.theirs);
            resolved.add(ResolvedMerge.merged(file.item, lines));
          }
        case _:
          resolved.add(ResolvedMerge.natural(file.item));
      }
    }
    return resolved;
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final incoming =
        preview.files.where((f) => f.side == PreviewSide.here).toList();
    final outgoing =
        preview.files.where((f) => f.side == PreviewSide.there).toList();
    final merged =
        preview.files.where((f) => f.kind == PreviewKind.merged).toList();
    final conflicts = preview.conflicts.toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Review "${widget.folderName}"'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Nothing is written until you apply.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        children: [
          if (preview.folders.isNotEmpty) _FolderSection(preview.folders),
          if (conflicts.isNotEmpty)
            _Section(
              title: 'Conflicts (${conflicts.length})',
              subtitle: 'Changed on both devices. Choose what to keep.',
              icon: Icons.warning,
              colour: Theme.of(context).colorScheme.error,
              children: [for (final file in conflicts) _conflictTile(file)],
            ),
          if (merged.isNotEmpty)
            _Section(
              title: 'Merged automatically (${merged.length})',
              subtitle: 'Edited in different places, so both sets of edits '
                  'survive on both devices.',
              icon: Icons.merge,
              colour: Colors.purple,
              children: [for (final file in merged) _fileTile(file)],
            ),
          if (incoming.isNotEmpty)
            _Section(
              title: 'Coming to this device (${incoming.length})',
              icon: Icons.download,
              colour: Colors.blue,
              children: [for (final file in incoming) _fileTile(file)],
            ),
          if (outgoing.isNotEmpty)
            _Section(
              title: 'Going to ${widget.deviceName} (${outgoing.length})',
              icon: Icons.upload,
              colour: Theme.of(context).colorScheme.primary,
              children: [for (final file in outgoing) _fileTile(file)],
            ),
          const SizedBox(height: 88),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pop(context, _resolve()),
        icon: const Icon(Icons.check),
        label: Text('Apply ${preview.files.length}'),
      ),
    );
  }

  Widget _fileTile(FilePreview file) {
    final counts = file.lines.isEmpty
        ? null
        : '+${file.added}  -${file.removed}';
    return ExpansionTile(
      leading: Icon(_iconFor(file.kind), size: 20),
      title: Text(file.path, style: const TextStyle(fontSize: 14)),
      subtitle: Text([_labelFor(file.kind), ?counts].join('  ')),
      children: file.lines.isEmpty
          ? [
              const ListTile(
                dense: true,
                title: Text('No line preview (binary file or a deletion).'),
              )
            ]
          : [_DiffView(file.lines)],
    );
  }

  Widget _conflictTile(FilePreview file) {
    final merge = file.conflict!.merge;

    if (merge == null) {
      // Nothing to merge against: the whole file has to go one way.
      return ExpansionTile(
        leading: Icon(Icons.warning,
            size: 20, color: Theme.of(context).colorScheme.error),
        title: Text(file.path, style: const TextStyle(fontSize: 14)),
        subtitle: const Text('Cannot be merged; keep one version'),
        initiallyExpanded: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Keep mine')),
                ButtonSegment(value: false, label: Text('Take theirs')),
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
    return ExpansionTile(
      leading: Icon(Icons.warning,
          size: 20, color: Theme.of(context).colorScheme.error),
      title: Text(file.path, style: const TextStyle(fontSize: 14)),
      subtitle: Text('${hunks.length} conflicting '
          '${hunks.length == 1 ? 'spot' : 'spots'}; the rest merges cleanly'),
      initiallyExpanded: true,
      children: [
        for (var i = 0; i < hunks.length; i++) _hunkView(file.path, i, hunks[i]),
      ],
    );
  }

  Widget _hunkView(String path, int index, ConflictChunk hunk) {
    final keepMine = _hunkChoices[path]![index];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DiffView([
            for (final line in hunk.ours) DiffLine(DiffOp.insert, line),
            for (final line in hunk.theirs) DiffLine(DiffOp.delete, line),
          ], insertLabel: 'mine', deleteLabel: 'theirs'),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: true, label: Text('Keep mine')),
              ButtonSegment(value: false, label: Text('Take theirs')),
            ],
            selected: {keepMine},
            onSelectionChanged: (s) =>
                setState(() => _hunkChoices[path]![index] = s.first),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(PreviewKind kind) => switch (kind) {
        PreviewKind.create => Icons.note_add,
        PreviewKind.update => Icons.edit,
        PreviewKind.delete => Icons.delete_outline,
        PreviewKind.merged => Icons.merge,
        PreviewKind.conflict => Icons.warning,
      };

  String _labelFor(PreviewKind kind) => switch (kind) {
        PreviewKind.create => 'New file',
        PreviewKind.update => 'Updated',
        PreviewKind.delete => 'Deleted',
        PreviewKind.merged => 'Merged',
        PreviewKind.conflict => 'Conflict',
      };
}

/// The lines a change adds and removes, rendered like a diff.
class _DiffView extends StatelessWidget {
  const _DiffView(this.lines, {this.insertLabel, this.deleteLabel});

  final List<DiffLine> lines;
  final String? insertLabel;
  final String? deleteLabel;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final addBg = dark ? const Color(0xFF14351C) : const Color(0xFFE6FFEC);
    final delBg = dark ? const Color(0xFF3A1417) : const Color(0xFFFFEBE9);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (insertLabel != null || deleteLabel != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Text(
                '+ ${insertLabel ?? 'added'}    − ${deleteLabel ?? 'removed'}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          // Long lines scroll rather than forcing the page sideways.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in _visible())
                  Container(
                    color: switch (line.op) {
                      DiffOp.insert => addBg,
                      DiffOp.delete => delBg,
                      DiffOp.equal => null,
                    },
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                    child: Text(
                      '${switch (line.op) {
                        DiffOp.insert => '+',
                        DiffOp.delete => '−',
                        DiffOp.equal => ' ',
                      }} ${line.text}',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Trims long runs of unchanged lines, the way a diff shows context only
  /// around what actually changed.
  List<DiffLine> _visible() {
    const context = 3;
    final keep = <int>{};
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].op == DiffOp.equal) continue;
      for (var j = i - context; j <= i + context; j++) {
        if (j >= 0 && j < lines.length) keep.add(j);
      }
    }
    return [
      for (var i = 0; i < lines.length; i++)
        if (keep.contains(i)) lines[i],
    ];
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
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
            padding: const EdgeInsets.fromLTRB(42, 0, 16, 8),
            child: Text(subtitle!,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ...children,
      ],
    );
  }
}

class _FolderSection extends StatelessWidget {
  const _FolderSection(this.folders);
  final List<FolderPreview> folders;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Folders (${folders.length})',
      icon: Icons.folder,
      colour: Theme.of(context).colorScheme.secondary,
      children: [
        for (final folder in folders)
          ListTile(
            dense: true,
            leading: Icon(
              folder.created ? Icons.create_new_folder : Icons.folder_delete,
              size: 20,
            ),
            title: Text(folder.path, style: const TextStyle(fontSize: 14)),
            subtitle: Text(
              '${folder.created ? 'Created' : 'Removed'} '
              '${folder.side == PreviewSide.here ? 'here' : 'on the other device'}',
            ),
          ),
      ],
    );
  }
}
