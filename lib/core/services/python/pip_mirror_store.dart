import 'package:shared_preferences/shared_preferences.dart';

/// 内置 Python 的 pip 镜像源。
///
/// 默认使用中科大（USTC）PyPI 镜像；模型在 `system_tool` 的 `python`（mode=pip）
/// 里传 `index_url` 即可覆盖——安装成功后持久化，后续未指定时沿用。
class PipMirrorStore {
  PipMirrorStore._();

  static const String defaultIndex = 'https://mirrors.ustc.edu.cn/pypi/simple';
  static const String _indexKey = 'python_pip_index_v1';

  static String? _cache;

  static Future<String> getIndex() async {
    final cached = _cache;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final saved = (prefs.getString(_indexKey) ?? '').trim();
    _cache = saved.isEmpty ? defaultIndex : saved;
    return _cache!;
  }

  /// 写入镜像源；空串表示恢复默认（中科大）。
  static Future<void> setIndex(String index) async {
    final saved = index.trim();
    _cache = saved.isEmpty ? defaultIndex : saved;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_indexKey, _cache!);
  }
}
