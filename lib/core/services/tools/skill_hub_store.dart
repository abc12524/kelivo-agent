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

  static Future<String> getRepo() async {
    if (_repoCache != null) return _repoCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_repoKey);
    _repoCache = (v == null || v.trim().isEmpty) ? defaultRepo : v.trim();
    return _repoCache!;
  }

  static Future<void> setRepo(String repo) async {
    _repoCache = repo.trim().isEmpty ? defaultRepo : repo.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_repoKey, _repoCache!);
  }

  static Future<String> getBranch() async {
    if (_branchCache != null) return _branchCache!;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_branchKey);
    _branchCache = (v == null || v.trim().isEmpty) ? defaultBranch : v.trim();
    return _branchCache!;
  }

  static Future<void> setBranch(String branch) async {
    _branchCache = branch.trim().isEmpty ? defaultBranch : branch.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_branchKey, _branchCache!);
  }

  /// 仓库类型：`github` / `gitea`；空表示按是否配置 Gitea 基址自动推断。
  static Future<String> getType() async {
    if (_typeCache != null) return _typeCache!;
    final prefs = await SharedPreferences.getInstance();
    _typeCache = (prefs.getString(_typeKey) ?? '').trim();
    return _typeCache!;
  }

  static Future<void> setType(String type) async {
    _typeCache = type.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_typeKey, _typeCache!);
  }

  /// Gitea 服务基址（如 http://192.168.30.181:3000）；空表示未配置。
  static Future<String> getBase() async {
    if (_baseCache != null) return _baseCache!;
    final prefs = await SharedPreferences.getInstance();
    _baseCache = (prefs.getString(_baseKey) ?? '').trim();
    return _baseCache!;
  }

  static Future<void> setBase(String base) async {
    _baseCache = base.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseKey, _baseCache!);
  }

  /// 私有仓库访问令牌（GitHub / Gitea 通用）；空表示匿名访问。
  static Future<String> getToken() async {
    if (_tokenCache != null) return _tokenCache!;
    final prefs = await SharedPreferences.getInstance();
    _tokenCache = (prefs.getString(_tokenKey) ?? '').trim();
    return _tokenCache!;
  }

  static Future<void> setToken(String token) async {
    _tokenCache = token.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, _tokenCache!);
  }
}
