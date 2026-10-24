import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/openviking/openviking_service.dart';

class OpenVikingProvider extends ChangeNotifier {
  static const _uKey = 'ov_url_v1';
  static const _aKey = 'ov_api_key_v1';
  static const _wKey = 'ov_user_v1';
  static const _tKey = 'ov_threshold_v1';
  static const _dKey = 'ov_display_count_v1';
  static const _fTKey = 'ov_find_threshold_v1';
  static const _fLKey = 'ov_find_limit_v1';
  static const _recallQuestionKey = 'ov_recall_question_v1';
  static const _recallStepKey = 'ov_recall_step_v1';
  static const _commitKey = 'ov_commit_v1';
  static const _showInjectedKey = 'show_injected_messages_v1';
  static const _peerKey = 'ov_peer_id_v1';
  static const _userTipsKey = 'ov_user_tips_v1';
  static const _wsPeerKey = 'ov_workspace_peer_v1';

  String _url = '';
  String _apiKey = '';
  String _user = 'default';
  double _threshold = 0.35;
  int _displayCount = 3;
  double _findThreshold = 0.4;
  int _findLimit = 3;
  bool _recallQuestion = true;
  bool _recallStep = false;
  bool _commit = false;
  bool _showInjected = false;
  String _peerId = '';
  bool _workspacePeer = false;
  String _userTips = '';
  String _packageName = '';

  String get url => _url;
  String get apiKey => _apiKey;
  String get user => _user;
  double get threshold => _threshold;
  int get displayCount => _displayCount;
  double get findThreshold => _findThreshold;
  int get findLimit => _findLimit;
  bool get recallQuestion => _recallQuestion;
  bool get recallStep => _recallStep;
  bool get commit => _commit;
  bool get showInjected => _showInjected;
  String get peerId => _peerId;
  bool get workspacePeer => _workspacePeer;
  String get userTips => _userTips;

  OpenVikingService? _service;
  OpenVikingService? get service => _service;
  bool get isConfigured => _url.isNotEmpty && _apiKey.isNotEmpty;

  OpenVikingProvider() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _url = prefs.getString(_uKey) ?? '';
    _apiKey = prefs.getString(_aKey) ?? '';
    _user = prefs.getString(_wKey) ?? 'default';
    _threshold = prefs.getDouble(_tKey) ?? 0.35;
    _displayCount = prefs.getInt(_dKey) ?? 3;
    _findThreshold = prefs.getDouble(_fTKey) ?? 0.4;
    _findLimit = prefs.getInt(_fLKey) ?? 3;
    _recallQuestion = prefs.getBool(_recallQuestionKey) ?? true;
    _recallStep = prefs.getBool(_recallStepKey) ?? false;
    _commit = prefs.getBool(_commitKey) ?? false;
    _showInjected = prefs.getBool(_showInjectedKey) ?? false;
    _peerId = prefs.getString(_peerKey) ?? '';
    _workspacePeer = prefs.getBool(_wsPeerKey) ?? false;
    _userTips = prefs.getString(_userTipsKey) ?? '';
    _rebuildService();
    notifyListeners();
    await _loadPackageName();
  }

  Future<void> _loadPackageName() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _packageName = info.packageName;
      _rebuildService();
      notifyListeners();
    } catch (_) {}
  }

  void _rebuildService() {
    if (_url.isNotEmpty && _apiKey.isNotEmpty) {
      _service = OpenVikingService(
        baseUrl: _url,
        apiKey: _apiKey,
        user: _user,
        explicitPeerId: _peerId,
        workspacePeer: _workspacePeer,
        packageName: _packageName,
      );
    } else {
      _service = null;
    }
  }

  Future<void> setUrl(String v) async {
    _url = v.trim();
    _rebuildService();
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_uKey, _url);
  }

  Future<void> setApiKey(String v) async {
    _apiKey = v.trim();
    _rebuildService();
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_aKey, _apiKey);
  }

  Future<void> setThreshold(double v) async {
    _threshold = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setDouble(_tKey, v);
  }

  Future<void> setUser(String v) async {
    _user = v.trim();
    _rebuildService();
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_wKey, _user);
  }

  Future<void> setDisplayCount(int v) async {
    _displayCount = v.clamp(0, 20);
    notifyListeners();
    (await SharedPreferences.getInstance()).setInt(_dKey, _displayCount);
  }

  Future<void> setFindThreshold(double v) async {
    _findThreshold = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setDouble(_fTKey, v);
  }

  Future<void> setFindLimit(int v) async {
    _findLimit = v.clamp(0, 20);
    notifyListeners();
    (await SharedPreferences.getInstance()).setInt(_fLKey, _findLimit);
  }

  Future<void> setRecallQuestion(bool v) async {
    _recallQuestion = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_recallQuestionKey, v);
  }

  Future<void> setRecallStep(bool v) async {
    _recallStep = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_recallStepKey, v);
  }

  Future<void> setCommit(bool v) async {
    _commit = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_commitKey, v);
  }

  Future<void> setShowInjected(bool v) async {
    _showInjected = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_showInjectedKey, v);
  }

  Future<void> setPeerId(String v) async {
    _peerId = v.trim();
    _rebuildService();
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_peerKey, _peerId);
  }

  Future<void> setWorkspacePeer(bool v) async {
    _workspacePeer = v;
    _rebuildService();
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_wsPeerKey, v);
  }

  Future<void> setUserTips(String v) async {
    _userTips = v.trim();
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_userTipsKey, _userTips);
  }

}
