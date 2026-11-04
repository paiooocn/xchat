/// A tiny, dependency-free **line level** diff (longest common subsequence).
///
/// Used by the note assistant to show what an AI rewrite would change before
/// it is applied. Only whole lines are compared — no intra-line diffing.
library;

/// The kind of a diff line.
enum DiffLineType { equal, delete, insert }

/// One line of a diff result.
class DiffLine {
  const DiffLine({
    required this.type,
    required this.text,
    this.oldIndex,
    this.newIndex,
  });

  final DiffLineType type;

  /// The line's text (without the trailing newline).
  final String text;

  /// Index in the original text (null for inserted lines).
  final int? oldIndex;

  /// Index in the new text (null for deleted lines).
  final int? newIndex;
}

/// Computes a line-level diff of [oldText] and [newText].
///
/// The result lists every line of both texts in order: unchanged lines are
/// [DiffLineType.equal], lines only in the original are
/// [DiffLineType.delete], lines only in the result are
/// [DiffLineType.insert].
List<DiffLine> diffLines(String oldText, String newText) {
  // Empty texts have no lines at all (an empty string would otherwise show up
  // as one empty line and produce a bogus "deleted" row).
  if (oldText.isEmpty && newText.isEmpty) return <DiffLine>[];
  if (oldText.isEmpty) {
    return [
      for (var i = 0; i < newText.split('\n').length; i++)
        DiffLine(type: DiffLineType.insert, text: newText.split('\n')[i], newIndex: i),
    ];
  }
  if (newText.isEmpty) {
    return [
      for (var i = 0; i < oldText.split('\n').length; i++)
        DiffLine(type: DiffLineType.delete, text: oldText.split('\n')[i], oldIndex: i),
    ];
  }

  final oldLines = oldText.split('\n');
  final newLines = newText.split('\n');

  // Trim the common prefix/suffix first — the interesting part is usually
  // tiny, and the LCS table stays small.
  var prefix = 0;
  while (prefix < oldLines.length &&
      prefix < newLines.length &&
      oldLines[prefix] == newLines[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < oldLines.length - prefix &&
      suffix < newLines.length - prefix &&
      oldLines[oldLines.length - 1 - suffix] ==
          newLines[newLines.length - 1 - suffix]) {
    suffix++;
  }

  final oldMiddle = oldLines.sublist(prefix, oldLines.length - suffix);
  final newMiddle = newLines.sublist(prefix, newLines.length - suffix);

  final result = <DiffLine>[];
  for (var i = 0; i < prefix; i++) {
    result.add(DiffLine(
      type: DiffLineType.equal,
      text: oldLines[i],
      oldIndex: i,
      newIndex: i,
    ));
  }

  result.addAll(_diffMiddle(oldMiddle, newMiddle, prefix));

  for (var i = 0; i < suffix; i++) {
    final oldIndex = oldLines.length - suffix + i;
    final newIndex = newLines.length - suffix + i;
    result.add(DiffLine(
      type: DiffLineType.equal,
      text: oldLines[oldIndex],
      oldIndex: oldIndex,
      newIndex: newIndex,
    ));
  }
  return result;
}

/// Number of cells the LCS table may have before we give up on a fine-grained
/// diff (very large inputs fall back to "delete everything / insert
/// everything").
const int _maxLcsCells = 4000000;

List<DiffLine> _diffMiddle(
  List<String> oldLines,
  List<String> newLines,
  int offset,
) {
  final result = <DiffLine>[];
  if (oldLines.isEmpty && newLines.isEmpty) return result;

  final cells = oldLines.length * newLines.length;
  if (cells > _maxLcsCells) {
    for (var i = 0; i < oldLines.length; i++) {
      result.add(DiffLine(
        type: DiffLineType.delete,
        text: oldLines[i],
        oldIndex: offset + i,
      ));
    }
    for (var i = 0; i < newLines.length; i++) {
      result.add(DiffLine(
        type: DiffLineType.insert,
        text: newLines[i],
        newIndex: offset + i,
      ));
    }
    return result;
  }

  // Classic LCS table (length + backtrack).
  final table = List<List<int>>.generate(
    oldLines.length + 1,
    (_) => List<int>.filled(newLines.length + 1, 0),
    growable: false,
  );
  for (var i = oldLines.length - 1; i >= 0; i--) {
    for (var j = newLines.length - 1; j >= 0; j--) {
      table[i][j] = oldLines[i] == newLines[j]
          ? table[i + 1][j + 1] + 1
          : (table[i + 1][j] >= table[i][j + 1]
              ? table[i + 1][j]
              : table[i][j + 1]);
    }
  }

  var i = 0;
  var j = 0;
  while (i < oldLines.length && j < newLines.length) {
    if (oldLines[i] == newLines[j]) {
      result.add(DiffLine(
        type: DiffLineType.equal,
        text: oldLines[i],
        oldIndex: offset + i,
        newIndex: offset + j,
      ));
      i++;
      j++;
    } else if (table[i + 1][j] >= table[i][j + 1]) {
      result.add(DiffLine(
        type: DiffLineType.delete,
        text: oldLines[i],
        oldIndex: offset + i,
      ));
      i++;
    } else {
      result.add(DiffLine(
        type: DiffLineType.insert,
        text: newLines[j],
        newIndex: offset + j,
      ));
      j++;
    }
  }
  while (i < oldLines.length) {
    result.add(DiffLine(
      type: DiffLineType.delete,
      text: oldLines[i],
      oldIndex: offset + i,
    ));
    i++;
  }
  while (j < newLines.length) {
    result.add(DiffLine(
      type: DiffLineType.insert,
      text: newLines[j],
      newIndex: offset + j,
    ));
    j++;
  }
  return result;
}

/// Counts the changed lines (deleted + inserted).
int diffChangeCount(List<DiffLine> lines) => lines
    .where((l) => l.type != DiffLineType.equal)
    .length;
