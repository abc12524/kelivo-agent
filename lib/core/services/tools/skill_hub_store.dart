import 'package:shared_preferences/shared_preferences.dart';

/// 远程技能仓库（skill_hub）下载源的本地存储：`owner/repo` 与分支，
/// 以及仓库类型（github / gitea）、Gitea 服务基址、私有仓库访问令牌。
class SkillHubStore {
  SkillHubStore._();

  static const String _repoKey = 'skill_hub_repo_v1';
  static const String _branchKey = 'skill_hub_branch_v1';
  static const String _typeKey = 'skill_hub_type_v1';
  static const String _baseKey = 'skill_hub_base_v1';
  static const String _tokenKey = 'skill_hub_token_v1';

  static const String defaultRepo = 'abc12524/shell-skills';
  static const String defaultBranch = 'main';

  static String? _repoCache;
  static String? _branchCache;
  static String? _typeCache;
  static String? _baseCache;
  static String? _tokenCache;

  /// 去掉粘贴引入的不可见字符（零宽空格 / BOM / 方向控制符等）并去掉首尾空白。
  ///
  /// 这些字符 `String.trim()` 不会处理（它们不是 Unicode 空白），却会被
  /// `Uri` 编码进 URL —— 例如零宽空格 U+200B 变成 `%E2%80%8B`，令拼出的
  /// 地址静默变形、请求打到不存在的仓库。读取时也清洗，可自愈历史脏数据。
  static String _clean(String s) =>
      s.replaceAll(_invisible, '').trim();

  static final RegExp _invisible = RegExp(
    r'[\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF]',
  );

  static Future<String> getRepo() async {
    if (_repoCache != null) return _repoCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = _clean(prefs.getString(_repoKey) ?? '');
    _repoCache = v.isEmpty ? defaultRepo : v;
    return _repoCache!;
  }

  static Future<void> setRepo(String repo) async {
    final v = _clean(repo);
    _repoCache = v.isEmpty ? defaultRepo : v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_repoKey, _repoCache!);
  }

  static Future<String> getBranch() async {
    if (_branchCache != null) return _branchCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = _clean(prefs.getString(_branchKey) ?? '');
    _branchCache = v.isEmpty ? defaultBranch : v;
    return _branchCache!;
  }

  static Future<void> setBranch(String branch) async {
    final v = _clean(branch);
    _branchCache = v.isEmpty ? defaultBranch : v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_branchKey, _branchCache!);
  }

  /// 仓库类型：`github` / `gitea`；空表示按是否配置 Gitea 基址自动推断。
  static Future<String> getType() async {
    if (_typeCache != null) return _typeCache!;
    final prefs = await SharedPreferences.getInstance();
    _typeCache = _clean(prefs.getString(_typeKey) ?? '');
    return _typeCache!;
  }

  static Future<void> setType(String type) async {
    _typeCache = _clean(type);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_typeKey, _typeCache!);
  }

  /// Gitea 服务基址（如 http://192.168.30.181:3000）；空表示未配置。
  static Future<String> getBase() async {
    if (_baseCache != null) return _baseCache!;
    final prefs = await SharedPreferences.getInstance();
    _baseCache = _clean(prefs.getString(_baseKey) ?? '');
    return _baseCache!;
  }

  static Future<void> setBase(String base) async {
    _baseCache = _clean(base);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseKey, _baseCache!);
  }

  /// 私有仓库访问令牌（GitHub / Gitea 通用）；空表示匿名访问。
  static Future<String> getToken() async {
    if (_tokenCache != null) return _tokenCache!;
    final prefs = await SharedPreferences.getInstance();
    _tokenCache = _clean(prefs.getString(_tokenKey) ?? '');
    return _tokenCache!;
  }

  static Future<void> setToken(String token) async {
    _tokenCache = _clean(token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, _tokenCache!);
  }
}
