import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:excel/excel.dart' as xlsx;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

void main() {
  runApp(const DiffStudioApp());
}

enum CompareSide { left, right }

enum FileKind { text, code, json, pdf, word, spreadsheet, csv, image, binary }

enum DiffKind { same, added, removed, modified, moved }

class ComparedFile {
  const ComparedFile({
    this.path,
    this.name = '未选择',
    this.text = '',
    this.kind = FileKind.text,
    this.bytes,
    this.tableRows,
    this.note = '',
  });

  final String? path;
  final String name;
  final String text;
  final FileKind kind;
  final Uint8List? bytes;
  final List<List<String>>? tableRows;
  final String note;

  bool get isEmpty => path == null;

  static const empty = ComparedFile();
}

class DiffLine {
  DiffLine({
    required this.id,
    required this.leftNumber,
    required this.rightNumber,
    required this.leftText,
    required this.rightText,
    required this.kind,
  });

  final int id;
  final int? leftNumber;
  final int? rightNumber;
  final String leftText;
  final String rightText;
  final DiffKind kind;

  bool get isChanged => kind != DiffKind.same;
}

class LineEntry {
  LineEntry(this.number, this.text, this.comparable);

  final int number;
  final String text;
  final String comparable;
}

class DiffOp {
  DiffOp.same(this.left, this.right) : kind = DiffKind.same;
  DiffOp.removed(this.left)
      : right = null,
        kind = DiffKind.removed;
  DiffOp.added(this.right)
      : left = null,
        kind = DiffKind.added;

  final DiffKind kind;
  final LineEntry? left;
  final LineEntry? right;
}

class CompareOptions {
  const CompareOptions({
    this.ignoreWhitespace = false,
    this.ignoreCase = false,
    this.ignoreBlankLines = false,
    this.onlyDifferences = false,
  });

  final bool ignoreWhitespace;
  final bool ignoreCase;
  final bool ignoreBlankLines;
  final bool onlyDifferences;

  CompareOptions copyWith({
    bool? ignoreWhitespace,
    bool? ignoreCase,
    bool? ignoreBlankLines,
    bool? onlyDifferences,
  }) {
    return CompareOptions(
      ignoreWhitespace: ignoreWhitespace ?? this.ignoreWhitespace,
      ignoreCase: ignoreCase ?? this.ignoreCase,
      ignoreBlankLines: ignoreBlankLines ?? this.ignoreBlankLines,
      onlyDifferences: onlyDifferences ?? this.onlyDifferences,
    );
  }
}

class DiffStudioApp extends StatelessWidget {
  const DiffStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Diff Studio',
      themeMode: ThemeMode.system,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const DiffStudioHome(),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF47D7D0),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? const Color(0xFF101314) : const Color(0xFFF5F7F8),
      fontFamily: 'Microsoft YaHei UI',
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          shape: MaterialStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
    );
  }
}

class DiffStudioHome extends StatefulWidget {
  const DiffStudioHome({super.key});

  @override
  State<DiffStudioHome> createState() => _DiffStudioHomeState();
}

class _DiffStudioHomeState extends State<DiffStudioHome> {
  ComparedFile leftFile = ComparedFile.empty;
  ComparedFile rightFile = ComparedFile.empty;
  CompareOptions options = const CompareOptions();
  List<DiffLine> rows = const [];
  int activeDiffIndex = 0;
  String status = '就绪';
  bool loading = false;
  CompareSide? dropTarget;
  final verticalController = ScrollController();

  List<DiffLine> get changedRows => rows.where((row) => row.isChanged).toList();

  bool get ready => !leftFile.isEmpty && !rightFile.isEmpty;

  bool get tableMode => ready && leftFile.tableRows != null && rightFile.tableRows != null;

  bool get imageMode => ready && leftFile.kind == FileKind.image && rightFile.kind == FileKind.image;

  @override
  void dispose() {
    verticalController.dispose();
    super.dispose();
  }

  Future<void> pickFile(CompareSide side) async {
    final result = await FilePicker.platform.pickFiles(withData: false);
    final path = result?.files.single.path;
    if (path == null) return;
    await loadPath(path, side);
  }

  Future<void> loadPath(String path, CompareSide side) async {
    setState(() {
      loading = true;
      status = '正在读取 ${p.basename(path)}...';
    });

    try {
      final file = await FileLoader.read(path);
      setState(() {
        if (side == CompareSide.left) {
          leftFile = file;
        } else {
          rightFile = file;
        }
        dropTarget = null;
        status = '已读取 ${file.name}';
      });
      rebuildDiff();
    } catch (error) {
      setState(() {
        status = '读取失败：$error';
      });
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  void rebuildDiff() {
    if (!ready) {
      setState(() {
        rows = const [];
        activeDiffIndex = 0;
      });
      return;
    }

    if (tableMode || imageMode || leftFile.kind == FileKind.binary || rightFile.kind == FileKind.binary) {
      setState(() {
        rows = DiffEngine.build(leftFile.text, rightFile.text, options);
        activeDiffIndex = 0;
        status = '对比完成：${changedRows.length} 处差异';
      });
      return;
    }

    final diffRows = DiffEngine.build(leftFile.text, rightFile.text, options);
    setState(() {
      rows = diffRows;
      activeDiffIndex = 0;
      status = diffRows.isEmpty ? '就绪' : '对比完成：${diffRows.where((row) => row.isChanged).length} 处差异';
    });
  }

  void selectDiff(int index) {
    if (!changedRows.asMap().containsKey(index)) return;
    setState(() {
      activeDiffIndex = index;
    });
    final target = changedRows[index].id * 28.0;
    verticalController.animateTo(
      math.max(0, target - 80),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  void moveDiff(int delta) {
    if (changedRows.isEmpty) return;
    final next = (activeDiffIndex + delta) % changedRows.length;
    selectDiff(next < 0 ? changedRows.length - 1 : next);
  }

  void closeSide(CompareSide side) {
    setState(() {
      if (side == CompareSide.left) {
        leftFile = ComparedFile.empty;
      } else {
        rightFile = ComparedFile.empty;
      }
      status = side == CompareSide.left ? '已关闭左侧' : '已关闭右侧';
      rows = const [];
      activeDiffIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final glass = GlassColors.of(context);
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor),
        child: Column(
          children: [
            _TopBar(onPick: pickFile),
            _FileStrip(
              leftFile: leftFile,
              rightFile: rightFile,
              dropTarget: dropTarget,
              onClose: closeSide,
              onPick: pickFile,
              onDrop: loadPath,
              onDropTarget: (side) => setState(() => dropTarget = side),
              onDropLeave: () => setState(() => dropTarget = null),
            ),
            _ControlBar(
              options: options,
              loading: loading,
              onOptionsChanged: (value) {
                setState(() => options = value);
                rebuildDiff();
              },
              onPrev: () => moveDiff(-1),
              onNext: () => moveDiff(1),
              activeLabel: '${changedRows.isEmpty ? 0 : activeDiffIndex + 1}/${changedRows.length}',
            ),
            Expanded(
              child: ready
                  ? Row(
                      children: [
                        _Sidebar(
                          rows: rows,
                          changedRows: changedRows,
                          activeIndex: activeDiffIndex,
                          onSelect: selectDiff,
                        ),
                        Container(width: 1, color: glass.stroke),
                        Expanded(child: _ComparisonSurface()),
                      ],
                    )
                  : _WelcomeSurface(
                      leftFile: leftFile,
                      rightFile: rightFile,
                      dropTarget: dropTarget,
                      onPick: pickFile,
                      onClose: closeSide,
                      onDrop: loadPath,
                      onDropTarget: (side) => setState(() => dropTarget = side),
                      onDropLeave: () => setState(() => dropTarget = null),
                    ),
            ),
            _StatusBar(status: status, rowsLabel: tableMode ? '${_tableChangeCount()} 个单元格差异' : '${rows.length} 行'),
          ],
        ),
      ),
    );
  }

  int _tableChangeCount() {
    final left = leftFile.tableRows ?? const <List<String>>[];
    final right = rightFile.tableRows ?? const <List<String>>[];
    final rowCount = math.max(left.length, right.length);
    final columnCount = math.max(
      left.fold<int>(0, (max, row) => math.max(max, row.length)),
      right.fold<int>(0, (max, row) => math.max(max, row.length)),
    );
    var count = 0;
    for (var r = 0; r < rowCount; r++) {
      for (var c = 0; c < columnCount; c++) {
        if (_cell(left, r, c) != _cell(right, r, c)) count++;
      }
    }
    return count;
  }

  Widget _ComparisonSurface() {
    if (tableMode) {
      return TableComparisonView(
        leftFile: leftFile,
        rightFile: rightFile,
        activeRow: changedRows.asMap().containsKey(activeDiffIndex)
            ? (changedRows[activeDiffIndex].leftNumber ?? changedRows[activeDiffIndex].rightNumber ?? 1) - 1
            : null,
      );
    }
    if (imageMode) {
      return ImageComparisonView(leftFile: leftFile, rightFile: rightFile);
    }
    if (leftFile.kind == FileKind.binary || rightFile.kind == FileKind.binary) {
      return BinaryComparisonView(leftFile: leftFile, rightFile: rightFile);
    }
    return TextComparisonView(
      rows: rows,
      changedRows: changedRows,
      activeIndex: activeDiffIndex,
      controller: verticalController,
      onlyDifferences: options.onlyDifferences,
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onPick});

  final Future<void> Function(CompareSide side) onPick;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          height: 78,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          decoration: BoxDecoration(
            color: GlassColors.of(context).fill,
            border: Border(bottom: BorderSide(color: GlassColors.of(context).stroke)),
          ),
          child: Row(
            children: [
              const AppMark(size: 42),
              const SizedBox(width: 12),
              const SizedBox(
                width: 230,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Diff Studio', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                    Text('Windows 文件对比', style: TextStyle(fontSize: 12, color: Colors.white54)),
                  ],
                ),
              ),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('文件')),
                  ButtonSegment(value: 1, label: Text('文件夹')),
                  ButtonSegment(value: 2, label: Text('三方')),
                  ButtonSegment(value: 3, label: Text('Git')),
                ],
                selected: const {0},
                onSelectionChanged: (_) {},
              ),
              const Spacer(),
              _GlassButton(icon: Icons.description_outlined, label: '左文件', onTap: () => onPick(CompareSide.left)),
              _GlassButton(icon: Icons.description_outlined, label: '右文件', onTap: () => onPick(CompareSide.right)),
              _GlassButton(icon: Icons.refresh_rounded, label: '刷新', onTap: () {}),
              _GlassButton(icon: Icons.article_outlined, label: '报告', onTap: () {}),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileStrip extends StatelessWidget {
  const _FileStrip({
    required this.leftFile,
    required this.rightFile,
    required this.dropTarget,
    required this.onClose,
    required this.onPick,
    required this.onDrop,
    required this.onDropTarget,
    required this.onDropLeave,
  });

  final ComparedFile leftFile;
  final ComparedFile rightFile;
  final CompareSide? dropTarget;
  final void Function(CompareSide side) onClose;
  final Future<void> Function(CompareSide side) onPick;
  final Future<void> Function(String path, CompareSide side) onDrop;
  final void Function(CompareSide side) onDropTarget;
  final VoidCallback onDropLeave;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
      color: GlassColors.of(context).fill,
      child: Row(
        children: [
          Expanded(
            child: _FileTarget(
              side: CompareSide.left,
              file: leftFile,
              active: dropTarget == CompareSide.left,
              onPick: onPick,
              onDrop: onDrop,
              onClose: onClose,
              onDropTarget: onDropTarget,
              onDropLeave: onDropLeave,
            ),
          ),
          Container(width: 2, height: 34, margin: const EdgeInsets.symmetric(horizontal: 10), color: GlassColors.of(context).stroke),
          Expanded(
            child: _FileTarget(
              side: CompareSide.right,
              file: rightFile,
              active: dropTarget == CompareSide.right,
              onPick: onPick,
              onDrop: onDrop,
              onClose: onClose,
              onDropTarget: onDropTarget,
              onDropLeave: onDropLeave,
            ),
          ),
        ],
      ),
    );
  }
}

class _FileTarget extends StatelessWidget {
  const _FileTarget({
    required this.side,
    required this.file,
    required this.active,
    required this.onPick,
    required this.onDrop,
    required this.onClose,
    required this.onDropTarget,
    required this.onDropLeave,
  });

  final CompareSide side;
  final ComparedFile file;
  final bool active;
  final Future<void> Function(CompareSide side) onPick;
  final Future<void> Function(String path, CompareSide side) onDrop;
  final void Function(CompareSide side) onClose;
  final void Function(CompareSide side) onDropTarget;
  final VoidCallback onDropLeave;

  @override
  Widget build(BuildContext context) {
    final glass = GlassColors.of(context);
    return DropTarget(
      onDragEntered: (_) => onDropTarget(side),
      onDragExited: (_) => onDropLeave(),
      onDragDone: (detail) async {
        onDropLeave();
        if (detail.files.isNotEmpty) {
          await onDrop(detail.files.first.path, side);
        }
      },
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onPick(side),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: active ? glass.focus.withOpacity(0.14) : glass.panel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: active ? glass.focus : glass.stroke, width: active ? 1.5 : 1),
              ),
              child: Row(
                children: [
                  Icon(side == CompareSide.left ? Icons.keyboard_tab_rounded : Icons.keyboard_tab_rounded, size: 18),
                  const SizedBox(width: 10),
                  Text(side == CompareSide.left ? '左侧' : '右侧', style: TextStyle(color: glass.muted)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (active)
                    Text(side == CompareSide.left ? '拖放到左侧' : '拖放到右侧', style: TextStyle(color: glass.focus, fontSize: 12)),
                  if (!file.isEmpty)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.cancel_rounded, size: 18),
                      onPressed: () => onClose(side),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.options,
    required this.loading,
    required this.onOptionsChanged,
    required this.onPrev,
    required this.onNext,
    required this.activeLabel,
  });

  final CompareOptions options;
  final bool loading;
  final ValueChanged<CompareOptions> onOptionsChanged;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final String activeLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: GlassColors.of(context).fill,
        border: Border(bottom: BorderSide(color: GlassColors.of(context).stroke)),
      ),
      child: Row(
        children: [
          _CheckChip(label: '忽略空白', value: options.ignoreWhitespace, onChanged: (v) => onOptionsChanged(options.copyWith(ignoreWhitespace: v))),
          _CheckChip(label: '忽略大小写', value: options.ignoreCase, onChanged: (v) => onOptionsChanged(options.copyWith(ignoreCase: v))),
          _CheckChip(label: '忽略空行', value: options.ignoreBlankLines, onChanged: (v) => onOptionsChanged(options.copyWith(ignoreBlankLines: v))),
          _CheckChip(label: '只看差异', value: options.onlyDifferences, onChanged: (v) => onOptionsChanged(options.copyWith(onlyDifferences: v))),
          const SizedBox(width: 18),
          _GlassButton(icon: Icons.keyboard_arrow_up_rounded, label: '', onTap: onPrev),
          _GlassButton(icon: Icons.keyboard_arrow_down_rounded, label: '', onTap: onNext),
          const SizedBox(width: 10),
          Text(activeLabel, style: TextStyle(color: GlassColors.of(context).muted)),
          if (loading) ...[
            const SizedBox(width: 14),
            const SizedBox(width: 120, child: LinearProgressIndicator()),
          ],
        ],
      ),
    );
  }
}

class _CheckChip extends StatelessWidget {
  const _CheckChip({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: value,
        label: Text(label),
        onSelected: onChanged,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _WelcomeSurface extends StatelessWidget {
  const _WelcomeSurface({
    required this.leftFile,
    required this.rightFile,
    required this.dropTarget,
    required this.onPick,
    required this.onClose,
    required this.onDrop,
    required this.onDropTarget,
    required this.onDropLeave,
  });

  final ComparedFile leftFile;
  final ComparedFile rightFile;
  final CompareSide? dropTarget;
  final Future<void> Function(CompareSide side) onPick;
  final void Function(CompareSide side) onClose;
  final Future<void> Function(String path, CompareSide side) onDrop;
  final void Function(CompareSide side) onDropTarget;
  final VoidCallback onDropLeave;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          Expanded(
            child: _WelcomeDropCard(
              side: CompareSide.left,
              file: leftFile,
              active: dropTarget == CompareSide.left,
              onPick: onPick,
              onClose: onClose,
              onDrop: onDrop,
              onDropTarget: onDropTarget,
              onDropLeave: onDropLeave,
            ),
          ),
          Container(width: 3, margin: const EdgeInsets.symmetric(horizontal: 8), color: GlassColors.of(context).stroke),
          Expanded(
            child: _WelcomeDropCard(
              side: CompareSide.right,
              file: rightFile,
              active: dropTarget == CompareSide.right,
              onPick: onPick,
              onClose: onClose,
              onDrop: onDrop,
              onDropTarget: onDropTarget,
              onDropLeave: onDropLeave,
            ),
          ),
        ],
      ),
    );
  }
}

class _WelcomeDropCard extends StatelessWidget {
  const _WelcomeDropCard({
    required this.side,
    required this.file,
    required this.active,
    required this.onPick,
    required this.onClose,
    required this.onDrop,
    required this.onDropTarget,
    required this.onDropLeave,
  });

  final CompareSide side;
  final ComparedFile file;
  final bool active;
  final Future<void> Function(CompareSide side) onPick;
  final void Function(CompareSide side) onClose;
  final Future<void> Function(String path, CompareSide side) onDrop;
  final void Function(CompareSide side) onDropTarget;
  final VoidCallback onDropLeave;

  @override
  Widget build(BuildContext context) {
    final glass = GlassColors.of(context);
    return DropTarget(
      onDragEntered: (_) => onDropTarget(side),
      onDragExited: (_) => onDropLeave(),
      onDragDone: (detail) async {
        onDropLeave();
        if (detail.files.isNotEmpty) await onDrop(detail.files.first.path, side);
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              color: active ? glass.focus.withOpacity(0.12) : glass.panel,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: active ? glass.focus : glass.stroke),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(file.isEmpty ? Icons.file_copy_outlined : Icons.description_rounded, size: 54, color: glass.muted),
                  const SizedBox(height: 16),
                  Text(file.isEmpty ? (side == CompareSide.left ? '拖入左侧文件' : '拖入右侧文件') : file.name,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 420,
                    child: Text(
                      file.isEmpty ? '支持文本、Word、PDF、Excel、CSV、图片和二进制文件' : file.path ?? '',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: glass.muted),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _GlassButton(icon: Icons.description_outlined, label: file.isEmpty ? '选择文件' : '切换文件', onTap: () => onPick(side)),
                      if (!file.isEmpty) ...[
                        const SizedBox(width: 8),
                        _GlassButton(icon: Icons.close_rounded, label: '关闭', onTap: () => onClose(side)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.rows,
    required this.changedRows,
    required this.activeIndex,
    required this.onSelect,
  });

  final List<DiffLine> rows;
  final List<DiffLine> changedRows;
  final int activeIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final glass = GlassColors.of(context);
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: 156,
          padding: const EdgeInsets.all(12),
          color: glass.sidebar,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${changedRows.length}', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
              Text('处差异', style: TextStyle(color: glass.muted)),
              const SizedBox(height: 14),
              Expanded(
                flex: 2,
                child: _GlassCard(
                  child: ListView.builder(
                    itemCount: changedRows.length,
                    itemBuilder: (context, index) {
                      final row = changedRows[index];
                      final selected = index == activeIndex;
                      return ListTile(
                        dense: true,
                        selected: selected,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        leading: CircleAvatar(radius: 4, backgroundColor: _kindColor(row.kind)),
                        title: Text('L${row.leftNumber ?? '-'}  R${row.rightNumber ?? '-'}', style: const TextStyle(fontSize: 12)),
                        trailing: Text(_kindLabel(row.kind), style: const TextStyle(fontSize: 11)),
                        onTap: () => onSelect(index),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                flex: 3,
                child: _GlassCard(
                  child: CustomPaint(
                    painter: DiffMapPainter(rows: rows, activeId: changedRows.asMap().containsKey(activeIndex) ? changedRows[activeIndex].id : null),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TextComparisonView extends StatelessWidget {
  const TextComparisonView({
    super.key,
    required this.rows,
    required this.changedRows,
    required this.activeIndex,
    required this.controller,
    required this.onlyDifferences,
  });

  final List<DiffLine> rows;
  final List<DiffLine> changedRows;
  final int activeIndex;
  final ScrollController controller;
  final bool onlyDifferences;

  @override
  Widget build(BuildContext context) {
    final visible = onlyDifferences ? _withContext(rows, changedRows.map((e) => e.id).toSet()) : rows;
    return Scrollbar(
      controller: controller,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: controller,
        child: Column(
          children: [
            for (final row in visible)
              DiffLineRow(
                row: row,
                focused: changedRows.asMap().containsKey(activeIndex) && changedRows[activeIndex].id == row.id,
              ),
          ],
        ),
      ),
    );
  }

  List<DiffLine> _withContext(List<DiffLine> allRows, Set<int> changedIds) {
    return allRows.where((row) => changedIds.any((id) => (id - row.id).abs() <= 2)).toList();
  }
}

class DiffLineRow extends StatelessWidget {
  const DiffLineRow({super.key, required this.row, required this.focused});

  final DiffLine row;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final color = _rowColor(context, row.kind);
    return Container(
      decoration: BoxDecoration(
        color: color,
        border: Border(bottom: BorderSide(color: GlassColors.of(context).stroke.withOpacity(0.55))),
      ),
      foregroundDecoration: focused
          ? BoxDecoration(border: Border.all(color: GlassColors.of(context).focus, width: 2))
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _LineCell(number: row.leftNumber, text: row.leftText),
          Container(width: 3, height: 28, color: GlassColors.of(context).stroke),
          _LineCell(number: row.rightNumber, text: row.rightText),
        ],
      ),
    );
  }
}

class _LineCell extends StatelessWidget {
  const _LineCell({required this.number, required this.text});

  final int? number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 560,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 58,
            padding: const EdgeInsets.fromLTRB(0, 5, 10, 5),
            alignment: Alignment.topRight,
            color: GlassColors.of(context).panel,
            child: Text(number?.toString() ?? '', style: TextStyle(color: GlassColors.of(context).muted, fontFamily: 'Consolas')),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: SelectableText(text.isEmpty ? ' ' : text, style: const TextStyle(fontFamily: 'Consolas', fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }
}

class TableComparisonView extends StatelessWidget {
  const TableComparisonView({super.key, required this.leftFile, required this.rightFile, this.activeRow});

  final ComparedFile leftFile;
  final ComparedFile rightFile;
  final int? activeRow;

  @override
  Widget build(BuildContext context) {
    final left = leftFile.tableRows ?? const <List<String>>[];
    final right = rightFile.tableRows ?? const <List<String>>[];
    final rowCount = math.max(left.length, right.length);
    final columnCount = math.max(
      left.fold<int>(0, (max, row) => math.max(max, row.length)),
      right.fold<int>(0, (max, row) => math.max(max, row.length)),
    );
    final changed = <int>{};
    for (var r = 0; r < rowCount; r++) {
      for (var c = 0; c < columnCount; c++) {
        if (_cell(left, r, c) != _cell(right, r, c)) changed.add(r);
      }
    }

    return Column(
      children: [
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: GlassColors.of(context).fill,
            border: Border(bottom: BorderSide(color: GlassColors.of(context).stroke)),
          ),
          child: Row(
            children: [
              _Metric(label: '变化行', value: '${changed.length}'),
              _Metric(label: '总行数', value: '$rowCount'),
              _Metric(label: '总列数', value: '$columnCount'),
              const Spacer(),
              _Legend(color: Colors.red.withOpacity(0.28), label: '左侧差异'),
              _Legend(color: Colors.green.withOpacity(0.28), label: '右侧差异'),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: TablePane(rows: left, peerRows: right, rowCount: rowCount, columnCount: columnCount, side: CompareSide.left, activeRow: activeRow),
                  ),
                ),
                Container(width: 5, height: math.max(260, 64 + rowCount * 36), margin: const EdgeInsets.symmetric(horizontal: 8), color: GlassColors.of(context).stroke),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: TablePane(rows: right, peerRows: left, rowCount: rowCount, columnCount: columnCount, side: CompareSide.right, activeRow: activeRow),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class TablePane extends StatelessWidget {
  const TablePane({
    super.key,
    required this.rows,
    required this.peerRows,
    required this.rowCount,
    required this.columnCount,
    required this.side,
    required this.activeRow,
  });

  final List<List<String>> rows;
  final List<List<String>> peerRows;
  final int rowCount;
  final int columnCount;
  final CompareSide side;
  final int? activeRow;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 30,
          width: 56 + columnCount * 170,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.centerLeft,
          color: GlassColors.of(context).fill,
          child: Text(side == CompareSide.left ? '左侧' : '右侧', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        Row(
          children: [
            _HeaderCell('#', width: 56),
            for (var c = 0; c < columnCount; c++) _HeaderCell(_columnName(c), width: 170),
          ],
        ),
        for (var r = 0; r < rowCount; r++)
          Row(
            children: [
              _HeaderCell('${r + 1}', width: 56, focused: activeRow == r),
              for (var c = 0; c < columnCount; c++)
                _TableCell(
                  value: _cell(rows, r, c),
                  changed: _cell(rows, r, c) != _cell(peerRows, r, c),
                  side: side,
                  focused: activeRow == r,
                ),
            ],
          ),
      ],
    );
  }
}

class _TableCell extends StatelessWidget {
  const _TableCell({required this.value, required this.changed, required this.side, required this.focused});

  final String value;
  final bool changed;
  final CompareSide side;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final base = changed
        ? (side == CompareSide.left ? Colors.red.withOpacity(0.26) : Colors.green.withOpacity(0.24))
        : Colors.transparent;
    return Container(
      width: 170,
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: base,
        border: Border.all(color: focused ? GlassColors.of(context).focus : GlassColors.of(context).stroke.withOpacity(0.55)),
      ),
      child: Text(value, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'Consolas', fontSize: 13)),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell(this.text, {required this.width, this.focused = false});

  final String text;
  final double width;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: GlassColors.of(context).fill,
        border: Border.all(color: focused ? GlassColors.of(context).focus : GlassColors.of(context).stroke.withOpacity(0.55)),
      ),
      child: Text(text, style: TextStyle(color: GlassColors.of(context).muted, fontWeight: FontWeight.w700)),
    );
  }
}

class ImageComparisonView extends StatelessWidget {
  const ImageComparisonView({super.key, required this.leftFile, required this.rightFile});

  final ComparedFile leftFile;
  final ComparedFile rightFile;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _ImagePane(file: leftFile)),
        Container(width: 3, color: GlassColors.of(context).stroke),
        Expanded(child: _ImagePane(file: rightFile)),
      ],
    );
  }
}

class _ImagePane extends StatelessWidget {
  const _ImagePane({required this.file});

  final ComparedFile file;

  @override
  Widget build(BuildContext context) {
    final bytes = file.bytes;
    return Center(
      child: bytes == null ? const Text('未选择图片') : Image.memory(bytes, fit: BoxFit.contain),
    );
  }
}

class BinaryComparisonView extends StatelessWidget {
  const BinaryComparisonView({super.key, required this.leftFile, required this.rightFile});

  final ComparedFile leftFile;
  final ComparedFile rightFile;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: _GlassCard(
        width: 520,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('二进制文件摘要', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              Text('左侧：${leftFile.name}  ${leftFile.bytes?.length ?? 0} bytes'),
              Text('右侧：${rightFile.name}  ${rightFile.bytes?.length ?? 0} bytes'),
              const SizedBox(height: 10),
              Text((leftFile.bytes?.length == rightFile.bytes?.length) ? '大小一致' : '大小不同'),
            ],
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 26),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: GlassColors.of(context).muted)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        children: [
          Container(width: 16, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 12, color: GlassColors.of(context).muted)),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.status, required this.rowsLabel});

  final String status;
  final String rowsLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: GlassColors.of(context).fill,
        border: Border(top: BorderSide(color: GlassColors.of(context).stroke)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(status, overflow: TextOverflow.ellipsis, style: TextStyle(color: GlassColors.of(context).muted))),
          _GlassButton(icon: Icons.more_horiz, label: '操作', onTap: () {}),
          const SizedBox(width: 12),
          Text(rowsLabel, style: TextStyle(color: GlassColors.of(context).muted)),
        ],
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: label.isEmpty ? const SizedBox.shrink() : Text(label),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          backgroundColor: GlassColors.of(context).panel,
          side: BorderSide(color: GlassColors.of(context).stroke),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child, this.width});

  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: width,
          decoration: BoxDecoration(
            color: GlassColors.of(context).panel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: GlassColors.of(context).stroke),
          ),
          child: child,
        ),
      ),
    );
  }
}

class AppMark extends StatelessWidget {
  const AppMark({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: AppMarkPainter());
  }
}

class AppMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = RRect.fromRectAndRadius(rect, Radius.circular(size.width * 0.22));
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF5BE7E0), Color(0xFF787DFF), Color(0xFFFF4F9A)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(rect);
    canvas.drawRRect(r, paint);
    canvas.drawRRect(r.deflate(2), Paint()..color = Colors.white.withOpacity(0.18));
    final pagePaint = Paint()..color = Colors.white.withOpacity(0.82);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(size.width * .22, size.height * .27, size.width * .24, size.height * .48), const Radius.circular(4)), pagePaint);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(size.width * .55, size.height * .27, size.width * .24, size.height * .48), const Radius.circular(4)), pagePaint..color = Colors.white.withOpacity(0.68));
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(size.width * .49, size.height * .24, size.width * .035, size.height * .54), const Radius.circular(8)), Paint()..color = Colors.white.withOpacity(0.74));
    final arrow = Paint()
      ..color = const Color(0xFF66EFE8)
      ..strokeWidth = size.width * .07
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(size.width * .40, size.height * .50)
      ..lineTo(size.width * .62, size.height * .50)
      ..moveTo(size.width * .54, size.height * .40)
      ..lineTo(size.width * .64, size.height * .50)
      ..lineTo(size.width * .54, size.height * .60);
    canvas.drawPath(path, arrow);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class DiffMapPainter extends CustomPainter {
  DiffMapPainter({required this.rows, required this.activeId});

  final List<DiffLine> rows;
  final int? activeId;

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty) return;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (final row in rows.where((row) => row.isChanged)) {
      final y = (row.id / rows.length * size.height).clamp(8.0, size.height - 8);
      paint
        ..color = _kindColor(row.kind)
        ..strokeWidth = row.id == activeId ? 7 : 5;
      canvas.drawLine(Offset(12, y), Offset(size.width - 12, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant DiffMapPainter oldDelegate) => true;
}

class GlassColors {
  GlassColors({
    required this.fill,
    required this.panel,
    required this.sidebar,
    required this.stroke,
    required this.focus,
    required this.muted,
  });

  final Color fill;
  final Color panel;
  final Color sidebar;
  final Color stroke;
  final Color focus;
  final Color muted;

  static GlassColors of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return GlassColors(
      fill: dark ? Colors.white.withOpacity(0.055) : Colors.white.withOpacity(0.56),
      panel: dark ? Colors.white.withOpacity(0.065) : Colors.white.withOpacity(0.50),
      sidebar: dark ? Colors.white.withOpacity(0.045) : Colors.white.withOpacity(0.36),
      stroke: dark ? Colors.white.withOpacity(0.12) : Colors.black.withOpacity(0.10),
      focus: dark ? const Color(0xFF66EFE8) : const Color(0xFFB83280),
      muted: dark ? Colors.white60 : Colors.black54,
    );
  }
}

class FileLoader {
  static Future<ComparedFile> read(String path) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final ext = p.extension(path).toLowerCase();
    final kind = _kind(ext);
    var note = '';
    var text = '';
    List<List<String>>? tableRows;

    switch (kind) {
      case FileKind.word:
        text = _extractDocx(bytes);
        note = '已抽取 Word 文本';
      case FileKind.pdf:
        text = _extractPdf(bytes);
        note = '已抽取 PDF 文本';
      case FileKind.spreadsheet:
        tableRows = _extractXlsx(bytes);
        text = tableRows.map((row) => row.join('\t')).join('\n');
        note = '已读取第一个工作表';
      case FileKind.csv:
        final raw = _decodeText(bytes);
        tableRows = _parseDelimited(raw, ext == '.tsv' ? '\t' : ',');
        text = tableRows.map((row) => row.join('\t')).join('\n');
      case FileKind.image:
        text = '${p.basename(path)}\n${bytes.length} bytes';
      case FileKind.binary:
        text = '${p.basename(path)}\n${bytes.length} bytes';
      case FileKind.json:
        text = _prettyJson(_decodeText(bytes));
      case FileKind.text:
      case FileKind.code:
        text = _decodeText(bytes);
    }

    return ComparedFile(
      path: path,
      name: p.basename(path),
      text: text,
      kind: kind,
      bytes: bytes,
      tableRows: tableRows,
      note: note,
    );
  }

  static FileKind _kind(String ext) {
    if (['.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp'].contains(ext)) return FileKind.image;
    if (ext == '.pdf') return FileKind.pdf;
    if (ext == '.docx') return FileKind.word;
    if (ext == '.xlsx') return FileKind.spreadsheet;
    if (ext == '.csv' || ext == '.tsv') return FileKind.csv;
    if (ext == '.json') return FileKind.json;
    if (['.swift', '.dart', '.js', '.ts', '.py', '.java', '.cpp', '.h', '.cs', '.go', '.rs', '.md', '.xml', '.html', '.css'].contains(ext)) {
      return FileKind.code;
    }
    if (['.txt', '.log', '.ini', '.yaml', '.yml'].contains(ext)) return FileKind.text;
    return FileKind.binary;
  }

  static String _decodeText(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      final data = ByteData.sublistView(bytes, 2);
      final units = <int>[];
      for (var offset = 0; offset + 1 < data.lengthInBytes; offset += 2) {
        units.add(data.getUint16(offset, Endian.little));
      }
      return String.fromCharCodes(units);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _prettyJson(String raw) {
    try {
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(jsonDecode(raw));
    } catch (_) {
      return raw;
    }
  }

  static String _extractDocx(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? document;
    for (final file in archive.files) {
      if (file.name == 'word/document.xml') {
        document = file;
        break;
      }
    }
    if (document == null) return '';
    final content = document.content;
    final xml = content is List<int> ? utf8.decode(content, allowMalformed: true) : content.toString();
    final parsed = XmlDocument.parse(xml);
    final nodes = parsed.descendants.whereType<XmlElement>().where((element) => element.name.local == 't');
    return nodes.map((node) => node.innerText).join('\n');
  }

  static String _extractPdf(Uint8List bytes) {
    final document = PdfDocument(inputBytes: bytes);
    try {
      return PdfTextExtractor(document).extractText();
    } finally {
      document.dispose();
    }
  }

  static List<List<String>> _extractXlsx(Uint8List bytes) {
    final workbook = xlsx.Excel.decodeBytes(bytes);
    if (workbook.tables.isEmpty) return const [];
    final sheet = workbook.tables.values.first;
    return sheet.rows
        .map((row) => row.map((cell) => cell?.value.toString() ?? '').toList())
        .toList();
  }

  static List<List<String>> _parseDelimited(String raw, String delimiter) {
    return const LineSplitter()
        .convert(raw)
        .map((line) => _splitDelimitedLine(line, delimiter))
        .toList();
  }

  static List<String> _splitDelimitedLine(String line, String delimiter) {
    final cells = <String>[];
    final buffer = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        quoted = !quoted;
      } else if (char == delimiter && !quoted) {
        cells.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }
    cells.add(buffer.toString());
    return cells;
  }
}

class DiffEngine {
  static List<DiffLine> build(String leftText, String rightText, CompareOptions options) {
    final left = _entries(leftText, options);
    final right = _entries(rightText, options);
    if (left.isEmpty && right.isEmpty) return const [];
    final ops = left.length * right.length > 1200000 ? _linear(left, right) : _lcs(left, right);
    return _markMoved(_compact(ops));
  }

  static List<LineEntry> _entries(String text, CompareOptions options) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final result = <LineEntry>[];
    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      if (options.ignoreBlankLines && raw.trim().isEmpty) continue;
      var comparable = raw;
      if (options.ignoreWhitespace) comparable = comparable.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).join(' ');
      if (options.ignoreCase) comparable = comparable.toLowerCase();
      result.add(LineEntry(i + 1, raw, comparable));
    }
    return result;
  }

  static List<DiffOp> _linear(List<LineEntry> left, List<LineEntry> right) {
    final result = <DiffOp>[];
    final maxCount = math.max(left.length, right.length);
    for (var i = 0; i < maxCount; i++) {
      final l = i < left.length ? left[i] : null;
      final r = i < right.length ? right[i] : null;
      if (l != null && r != null && l.comparable == r.comparable) {
        result.add(DiffOp.same(l, r));
      } else {
        if (l != null) result.add(DiffOp.removed(l));
        if (r != null) result.add(DiffOp.added(r));
      }
    }
    return result;
  }

  static List<DiffOp> _lcs(List<LineEntry> left, List<LineEntry> right) {
    final table = List.generate(left.length + 1, (_) => List.filled(right.length + 1, 0));
    for (var i = left.length - 1; i >= 0; i--) {
      for (var j = right.length - 1; j >= 0; j--) {
        table[i][j] = left[i].comparable == right[j].comparable ? table[i + 1][j + 1] + 1 : math.max(table[i + 1][j], table[i][j + 1]);
      }
    }
    final ops = <DiffOp>[];
    var i = 0;
    var j = 0;
    while (i < left.length || j < right.length) {
      if (i < left.length && j < right.length && left[i].comparable == right[j].comparable) {
        ops.add(DiffOp.same(left[i++], right[j++]));
      } else if (j >= right.length || (i < left.length && table[i + 1][j] >= table[i][j + 1])) {
        ops.add(DiffOp.removed(left[i++]));
      } else {
        ops.add(DiffOp.added(right[j++]));
      }
    }
    return ops;
  }

  static List<DiffLine> _compact(List<DiffOp> ops) {
    final rows = <DiffLine>[];
    var index = 0;
    while (index < ops.length) {
      final op = ops[index];
      if (op.kind == DiffKind.same) {
        rows.add(DiffLine(id: rows.length, leftNumber: op.left!.number, rightNumber: op.right!.number, leftText: op.left!.text, rightText: op.right!.text, kind: DiffKind.same));
        index++;
      } else {
        final removed = <LineEntry>[];
        final added = <LineEntry>[];
        while (index < ops.length && ops[index].kind != DiffKind.same) {
          if (ops[index].kind == DiffKind.removed) removed.add(ops[index].left!);
          if (ops[index].kind == DiffKind.added) added.add(ops[index].right!);
          index++;
        }
        final maxCount = math.max(removed.length, added.length);
        for (var offset = 0; offset < maxCount; offset++) {
          final l = offset < removed.length ? removed[offset] : null;
          final r = offset < added.length ? added[offset] : null;
          final kind = l != null && r != null ? DiffKind.modified : (l != null ? DiffKind.removed : DiffKind.added);
          rows.add(DiffLine(id: rows.length, leftNumber: l?.number, rightNumber: r?.number, leftText: l?.text ?? '', rightText: r?.text ?? '', kind: kind));
        }
      }
    }
    return rows;
  }

  static List<DiffLine> _markMoved(List<DiffLine> rows) {
    final removed = <String, Set<int>>{};
    final added = <String, Set<int>>{};
    for (final row in rows.where((row) => row.isChanged)) {
      final l = _token(row.leftText);
      final r = _token(row.rightText);
      if (l.isNotEmpty && (row.kind == DiffKind.removed || row.kind == DiffKind.modified)) removed.putIfAbsent(l, () => {}).add(row.id);
      if (r.isNotEmpty && (row.kind == DiffKind.added || row.kind == DiffKind.modified)) added.putIfAbsent(r, () => {}).add(row.id);
    }
    return rows.map((row) {
      var moved = false;
      if (row.kind == DiffKind.removed) moved = added[_token(row.leftText)]?.any((id) => id != row.id) ?? false;
      if (row.kind == DiffKind.added) moved = removed[_token(row.rightText)]?.any((id) => id != row.id) ?? false;
      if (!moved) return row;
      return DiffLine(id: row.id, leftNumber: row.leftNumber, rightNumber: row.rightNumber, leftText: row.leftText, rightText: row.rightText, kind: DiffKind.moved);
    }).toList();
  }

  static String _token(String value) => value.trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty).join(' ');
}

String _cell(List<List<String>> rows, int row, int column) {
  if (row < 0 || row >= rows.length) return '';
  if (column < 0 || column >= rows[row].length) return '';
  return rows[row][column];
}

String _columnName(int index) {
  var number = index + 1;
  var result = '';
  while (number > 0) {
    final remainder = (number - 1) % 26;
    result = String.fromCharCode(65 + remainder) + result;
    number = (number - 1) ~/ 26;
  }
  return result;
}

Color _kindColor(DiffKind kind) {
  switch (kind) {
    case DiffKind.added:
      return Colors.greenAccent.withOpacity(0.72);
    case DiffKind.removed:
      return Colors.redAccent.withOpacity(0.72);
    case DiffKind.modified:
      return Colors.amber.withOpacity(0.75);
    case DiffKind.moved:
      return Colors.blueAccent.withOpacity(0.72);
    case DiffKind.same:
      return Colors.transparent;
  }
}

Color _rowColor(BuildContext context, DiffKind kind) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  switch (kind) {
    case DiffKind.added:
      return (dark ? Colors.green : Colors.greenAccent).withOpacity(dark ? 0.16 : 0.22);
    case DiffKind.removed:
      return (dark ? Colors.red : Colors.redAccent).withOpacity(dark ? 0.18 : 0.22);
    case DiffKind.modified:
      return Colors.amber.withOpacity(dark ? 0.18 : 0.24);
    case DiffKind.moved:
      return Colors.blueAccent.withOpacity(dark ? 0.16 : 0.20);
    case DiffKind.same:
      return Colors.transparent;
  }
}

String _kindLabel(DiffKind kind) {
  switch (kind) {
    case DiffKind.added:
      return '新增';
    case DiffKind.removed:
      return '删除';
    case DiffKind.modified:
      return '修改';
    case DiffKind.moved:
      return '移动';
    case DiffKind.same:
      return '相同';
  }
}
