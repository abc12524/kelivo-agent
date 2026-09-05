import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/backup.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/backup/s3_client.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import 'package:Kelivo/theme/app_font_weights.dart';

/// 对象存储（S3）配置：读写 SettingsProvider.s3Config，供备份与 @kelivo/s3 复用。
class S3SettingsPage extends StatefulWidget {
  const S3SettingsPage({super.key});

  @override
  State<S3SettingsPage> createState() => _S3SettingsPageState();
}

class _S3SettingsPageState extends State<S3SettingsPage> {
  late final TextEditingController _endpointCtrl;
  late final TextEditingController _regionCtrl;
  late final TextEditingController _bucketCtrl;
  late final TextEditingController _accessKeyCtrl;
  late final TextEditingController _secretKeyCtrl;
  bool _showSecret = false;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<SettingsProvider>().s3Config;
    _endpointCtrl = TextEditingController(text: cfg.endpoint);
    _regionCtrl = TextEditingController(text: cfg.region);
    _bucketCtrl = TextEditingController(text: cfg.bucket);
    _accessKeyCtrl = TextEditingController(text: cfg.accessKeyId);
    _secretKeyCtrl = TextEditingController(text: cfg.secretAccessKey);
  }

  @override
  void dispose() {
    _endpointCtrl.dispose();
    _regionCtrl.dispose();
    _bucketCtrl.dispose();
    _accessKeyCtrl.dispose();
    _secretKeyCtrl.dispose();
    super.dispose();
  }

  S3Config _currentConfig() {
    final cfg = context.read<SettingsProvider>().s3Config;
    return cfg.copyWith(
      endpoint: _endpointCtrl.text.trim(),
      region: _regionCtrl.text.trim(),
      bucket: _bucketCtrl.text.trim(),
      accessKeyId: _accessKeyCtrl.text.trim(),
      secretAccessKey: _secretKeyCtrl.text.trim(),
    );
  }

  void _persist() {
    final settings = context.read<SettingsProvider>();
    settings.setS3Config(_currentConfig());
  }

  Future<void> _testConnection() async {
    setState(() => _testing = true);
    final l10n = AppLocalizations.of(context)!;
    try {
      await const S3BackupClient().test(_currentConfig());
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.backupPageTestDone,
        type: NotificationType.success,
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, message: e.toString(), type: NotificationType.error);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Lucide.ArrowLeft),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.backupPageS3ServerSettings),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          _sectionHeader('连接设置', cs),
          _sectionCard(
            cs,
            children: [
              _field(
                cs,
                label: l10n.backupPageS3Endpoint,
                hint: 'https://s3.amazonaws.com',
                controller: _endpointCtrl,
                onChanged: (_) => _persist(),
              ),
              _divider(cs),
              _field(
                cs,
                label: l10n.backupPageS3Region,
                hint: 'us-east-1 / auto',
                controller: _regionCtrl,
                onChanged: (_) => _persist(),
              ),
              _divider(cs),
              _field(
                cs,
                label: l10n.backupPageS3Bucket,
                controller: _bucketCtrl,
                onChanged: (_) => _persist(),
              ),
              _divider(cs),
              _field(
                cs,
                label: l10n.backupPageS3AccessKeyId,
                controller: _accessKeyCtrl,
                onChanged: (_) => _persist(),
              ),
              _divider(cs),
              _field(
                cs,
                label: l10n.backupPageS3SecretAccessKey,
                controller: _secretKeyCtrl,
                obscure: !_showSecret,
                onChanged: (_) => _persist(),
                suffix: TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: cs.primary,
                  ),
                  onPressed: () => setState(() => _showSecret = !_showSecret),
                  child: Text(_showSecret ? '隐藏' : '显示'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: _testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Lucide.Cable, size: 18),
            label: Text(l10n.backupPageTestConnection),
            onPressed: _testing ? null : _testConnection,
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text, ColorScheme cs) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: AppFontWeights.semibold,
        color: cs.onSurface.withValues(alpha: 0.8),
      ),
    ),
  );

  Widget _sectionCard(ColorScheme cs, {required List<Widget> children}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
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
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: children),
      ),
    );
  }

  Widget _divider(ColorScheme cs) => Divider(
    height: 6,
    thickness: 0.6,
    indent: 16,
    endIndent: 12,
    color: cs.outlineVariant.withValues(alpha: 0.18),
  );

  Widget _field(
    ColorScheme cs, {
    required String label,
    required TextEditingController controller,
    String? hint,
    ValueChanged<String>? onChanged,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          TextField(
            controller: controller,
            obscureText: obscure,
            onChanged: onChanged,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withValues(alpha: 0.4),
              ),
              border: InputBorder.none,
              suffixIcon: suffix,
            ),
            style: TextStyle(
              fontSize: 15,
              color: cs.onSurface.withValues(alpha: 0.92),
            ),
          ),
        ],
      ),
    );
  }
}
