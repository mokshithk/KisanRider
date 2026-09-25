import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/api_service.dart';

/// Holds authentication state for KisanRider and persists it across app
/// restarts using [FlutterSecureStorage].
class AuthProvider extends ChangeNotifier {
  AuthProvider() {
    _loadSession();
  }

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static const String _tokenKey = 'jwt_token';
  static const String _roleKey = 'user_role';
  static const String _userIdKey = 'user_id';

  bool _isLoggedIn = false;
  String? _role; // 'FARMER' | 'RIDER'
  String? _userId;
  bool _isInitializing = true;
  bool _isLoggingIn = false;
  String? _lastError;

  bool get isLoggedIn => _isLoggedIn;
  String? get role => _role;
  String? get userId => _userId;

  /// True while the provider is checking secure storage for an existing
  /// session on app startup. Useful for showing a splash/loading screen.
  bool get isInitializing => _isInitializing;

  /// True while a `devLogin` call is in flight.
  bool get isLoggingIn => _isLoggingIn;

  /// The error message from the most recent failed login attempt, if any.
  String? get lastError => _lastError;

  /// Reads any previously stored session from secure storage on startup so
  /// the user stays logged in across app restarts.
  Future<void> _loadSession() async {
    try {
      final token = await _secureStorage.read(key: _tokenKey);
      final storedRole = await _secureStorage.read(key: _roleKey);
      final storedUserId = await _secureStorage.read(key: _userIdKey);

      if (token != null &&
          token.isNotEmpty &&
          storedRole != null &&
          storedUserId != null) {
        _isLoggedIn = true;
        _role = storedRole;
        _userId = storedUserId;
      }
    } catch (_) {
      // If secure storage is unreadable, fall back to a logged-out state.
      _isLoggedIn = false;
      _role = null;
      _userId = null;
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  /// Logs in using the backend's dev-token flow:
  /// `POST /auth/dev-token?user_id=<uuid>`.
  ///
  /// On success, persists the token, role, and user id to secure storage,
  /// updates in-memory state, and notifies listeners.
  ///
  /// Returns `true` on success, `false` on failure (check [lastError] for
  /// details).
  Future<bool> devLogin(String uuid, String selectedRole) async {
    _isLoggingIn = true;
    _lastError = null;
    notifyListeners();

    try {
      final response = await ApiService.dio.post(
        '/auth/dev-token',
        queryParameters: {'user_id': uuid},
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data as Map<String, dynamic>;
        final token = data['access_token'] as String?;

        if (token == null || token.isEmpty) {
          _lastError = 'No access token returned by server.';
          _isLoggingIn = false;
          notifyListeners();
          return false;
        }

        await _secureStorage.write(key: _tokenKey, value: token);
        await _secureStorage.write(key: _roleKey, value: selectedRole);
        await _secureStorage.write(key: _userIdKey, value: uuid);

        _isLoggedIn = true;
        _role = selectedRole;
        _userId = uuid;
        _isLoggingIn = false;
        notifyListeners();
        return true;
      } else {
        _lastError = 'Unexpected response (status ${response.statusCode}).';
        _isLoggingIn = false;
        notifyListeners();
        return false;
      }
    } on DioException catch (e) {
      _lastError = _messageFromDioException(e);
      _isLoggingIn = false;
      notifyListeners();
      return false;
    } catch (e) {
      _lastError = 'Unexpected error: $e';
      _isLoggingIn = false;
      notifyListeners();
      return false;
    }
  }

  String _messageFromDioException(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return 'Connection to server timed out. Is the backend running?';
    }
    if (e.type == DioExceptionType.connectionError) {
      return 'Could not connect to server at ${ApiService.baseUrl}.';
    }
    final status = e.response?.statusCode;
    if (status != null) {
      final detail = e.response?.data is Map
          ? (e.response?.data['detail']?.toString())
          : null;
      return detail ?? 'Login failed (status $status).';
    }
    return e.message ?? 'Login failed.';
  }

  /// Clears the persisted session and resets in-memory state.
  Future<void> logout() async {
    await _secureStorage.delete(key: _tokenKey);
    await _secureStorage.delete(key: _roleKey);
    await _secureStorage.delete(key: _userIdKey);

    _isLoggedIn = false;
    _role = null;
    _userId = null;
    _lastError = null;
    notifyListeners();
  }
}