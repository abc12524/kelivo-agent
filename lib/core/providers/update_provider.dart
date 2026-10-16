import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class UpdateInfo {
  final String app;
  final String version;
  final int? build;
  final DateTime? releasedAt;
  final String? notes;
  final bool mandatory;
  final Map<String, String> downloads;

  const UpdateInfo({
    required this.app,
    required this.version,
    this.build,
    this.releasedAt,
    this.notes,
    this.mandatory = false,
    this.downloads = const {},
  });

  String? bestDownloadUrl() {
    if (Platform.isIOS) {
      return downloads['ios'] ??
          downloads['iosAppStore'] ??
          downloads['universal'];
    }
    if (Platform.isAndroid) {
      return downloads['android'] ?? downloads['universal'];
    }
    if (Platform.isMacOS) {
      return downloads['macos'] ??
          downloads['mac'] ??
          downloads['darwin'] ??
          downloads['universal'];
    }
    if (Platform.isWindows) {
      return downloads['windows'] ?? downloads['win'] ?? downloads['universal'];
    }
    if (Platform.isLinux) {
      return downloads['linux'] ?? downloads['universal'];
    }
    return downloads['universal'] ?? downloads['android'] ?? downloads['ios'];
  }
}

/// 更新源：本仓库 GitHub Releases（tag = v<major>.<minor>.<build>，
/// 其中 build 即 CI run_number，发布说明里也会写明「构建号」）。
class UpdateProvider extends ChangeNotifier {
  static const String owner = 'abc12524';
  static const String repo = 'kelivo-agent';
  static const String _releasesLatestUrl =
      'https://api.github.com/repos/$owner/$repo/releases/latest';

  UpdateInfo? _available;
  UpdateInfo? get available => _available;
  bool _checking = false;
  bool get checking => _checking;
  String? _error;
  String? get error => _error;

  Future<void> checkForUpdates() async {
    if (_checking) return;
    _checking = true;
    _error = null;
    notifyListeners();
    try {
      final resp = await http.get(
        Uri.parse(_releasesLatestUrl),
        headers: const {
          'Accept': 'application/vnd.github+json',
          // GitHub API 要求带 User-Agent，否则返回 403。
          'User-Agent': 'Kelivo',
        },
      );
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final json =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final info = _parseRelease(json);

      final pkg = await PackageInfo.fromPlatform();
      final hasNew = _isRemoteNewer(
        remoteVersion: info.version,
        currentVersion: pkg.version,
        remoteBuild: info.build,
        currentBuild: int.tryParse(pkg.buildNumber),
      );
      _available = hasNew ? info : null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  UpdateInfo _parseRelease(Map<String, dynamic> json) {
    final tag = (json['tag_name'] ?? '').toString().trim();
    final rawVersion = (tag.startsWith('v') || tag.startsWith('V'))
        ? tag.substring(1)
        : tag;
    // 兼容 v1.1.73（构建号=修订号）与 v1.1.17-build.51 两种 tag。
    final version = rawVersion.split('-').first;

    final body = (json['body'] ?? '').toString();
    final build = _buildFromBody(body) ?? _buildFromVersion(rawVersion);

    final downloads = <String, String>{};
    final assets = (json['assets'] as List?) ?? const [];
    for (final asset in assets) {
      if (asset is! Map) continue;
      final url = (asset['browser_download_url'] ?? '').toString();
      if (url.isEmpty) continue;
      final name = (asset['name'] ?? '').toString();
      downloads.putIfAbsent(_platformKey(name), () => url);
    }

    DateTime? released;
    final raw = (json['published_at'] ?? json['created_at'])?.toString();
    if (raw != null && raw.isNotEmpty) {
      try {
        released = DateTime.parse(raw);
      } catch (_) {}
    }

    final notes = body.trim();
    return UpdateInfo(
      app: (json['name'] ?? 'Kelivo').toString(),
      version: version,
      build: build,
      releasedAt: released,
      notes: notes.isEmpty ? null : notes,
      mandatory: false,
      downloads: downloads,
    );
  }

  int? _buildFromBody(String body) {
    final m = RegExp(r'构建号[：:]\s*(\d+)').firstMatch(body);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  int? _buildFromVersion(String version) {
    final buildTag = RegExp(
      r'build[.\-](\d+)',
      caseSensitive: false,
    ).firstMatch(version);
    if (buildTag != null) return int.tryParse(buildTag.group(1)!);
    final parts = version.split('.');
    if (parts.length >= 3) return int.tryParse(parts[2]);
    return null;
  }

  String _platformKey(String assetName) {
    final n = assetName.toLowerCase();
    if (n.endsWith('.apk')) return 'android';
    if (n.endsWith('.ipa')) return 'ios';
    if (n.endsWith('.dmg') || n.endsWith('.pkg')) return 'macos';
    if (n.endsWith('.exe') || n.endsWith('.msi')) return 'windows';
    if (n.endsWith('.appimage') || n.endsWith('.deb') || n.endsWith('.tar.gz')) {
      return 'linux';
    }
    return 'universal';
  }

  bool _isRemoteNewer({
    required String remoteVersion,
    required String currentVersion,
    int? remoteBuild,
    int? currentBuild,
  }) {
    List<int> parseVer(String v) {
      final core = v.split('-').first;
      final parts = core.split('.');
      final nums = <int>[];
      for (int i = 0; i < 3; i++) {
        nums.add(i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0);
      }
      return nums;
    }

    final a = parseVer(remoteVersion);
    final b = parseVer(currentVersion);
    for (int i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    // 版本号相同则比较编译号（CI run_number）。
    if (remoteBuild != null && currentBuild != null) {
      return remoteBuild > currentBuild;
    }
    return false;
  }
}
