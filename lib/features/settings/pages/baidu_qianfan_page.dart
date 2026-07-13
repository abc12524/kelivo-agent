import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../core/services/baidu_qianfan/baidu_qianfan_service.dart';
import 'package:Kelivo/theme/app_font_weights.dart';

class BaiduQianfanPage extends StatefulWidget {
  const BaiduQianfanPage({super.key});
  @override
  State<BaiduQianfanPage> createState() => _BaiduQianfanPageState();
}

class _BaiduQianfanPageState extends State<BaiduQianfanPage> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: context.read<BaiduQianfanProvider>().apiKey);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = context.watch<BaiduQianfanProvider>();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Lucide.ArrowLeft), onPressed: () => Navigator.of(context).maybePop()),
        title: const Text('百度千帆'),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 16), children: [
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('API Key', style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.7))),
              ),
              TextField(
                controller: _ctrl,
                decoration: InputDecoration(
                  hintText: '请输入百度千帆 API Key',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                style: TextStyle(fontSize: 14, color: cs.onSurface),
                onChanged: (v) => p.setApiKey(v),
              ),
            ],
          )),
        ),
        const SizedBox(height: 12),
        if (p.isConfigured)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('✔️ API Key 已配置，AI 可以调用百度搜索和百科查询',
              style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.6))),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('⚠️ 请配置 API Key 后才能使用百度搜索和百科功能',
              style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.6))),
          ),
      ]),
    );
  }
}
