import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../core/providers/openviking_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import 'package:Kelivo/theme/app_font_weights.dart';

class OpenVikingPage extends StatefulWidget {
  const OpenVikingPage({super.key, this.embedded = false});

  /// 嵌在桌面设置页中时不再套 Scaffold/AppBar。
  final bool embedded;

  @override
  State<OpenVikingPage> createState() => _OpenVikingPageState();
}

class _OpenVikingPageState extends State<OpenVikingPage> {
  late TextEditingController _urlCtrl;
  late TextEditingController _apiKeyCtrl;
  late TextEditingController _userCtrl;
  late TextEditingController _peerCtrl;

  @override
  void initState() {
    super.initState();
    final ov = context.read<OpenVikingProvider>();
    _urlCtrl = TextEditingController(text: ov.url);
    _apiKeyCtrl = TextEditingController(text: ov.apiKey);
    _userCtrl = TextEditingController(text: ov.user);
    _peerCtrl = TextEditingController(text: ov.peerId);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _userCtrl.dispose();
    _peerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final ov = context.watch<OpenVikingProvider>();

    final body = ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
          // Options（是否启用由 MCP 服务 @kelivo/openviking 的开 / 关决定）
          _sectionCard(
            cs,
            children: [
              _switchRow(cs, l10n.openVikingRecallQuestion, ov.recallQuestion, (v) {
                ov.setRecallQuestion(v);
              }),
              _divider(cs),
              _switchRow(cs, l10n.openVikingRecallStep, ov.recallStep, (v) {
                ov.setRecallStep(v);
              }),
              _divider(cs),
              _switchRow(cs, l10n.openVikingCommit, ov.commit, (v) {
                ov.setCommit(v);
              }),
              _divider(cs),
              _switchRow(cs, l10n.openVikingShowInjected, ov.showInjected, (v) {
                ov.setShowInjected(v);
              }),
            ],
          ),
          const SizedBox(height: 12),

          // Connection settings
          _sectionHeader(l10n.openVikingConnectionSection, cs),
          _sectionCard(
            cs,
            children: [
              _textFieldRow(
                cs,
                label: l10n.openVikingServerUrl,
                hint: 'http://192.168.x.x:1933',
                controller: _urlCtrl,
                onChanged: (v) => ov.setUrl(v),
              ),
              _divider(cs),
              _textFieldRow(
                cs,
                label: l10n.openVikingApiKey,
                hint: 'sk-...',
                controller: _apiKeyCtrl,
                onChanged: (v) => ov.setApiKey(v),
                obscure: true,
              ),
              _divider(cs),
              _textFieldRow(
                cs,
                label: l10n.openVikingUsername,
                hint: 'default',
                controller: _userCtrl,
                onChanged: (v) => ov.setUser(v),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Search settings
          _sectionHeader(l10n.openVikingSearchSection, cs),
          _sectionCard(
            cs,
            children: [
              _sliderRow(
                cs,
                label: l10n.openVikingThreshold(ov.threshold.toStringAsFixed(2)),
                value: ov.threshold,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                onChanged: (v) => ov.setThreshold(v),
              ),
              _divider(cs),
              _sliderRow(
                cs,
                label: l10n.openVikingDisplayCount(ov.displayCount.toString()),
                value: ov.displayCount.toDouble(),
                min: 0,
                max: 20,
                divisions: 20,
                onChanged: (v) => ov.setDisplayCount(v.round()),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Auto-injection (find) settings
          _sectionHeader(l10n.openVikingFindSection, cs),
          _sectionCard(
            cs,
            children: [
              _sliderRow(
                cs,
                label: l10n.openVikingFindThreshold(ov.findThreshold.toStringAsFixed(2)),
                value: ov.findThreshold,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                onChanged: (v) => ov.setFindThreshold(v),
              ),
              _divider(cs),
              _sliderRow(
                cs,
                label: l10n.openVikingFindLimit(ov.findLimit.toString()),
                value: ov.findLimit.toDouble(),
                min: 0,
                max: 20,
                divisions: 20,
                onChanged: (v) => ov.setFindLimit(v.round()),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Peer settings (android mode)
          _sectionHeader(l10n.openVikingPeerSection, cs),
          _sectionCard(
            cs,
            children: [
              _textFieldRow(
                cs,
                label: l10n.openVikingPeerId,
                hint: 'default',
                controller: _peerCtrl,
                onChanged: (v) => ov.setPeerId(v),
              ),
              _divider(cs),
              _switchRow(cs, l10n.openVikingWorkspacePeer, ov.workspacePeer, (v) {
                ov.setWorkspacePeer(v);
              }),
            ],
          ),
          const SizedBox(height: 24),

          // Status
          if (ov.isConfigured)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                l10n.openVikingStatusConfigured,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                l10n.openVikingStatusNotConfigured,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
        ],
    );

    if (widget.embedded) {
      return Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Align(
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
        title: Text(l10n.settingsPageOpenViking),
      ),
      body: body,
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

  Widget _switchRow(
    ColorScheme cs,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color: cs.onSurface.withValues(alpha: 0.9),
              ),
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _textFieldRow(
    ColorScheme cs, {
    required String label,
    required String hint,
    required TextEditingController controller,
    ValueChanged<String>? onChanged,
    bool obscure = false,
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
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            style: TextStyle(fontSize: 14, color: cs.onSurface),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _sliderRow(
    ColorScheme cs, {
    required String label,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
