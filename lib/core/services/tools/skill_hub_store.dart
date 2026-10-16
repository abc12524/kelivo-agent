import 'package:shared_preferences/shared_preferences.dart';

/// 远程技能仓库（skill_hub）下载源的本地存储：GitHub `owner/repo` 与分支。
class SkillHubStore {
  SkillHubStore._();

  static const String _repoKey = 'skill_hub_repo_v1';
  static const String _branchKey = 'skill_hub_branch_v1';

  static const String defaultRepo = 'abc12524/shell-skills';
  static const String defaultBranch = 'main';

  static String? _repoCache;
  static String? _branchCache;

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
}
