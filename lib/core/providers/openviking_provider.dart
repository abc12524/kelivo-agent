import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/openviking/openviking_service.dart';

class OpenVikingProvider extends ChangeNotifier {
  static const _eKey = 'ov_enabled_v1';
  static const _uKey = 'ov_url_v1';
  static const _aKey = 'ov_api_key_v1';
  static const _wKey = 'ov_user_v1';
  static const _tKey = 'ov_threshold_v1';
  static const _dKey = 'ov_display_count_v1';
  static const _fTKey = 'ov_find_threshold_v1';
  static const _fLKey = 'ov_find_limit_v1';
  static const _cKey = 'ov_auto_capture_v1';

  bool _enabled = false;
  String _url = '';
  String _apiKey = '';
  String _user = 'default';
  double _threshold = 0.35;
  int _displayCount = 3;
  double _findThreshold = 0.4;
  int _findLimit = 3;
  bool _autoCapture = true;

  bool get enabled => _enabled;
  String get url => _url;
  String get apiKey => _apiKey;
  String get user => _user;
  double get threshold => _threshold;
  int get displayCount => _displayCount;
  double get findThreshold => _findThreshold;
  int get findLimit => _findLimit;
  bool get autoCapture => _autoCapture;

  OpenVikingService? _service;
  OpenVikingService? get service => _service;
  bool get isConfigured => _url.isNotEmpty && _apiKey.isNotEmpty;

  OpenVikingProvider() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_eKey) ?? false;
    _url = prefs.getString(_uKey) ?? '';
    _apiKey = prefs.getString(_aKey) ?? '';
    _user = prefs.getString(_wKey) ?? 'default';
    _threshold = prefs.getDouble(_tKey) ?? 0.35;
    _displayCount = prefs.getInt(_dKey) ?? 3;
    _findThreshold = prefs.getDouble(_fTKey) ?? 0.4;
    _findLimit = prefs.getInt(_fLKey) ?? 3;
    _autoCapture = prefs.getBool(_cKey) ?? true;
    _rebuildService();
    notifyListeners();
  }

  void _rebuildService() {
    if (_url.isNotEmpty && _apiKey.isNotEmpty) {
      _service = OpenVikingService(baseUrl: _url, apiKey: _apiKey, user: _user);
    } else {
      _service = null;
    }
  }

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_eKey, v);
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

  Future<void> setAutoCapture(bool v) async {
    _autoCapture = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_cKey, v);
  }
}
