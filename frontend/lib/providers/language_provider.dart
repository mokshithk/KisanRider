import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../l10n/app_strings.dart';

/// Persists and broadcasts the active UI language (`'en'` or `'kn'`).
class LanguageProvider extends ChangeNotifier {
  LanguageProvider._internal();

  static final LanguageProvider instance = LanguageProvider._internal();

  static const String _storageKey = 'kisanrider_language_code';
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  String _languageCode = 'en';

  String get languageCode => _languageCode;
  bool get isKannada => _languageCode == 'kn';

  /// Loads any saved language preference from secure storage.
  Future<void> load() async {
    try {
      final saved = await _storage.read(key: _storageKey);
      final normalized = saved == 'kn' ? 'kn' : 'en';
      if (normalized != _languageCode || AppStrings.currentLanguage != normalized) {
        _languageCode = normalized;
        AppStrings.currentLanguage = normalized;
        notifyListeners();
      }
    } catch (_) {
      // Storage unavailable (e.g., headless tests) — keep default 'en'.
    }
  }

  /// Switches the active UI language (`'en'` or `'kn'`) and persists it.
  Future<void> setLanguage(String code) async {
    final normalized = code == 'kn' ? 'kn' : 'en';
    _languageCode = normalized;
    AppStrings.currentLanguage = normalized;
    notifyListeners();
    try {
      await _storage.write(key: _storageKey, value: normalized);
    } catch (_) {
      // Best-effort persistence.
    }
  }
}
