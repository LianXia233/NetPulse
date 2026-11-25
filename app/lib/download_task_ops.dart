import 'dart:io';

import 'package:flutter/material.dart';

import 'bridge.dart';
import 'theme.dart';
import 'widgets.dart';

/// 下载任务在磁盘上的产物探测结果。
///
/// 成品文件（`dir/name`）与临时分块（`.{文件名}.{哈希}.pmdown*`）分开统计：
/// 删除任务时临时分块总会清掉，成品文件由用户决定是否一起删。
class TaskFiles {
  const TaskFiles({
    required this.dir,
    required this.name,
    required this.targets,
    required this.temps,
    required this.targetBytes,
    required this.targetCount,
    required this.tempBytes,
  });

  final String dir;
  final String name;
  final List<String> targets;
  final List<String> temps;
  final int targetBytes;
  final int targetCount;
  final int tempBytes;

  /// 成品文件是否存在；不存在时不再询问「是否删除文件」。
  bool get hasTarget => targetCount > 0;

  String get targetPath => targets.isEmpty ? joinPath(dir, name) : targets.first;
}

/// 拼接下载目录与文件名，兼容目录已带结尾斜杠的情况。
String joinPath(String dir, String name) {
  if (dir.isEmpty) return name;
  return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
}

/// 收集任务在磁盘上的成品与临时文件。
Future<TaskFiles> probeTaskFiles(Map<String, dynamic> item, String fallbackDir) async {
  final rawDir = (item['dir'] ?? '').toString().trim();
  final dir = rawDir.isEmpty ? fallbackDir : rawDir;
  final name = item['name']?.toString() ?? '';

  final targets = <String>{};
  final path = item['path']?.toString() ?? '';
  if (path.isNotEmpty) targets.add(path);
  if (dir.isNotEmpty && name.isNotEmpty) targets.add(joinPath(dir, name));

  final temps = <String>{};
  final dataFile = item['data_file']?.toString() ?? '';
  final metaFile = item['meta_file']?.toString() ?? '';
  if (dataFile.isNotEmpty) temps.add(dataFile);
  if (metaFile.isNotEmpty) temps.add(metaFile);
  if (dir.isNotEmpty && name.isNotEmpty) {
    temps.add('$dir/.$name.pmdown');
    temps.add('$dir/.$name.pmdown.json');
    // 现版本命名形如 .{文件名}.{哈希}.pmdown，只能按前缀扫目录。
    try {
      await for (final e in Directory(dir).list(followLinks: false)) {
        final base = e.path.split('/').last;
        if (base.startsWith('.$name.') && base.contains('.pmdown')) temps.add(e.path);
      }
    } catch (_) {}
  }

  final targetProbe = await _probe(targets.toList());
  final tempProbe = await _probe(temps.toList());
  return TaskFiles(
    dir: dir,
    name: name,
    targets: targets.toList(),
    temps: temps.toList(),
    targetBytes: targetProbe.$1,
    targetCount: targetProbe.$2,
    tempBytes: tempProbe.$1,
  );
}

Future<(int, int)> _probe(List<String> paths) async {
  var bytes = 0;
  var count = 0;
  for (final p in paths) {
    try {
      if (await FileSystemEntity.type(p) != FileSystemEntityType.file) continue;
      bytes += await File(p).length();
      count++;
    } catch (_) {}
  }
  return (bytes, count);
}

/// 删除给定路径（文件或目录），返回释放的字节数。
Future<int> purgePaths(List<String> paths) async {
  var freed = 0;
  for (final p in paths) {
    try {
      final type = await FileSystemEntity.type(p);
      if (type == FileSystemEntityType.file) {
        freed += await File(p).length();
        await File(p).delete();
      } else if (type == FileSystemEntityType.directory) {
        var dirBytes = 0;
        await for (final e in Directory(p).list(recursive: true, followLinks: false)) {
          if (e is File) {
            try {
              dirBytes += await e.length();
            } catch (_) {}
          }
        }
        await Directory(p).delete(recursive: true);
        freed += dirBytes;
      }
    } catch (_) {}
  }
  return freed;
}

/// 删除确认弹层：默认只移除任务记录，勾选后连成品文件一起删。
///
/// 返回 `null` 表示取消；`false` 表示仅删任务；`true` 表示连文件一起删。
Future<bool?> askDeleteTask(BuildContext context, TaskFiles files) {
  var withFile = false;
  final pm = context.pm;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final sheet = ctx.pm;
        final scheme = ctx.scheme;
        return AlertDialog(
          backgroundColor: sheet.card,
          surfaceTintColor: Colors.transparent,
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(24)),
          title: Text(
            '删除任务',
            style: ctx.text.titleLarge?.copyWith(fontSize: 19, color: scheme.onSurface),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                files.name.isEmpty ? '该下载任务' : files.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ctx.text.bodyMedium?.copyWith(fontSize: 15, color: scheme.onSurface),
              ),
              const SizedBox(height: 4),
              Text(
                files.hasTarget
                    ? '${files.targetPath} · ${formatBytes(files.targetBytes)}'
                    : '尚未生成成品文件',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ctx.text.bodySmall?.copyWith(fontSize: 12, color: sheet.muted, height: 1.4),
              ),
              if (files.hasTarget) ...[
                const SizedBox(height: 10),
                PmPressable(
                  onTap: () => setLocal(() => withFile = !withFile),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 26,
                        height: 26,
                        child: IgnorePointer(
                          child: Checkbox(
                            value: withFile,
                            onChanged: (_) {},
                            activeColor: sheet.warn,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '同时删除已下载的文件',
                          style: ctx.text.bodyMedium?.copyWith(fontSize: 14.5, color: scheme.onSurface),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                withFile
                    ? '任务记录、临时分块与成品文件都会被删除，无法恢复。'
                    : '只移除任务记录，成品文件保留在下载目录；临时分块会一并清理。',
                style: ctx.text.bodySmall?.copyWith(fontSize: 12.5, height: 1.5, color: sheet.muted),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: TextStyle(color: pm.muted)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                withFile ? '删除任务与文件' : '删除任务',
                style: TextStyle(color: pm.warn, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// 执行删除：活跃任务交给内核取消线程并清临时分块，离线记录直接删临时文件。
///
/// 返回实际释放的字节数。
Future<int> removeTaskFiles(
  Map<String, dynamic> item,
  TaskFiles files, {
  required bool withFile,
}) async {
  final id = item['id']?.toString() ?? '';
  final live = item['live'] == true && !id.startsWith('local:');
  if (live) {
    try {
      Core.i.call('dl_delete', {'id': id, 'delete_files': true});
      Core.i.dispose(id);
    } catch (_) {}
  } else {
    await purgePaths(files.temps);
  }
  if (withFile) return purgePaths(files.targets);
  return 0;
}
