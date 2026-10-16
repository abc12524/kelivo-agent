import 'package:flutter/material.dart';
import '../../../core/services/tools/skill_tool.dart';
import '../../../icons/lucide_adapter.dart';
import 'package:Kelivo/theme/app_font_weights.dart';

/// skill 管理页：列出 skills/ 目录下自动注册的自建 Python 工具，支持查看用法与删除。
class SkillsPage extends StatefulWidget {
  const SkillsPage({super.key});
  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  bool _loading = true;
  List<SkillMeta> _skills = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    await SkillTool.instance.ensureScanned();
    if (!mounted) return;
    setState(() {
      _skills = SkillTool.instance.skills;
      _loading = false;
    });
  }

  Future<void> _confirmDelete(SkillMeta s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 skill'),
        content: Text("确定删除 skill '${s.name}'（${s.path}）？此操作不可撤销。"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await SkillTool.instance.execute({
      'action': 'delete',
      'params': {'skill': s.name},
    });
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Lucide.ArrowLeft),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Skill 管理'),
        actions: [
          IconButton(
            icon: const Icon(Lucide.RefreshCw),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '脚本目录：${SkillTool.instance.directoryPath ?? 'skills/'}',
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (_skills.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 24,
                    ),
                    child: Text(
                      '暂无已注册 skill。把 *.py 脚本放入脚本目录即自动注册。',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  )
                else
                  for (final s in _skills) _skillCard(cs, s),
              ],
            ),
    );
  }

  Widget _skillCard(ColorScheme cs, SkillMeta s) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        s.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.onSurface.withValues(alpha: 0.9),
                        ),
                      ),
                      if (!s.enabled)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            '(disabled)',
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (s.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        s.description,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  if (s.usage.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        s.usage,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Lucide.Trash2),
              color: cs.error,
              onPressed: () => _confirmDelete(s),
            ),
          ],
        ),
      ),
    );
  }
}
