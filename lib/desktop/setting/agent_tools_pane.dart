import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/services/tools/desktop_tool_env.dart';
import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/ios_tile_button.dart';
import '../../theme/app_font_weights.dart';

/// 桌面端：Agent 工具的运行环境（Windows: Git Bash / Python；Linux: Python）。
class DesktopAgentToolsPane extends StatefulWidget {
  const DesktopAgentToolsPane({super.key});

  @override
  State<DesktopAgentToolsPane> createState() => _DesktopAgentToolsPaneState();
}

class _DesktopAgentToolsPaneState extends State<DesktopAgentToolsPane> {
  final TextEditingController _bashCtl = TextEditingController();
  final TextEditingController _pythonCtl = TextEditingController();
  final FocusNode _bashFn = FocusNode();
  final FocusNode _pythonFn = FocusNode();

  @override
  void initState() {
    super.initState();
    _load();
    _bashFn.addListener(() {
      if (!_bashFn.hasFocus) DesktopToolEnv.setBashPath(_bashCtl.text);
    });
    _pythonFn.addListener(() {
      if (!_pythonFn.hasFocus) DesktopToolEnv.setPythonPath(_pythonCtl.text);
    });
  }

  Future<void> _load() async {
    final bash = await DesktopToolEnv.getBashPath();
    final python = await DesktopToolEnv.getPythonPath();
    if (!mounted) return;
    setState(() {
      _bashCtl.text = bash;
      _pythonCtl.text = python;
    });
  }

  @override
  void dispose() {
    _bashCtl.dispose();
    _pythonCtl.dispose();
    _bashFn.dispose();
    _pythonFn.dispose();
    super.dispose();
  }

  Future<void> _pickBash() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: l10n.agentToolsPickFile,
      type: Platform.isWindows ? FileType.custom : FileType.any,
      allowedExtensions: Platform.isWindows ? const ['exe'] : null,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    _bashCtl.text = path;
    await DesktopToolEnv.setBashPath(path);
  }

  Future<void> _pickPythonFile() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: l10n.agentToolsPickFile,
      type: Platform.isWindows ? FileType.custom : FileType.any,
      allowedExtensions: Platform.isWindows ? const ['exe'] : null,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    _pythonCtl.text = path;
    await DesktopToolEnv.setPythonPath(path);
  }

  Future<void> _pickPythonFolder() async {
    final l10n = AppLocalizations.of(context)!;
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: l10n.agentToolsPickFolder,
    );
    if (path == null) return;
    _pythonCtl.text = path;
    await DesktopToolEnv.setPythonPath(path);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            children: [
              SizedBox(
                height: 36,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.settingsPageAgentTools,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: AppFontWeights.regular,
                      color: cs.onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _sectionCard(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: Text(
                      Platform.isWindows
                          ? l10n.agentToolsDescription
                          : l10n.agentToolsDescriptionLinux,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  if (Platform.isWindows) ...[
                    _sectionTitle(context, l10n.agentToolsBashSection),
                    _PathField(
                      label: l10n.agentToolsBashPathLabel,
                      hint: l10n.agentToolsBashPathHint,
                      controller: _bashCtl,
                      focusNode: _bashFn,
                      onBrowseFile: _pickBash,
                      browseLabel: l10n.agentToolsPickFile,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: _rowDivider(context),
                    ),
                  ],
                  _sectionTitle(context, l10n.agentToolsPythonSection),
                  _PathField(
                    label: l10n.agentToolsPythonPathLabel,
                    hint: Platform.isWindows
                        ? l10n.agentToolsPythonPathHint
                        : l10n.agentToolsPythonPathHintLinux,
                    controller: _pythonCtl,
                    focusNode: _pythonFn,
                    onBrowseFile: _pickPythonFile,
                    onBrowseFolder: _pickPythonFolder,
                    browseLabel: l10n.agentToolsPickFile,
                    browseFolderLabel: l10n.agentToolsPickFolder,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _sectionTitle(BuildContext context, String text) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 15,
        fontWeight: AppFontWeights.semibold,
        color: cs.onSurface.withValues(alpha: 0.95),
      ),
    ),
  );
}

class _PathField extends StatelessWidget {
  const _PathField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.focusNode,
    required this.onBrowseFile,
    required this.browseLabel,
    this.onBrowseFolder,
    this.browseFolderLabel,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onBrowseFile;
  final String browseLabel;
  final VoidCallback? onBrowseFolder;
  final String? browseFolderLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface.withValues(alpha: 0.88),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  style: const TextStyle(fontSize: 14),
                  decoration: _deskInputDecoration(
                    context,
                  ).copyWith(hintText: hint),
                ),
              ),
              const SizedBox(width: 8),
              IosTileButton(
                label: browseLabel,
                icon: lucide.Lucide.FileText,
                onTap: onBrowseFile,
              ),
              if (onBrowseFolder != null) ...[
                const SizedBox(width: 8),
                IosTileButton(
                  label: browseFolderLabel ?? '',
                  icon: lucide.Lucide.FolderOpen,
                  onTap: onBrowseFolder!,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _rowDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return Container(
    height: 1,
    color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
  );
}

Widget _sectionCard({required List<Widget> children}) {
  return Builder(
    builder: (context) {
      final cs = Theme.of(context).colorScheme;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final baseBg = isDark
          ? Colors.white10
          : Colors.white.withValues(alpha: 0.96);
      return Container(
        decoration: BoxDecoration(
          color: baseBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.12 : 0.08),
            width: 0.8,
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    },
  );
}

InputDecoration _deskInputDecoration(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final cs = Theme.of(context).colorScheme;
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: isDark ? Colors.white10 : const Color(0xFFF7F7F9),
    hintStyle: TextStyle(
      fontSize: 14,
      color: cs.onSurface.withValues(alpha: 0.5),
    ),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(
        color: cs.outlineVariant.withValues(alpha: 0.12),
        width: 0.6,
      ),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(
        color: cs.outlineVariant.withValues(alpha: 0.12),
        width: 0.6,
      ),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(
        color: cs.primary.withValues(alpha: 0.35),
        width: 0.8,
      ),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );
}
