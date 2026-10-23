import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/services/tools/skill_hub_store.dart';
import '../../../core/services/tools/skill_hub_tool.dart';
import '../../../core/services/tools/skill_tool.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import 'package:Kelivo/theme/app_font_weights.dart';

/// skill 管理页：列出 skills/ 目录下自动注册的自建 Python 工具（查看名称与说明 /
/// 下线 / 删除），并可从远程技能仓库查看 / 下载 / 下线 skill（Android / Windows / Linux）。
class SkillsPage extends StatefulWidget {
  const SkillsPage({super.key, this.embedded = false});

  /// 嵌在桌面设置页中时不再套 Scaffold/AppBar。
  final bool embedded;

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  bool _loading = true;
  List<SkillMeta> _skills = const [];

  final TextEditingController _repoCtrl = TextEditingController();
  final TextEditingController _branchCtrl = TextEditingController();
  final TextEditingController _typeCtrl = TextEditingController();
  final TextEditingController _baseCtrl = TextEditingController();
  final TextEditingController _tokenCtrl = TextEditingController();
  bool _savingCfg = false;
  bool _remoteLoading = false;
  String? _remoteError;
  List<Map<String, dynamic>> _remote = const [];
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _refresh();
  }

  @override
  void dispose() {
    _repoCtrl.dispose();
    _branchCtrl.dispose();
    _typeCtrl.dispose();
    _baseCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final repo = await SkillHubStore.getRepo();
    final branch = await SkillHubStore.getBranch();
    final type = await SkillHubStore.getType();
    final base = await SkillHubStore.getBase();
    final token = await SkillHubStore.getToken();
    if (!mounted) return;
    setState(() {
      _repoCtrl.text = repo;
      _branchCtrl.text = branch;
      _typeCtrl.text = type;
      _baseCtrl.text = base;
      _tokenCtrl.text = token;
    });
  }

  Future<void> _saveConfig() async {
    setState(() => _savingCfg = true);
    await SkillHubStore.setRepo(_repoCtrl.text);
    await SkillHubStore.setBranch(_branchCtrl.text);
    await SkillHubStore.setType(_typeCtrl.text);
    await SkillHubStore.setBase(_baseCtrl.text);
    await SkillHubStore.setToken(_tokenCtrl.text);
    if (!mounted) return;
    setState(() => _savingCfg = false);
    _snack(AppLocalizations.of(context)!.skillsPageSaveConfigSaved);
  }

  Future<void> _refresh() async {
    await SkillTool.instance.ensureScanned();
    if (!mounted) return;
    setState(() {
      _skills = SkillTool.instance.skills;
      _loading = false;
    });
  }

  Future<void> _loadRemote() async {
    setState(() {
      _remoteLoading = true;
      _remoteError = null;
    });
    try {
      final raw = await SkillHubTool.instance.execute({'action': 'list'});
      final m = jsonDecode(raw);
      if (!mounted) return;
      if (m is Map && m['status'] == 'ok') {
        final list = (m['skills'] as List?) ?? const [];
        setState(() {
          _remote = list
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          _remoteLoading = false;
        });
      } else {
        final err = (m is Map ? m['error'] : null)?.toString() ?? AppLocalizations.of(context)!.skillsPageUnknownError;
        setState(() {
          _remoteError = err;
          _remoteLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _remoteError = '$e';
        _remoteLoading = false;
      });
    }
  }

  Future<void> _install(String name) async {
    setState(() => _busy.add(name));
    try {
      final raw = await SkillHubTool.instance.execute({
        'action': 'install',
        'params': {'name': name},
      });
      if (!mounted) return;
      _snack(_resultMessage(raw, fallback: AppLocalizations.of(context)!.skillsPageInstalled(name)));
    } finally {
      if (mounted) setState(() => _busy.remove(name));
    }
    await _refresh();
    await _loadRemote();
  }

  Future<void> _remove(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l = AppLocalizations.of(ctx)!;
        return AlertDialog(
          title: Text(l.skillsPageDeleteTitle),
          content: Text(l.skillsPageDeleteRemoteConfirm(name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.skillsPageCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.skillsPageDeleteAction),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    setState(() => _busy.add(name));
    try {
      final raw = await SkillHubTool.instance.execute({
        'action': 'remove',
        'params': {'name': name},
      });
      if (!mounted) return;
      _snack(_resultMessage(raw, fallback: AppLocalizations.of(context)!.skillsPageRemoved(name)));
    } finally {
      if (mounted) setState(() => _busy.remove(name));
    }
    await _refresh();
    await _loadRemote();
  }

  Future<void> _setEnabled(String name, bool enabled) async {
    setState(() => _busy.add(name));
    try {
      final raw = await SkillHubTool.instance.execute({
        'action': enabled ? 'enable' : 'disable',
        'params': {'name': name},
      });
      if (!mounted) return;
      _snack(
        _resultMessage(
          raw,
          fallback: enabled
              ? AppLocalizations.of(context)!.skillsPageEnabled(name)
              : AppLocalizations.of(context)!.skillsPageDisabled(name),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(name));
    }
    await _refresh();
    await _loadRemote();
  }

  Future<void> _toggleHide(SkillMeta s) async {
    final target = s.enabled ? 'disable' : 'enable';
    final err = SkillTool.instance.setStatus(s.path, target);
    if (err != null) {
      _snack(err);
      return;
    }
    SkillTool.instance.invalidate();
    await _refresh();
  }

  Future<void> _confirmDeleteLocal(SkillMeta s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l = AppLocalizations.of(ctx)!;
        return AlertDialog(
          title: Text(l.skillsPageDeleteTitle),
          content: Text(l.skillsPageDeleteLocalConfirm(s.name, s.path)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.skillsPageCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.skillsPageDeleteAction),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    await SkillTool.instance.execute({
      'action': 'delete',
      'params': {'skill': s.name},
    });
    await _refresh();
  }

  String _resultMessage(String raw, {required String fallback}) {
    try {
      final m = jsonDecode(raw);
      if (m is Map) {
        if (m['status'] == 'error') return (m['error'] ?? AppLocalizations.of(context)!.skillsPageOperationFailed).toString();
        if (m['status'] == 'ok') return fallback;
      }
    } catch (_) {}
    return raw.length > 200 ? '${raw.substring(0, 200)}…' : raw;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              children: [
                _hintText(cs, l10n.skillsPageDirHint(SkillTool.instance.directoryPath ?? 'skills/')),
                const SizedBox(height: 8),
                if (_skills.isEmpty)
                  _hintText(cs, l10n.skillsPageEmptyHint)
                else
                  for (final s in _skills) _skillCard(cs, s),
                const SizedBox(height: 24),
                _sectionTitle(cs, l10n.skillsPageRemoteSection),
                const SizedBox(height: 6),
                _repoField(cs, label: l10n.skillsPageRepoLabel, controller: _repoCtrl),
                const SizedBox(height: 8),
                _repoField(cs, label: l10n.skillsPageBranchLabel, controller: _branchCtrl),
                const SizedBox(height: 8),
                _repoField(
                  cs,
                  label: l10n.skillsPageTypeLabel,
                  controller: _typeCtrl,
                ),
                const SizedBox(height: 8),
                _repoField(
                  cs,
                  label: l10n.skillsPageBaseLabel,
                  controller: _baseCtrl,
                ),
                const SizedBox(height: 8),
                _repoField(
                  cs,
                  label: l10n.skillsPageTokenLabel,
                  controller: _tokenCtrl,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton.tonal(
                      onPressed: _savingCfg ? null : _saveConfig,
                      child: Text(l10n.skillsPageSave),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: _remoteLoading ? null : _loadRemote,
                      icon: const Icon(Lucide.cloudDownload, size: 16),
                      label: Text(l10n.skillsPageBrowseRemote),
                    ),
                    if (_remoteLoading) ...[
                      const SizedBox(width: 10),
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
                if (_remoteError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      l10n.skillsPageLoadFailed(_remoteError ?? ''),
                      style: TextStyle(fontSize: 13, color: cs.error),
                    ),
                  ),
                if (_remote.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      children: [
                        for (final m in _remote) _remoteCard(cs, m),
                      ],
                    ),
                  ),
              ],
            );

    if (widget.embedded) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: body,
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Lucide.ArrowLeft),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.settingsPageSkills),
        actions: [
          IconButton(
            icon: const Icon(Lucide.RefreshCw),
            onPressed: () {
              _refresh();
              _loadRemote();
            },
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _sectionTitle(ColorScheme cs, String text) => Text(
    text,
    style: TextStyle(
      fontSize: 15,
      fontWeight: AppFontWeights.semibold,
      color: cs.onSurface.withValues(alpha: 0.9),
    ),
  );

  Widget _hintText(ColorScheme cs, String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Text(
      text,
      style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.6)),
    ),
  );

  Widget _repoField(
    ColorScheme cs, {
    required String label,
    required TextEditingController controller,
  }) => TextField(
    controller: controller,
    decoration: InputDecoration(
      labelText: label,
      isDense: true,
      border: const OutlineInputBorder(),
    ),
  );

  Widget _card(ColorScheme cs, Widget child) {
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
        child: child,
      ),
    );
  }

  Widget _skillCard(ColorScheme cs, SkillMeta s) {
    final l10n = AppLocalizations.of(context)!;
    return _card(
      cs,
      Row(
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
                          l10n.skillsPageHiddenLabel,
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
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IosSwitch(
                value: s.enabled,
                semanticLabel: s.name,
                onChanged: (_) => _toggleHide(s),
              ),
              IconButton(
                icon: const Icon(Lucide.Trash2),
                color: cs.error,
                onPressed: () => _confirmDeleteLocal(s),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _remoteCard(ColorScheme cs, Map<String, dynamic> m) {
    final name = (m['name'] ?? '').toString();
    final desc = (m['description'] ?? '').toString();
    final installed = m['installed'] == true;
    final enabled = m['enabled'] == true;
    final platform = (m['platform'] as List?)?.join('/') ?? '';
    final requires = (m['requires'] as List?)?.join(', ') ?? '';
    final busy = _busy.contains(name);
    final l10n = AppLocalizations.of(context)!;
    final stateText = !installed
        ? l10n.skillsPageStateNotInstalled
        : (enabled ? l10n.skillsPageStateInstalled : l10n.skillsPageStateDisabled);
    final metaText = [
      if (platform.isNotEmpty) platform,
      if (requires.isNotEmpty) l10n.skillsPageRequires(requires),
      stateText,
    ].join(' · ');

    return _card(
      cs,
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                ),
                if (desc.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      desc,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    metaText,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!installed)
                  IconButton(
                    tooltip: AppLocalizations.of(context)!.skillsPageInstallTooltip,
                    icon: const Icon(Lucide.Download),
                    onPressed: () => _install(name),
                  )
                else
                  IosSwitch(
                    value: enabled,
                    semanticLabel: name,
                    onChanged: (v) => _setEnabled(name, v),
                  ),
                if (installed)
                  IconButton(
                    tooltip: AppLocalizations.of(context)!.skillsPageDeleteTooltip,
                    icon: const Icon(Lucide.Trash2),
                    color: cs.error,
                    onPressed: () => _remove(name),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
