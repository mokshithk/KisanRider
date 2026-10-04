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
  static const String _fullNameKey = 'user_full_name';
  static const String _emailKey = 'user_email';
  static const String _districtKey = 'user_district';
  static const String _stateKey = 'user_state';

  bool _isLoggedIn = false;
  String? _role; // 'FARMER' | 'RIDER'
  String? _userId;
  String? _token;

  /// Profile fields surfaced from the login / signup response's `user`
  /// object. All nullable — a session restored from an older app version
  /// (before these keys existed) will simply have them as null until the
  /// next login. The Account screen falls back to `GET /farmer/account`
  /// when these are missing.
  String? _fullName;
  String? _email;
  String? _district;
  String? _state;

  bool _isInitializing = true;
  bool _isLoggingIn = false;
  String? _lastError;

  bool get isLoggedIn => _isLoggedIn;

  /// Alias for [isLoggedIn]. Provided so callers that express the check as
  /// "is the user authenticated?" read naturally — e.g. the auth-gated
  /// routing branch in main.dart, or a logout button's enabled state.
  bool get isAuthenticated => _isLoggedIn;

  String? get role => _role;
  String? get userId => _userId;
  String? get token => _token;
  String? get fullName => _fullName;
  String? get email => _email;
  String? get district => _district;
  String? get state => _state;

  /// True while the provider is checking secure storage for an existing
  /// session on app startup. Useful for showing a splash/loading screen.
  bool get isInitializing => _isInitializing;

  /// True while a login request is in flight (either [login] or [devLogin]).
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
        _token = token;

        // Profile fields are best-effort — an older install may not have
        // them stored, in which case they stay null.
        _fullName = await _secureStorage.read(key: _fullNameKey);
        _email = await _secureStorage.read(key: _emailKey);
        _district = await _secureStorage.read(key: _districtKey);
        _state = await _secureStorage.read(key: _stateKey);
      }
    } catch (_) {
      // If secure storage is unreadable, fall back to a logged-out state.
      _isLoggedIn = false;
      _role = null;
      _userId = null;
      _token = null;
      _fullName = null;
      _email = null;
      _district = null;
      _state = null;
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  /// Persists the profile fields that arrived alongside the token. Kept as
  /// its own method so [login], [devLogin], and [completeSignup] all share
  /// one write path — a field added here is automatically picked up by
  /// every auth entry point.
  ///
  /// Any param passed as null clears the corresponding stored key. That's
  /// the correct behavior for [devLogin], whose response carries no user
  /// object at all.
  Future<void> _persistProfileFields({
    String? fullName,
    String? email,
    String? district,
    String? state,
  }) async {
    Future<void> write(String key, String? value) async {
      if (value == null || value.isEmpty) {
        await _secureStorage.delete(key: key);
      } else {
        await _secureStorage.write(key: key, value: value);
      }
    }

    await write(_fullNameKey, fullName);
    await write(_emailKey, email);
    await write(_districtKey, district);
    await write(_stateKey, state);

    _fullName = (fullName == null || fullName.isEmpty) ? null : fullName;
    _email = (email == null || email.isEmpty) ? null : email;
    _district = (district == null || district.isEmpty) ? null : district;
    _state = (state == null || state.isEmpty) ? null : state;
  }

  /// Standard email + password login against `POST /auth/login`.
  ///
  /// On success, persists the JWT, role, user id, and profile fields to
  /// secure storage and flips in-memory state to logged-in. The caller (or
  /// the root widget observing [notifyListeners]) can then route based on
  /// [role].
  ///
  /// Returns `true` on success. On failure returns `false` and sets
  /// [lastError] to the server's `detail` message — most commonly
  /// "Invalid email or password" — which the caller should surface as-is.
  Future<bool> login(String email, String password) async {
    _isLoggingIn = true;
    _lastError = null;
    notifyListeners();

    try {
      final response = await ApiService.dio.post(
        '/auth/login',
        data: {
          // Normalize email client-side too — the backend does it as well,
          // but this keeps the request body identical to what /auth/signup
          // sent at registration, which helps if you ever add request
          // logging.
          'email': email.trim().toLowerCase(),
          'password': password,
        },
      );

      if (response.statusCode == 200 && response.data != null) {
        final data = response.data as Map<String, dynamic>;
        final token = data['access_token'] as String?;
        final user = data['user'] as Map<String, dynamic>?;
        final userRole = (user?['role'] ?? '').toString();
        final userId = (user?['id'] ?? '').toString();
        final userFullName = (user?['full_name'] ?? '').toString();
        final userEmail = (user?['email'] ?? '').toString();
        final userDistrict = (user?['district'] ?? '').toString();
        final userState = (user?['state'] ?? '').toString();

        if (token == null ||
            token.isEmpty ||
            userRole.isEmpty ||
            userId.isEmpty) {
          _lastError = 'Server returned an incomplete session.';
          _isLoggingIn = false;
          notifyListeners();
          return false;
        }

        await _secureStorage.write(key: _tokenKey, value: token);
        await _secureStorage.write(key: _roleKey, value: userRole);
        await _secureStorage.write(key: _userIdKey, value: userId);
        await _persistProfileFields(
          fullName: userFullName,
          email: userEmail,
          district: userDistrict,
          state: userState,
        );

        _isLoggedIn = true;
        _role = userRole;
        _userId = userId;
        _token = token;
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

  /// Logs in using the backend's dev-token flow:
  /// `POST /auth/dev-token?user_id=<uuid>`.
  ///
  /// Retained for local development; not reachable in production because
  /// the backend 404s that route when ENVIRONMENT=production. The current
  /// login UI doesn't expose it — call [login] instead.
  ///
  /// The dev-token response carries no user object, so profile fields are
  /// explicitly cleared. The Account screen will fetch them from
  /// `GET /farmer/account` on first open.
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
        await _persistProfileFields();

        _isLoggedIn = true;
        _role = selectedRole;
        _userId = uuid;
        _token = token;
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

  /// Persists a session established by the email-OTP signup flow.
  ///
  /// The signup screen has already hit `/auth/verify-otp` and has the
  /// `access_token`, `role`, and user id in hand — this method just
  /// centralizes the storage writes and in-memory state update so the rest
  /// of the app sees a "just logged in" transition, exactly like
  /// [login] does on success.
  ///
  /// [fullName], [email], [district], and [state] are optional. Callers
  /// that already have the user object (which `/auth/verify-otp` returns)
  /// can pass them so the Account screen's header renders instantly on
  /// first open. Callers that don't (older code) can leave them out — the
  /// Account screen falls back to `GET /farmer/account`.
  ///
  /// Returns `true` on success, `false` if secure storage rejected the
  /// write (in which case [lastError] explains why and the caller should
  /// NOT navigate).
  Future<bool> completeSignup({
    required String token,
    required String role,
    required String userId,
    String? fullName,
    String? email,
    String? district,
    String? state,
  }) async {
    _lastError = null;

    try {
      await _secureStorage.write(key: _tokenKey, value: token);
      await _secureStorage.write(key: _roleKey, value: role);
      await _secureStorage.write(key: _userIdKey, value: userId);
      await _persistProfileFields(
        fullName: fullName,
        email: email,
        district: district,
        state: state,
      );

      _isLoggedIn = true;
      _role = role;
      _userId = userId;
      _token = token;
      notifyListeners();
      return true;
    } catch (e) {
      _lastError = 'Could not save session: $e';
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
  ///
  /// Three things must happen for the app to reach a clean logged-out
  /// state, and all three are done here:
  ///
  ///   1. Wipe the JWT, role, user id, and profile fields from secure
  ///      storage so a restart doesn't resurrect the session.
  ///   2. Reset the in-memory fields so nothing downstream can read a
  ///      stale token or display a previous user's name.
  ///   3. `notifyListeners()` so any `Consumer<AuthProvider>` /
  ///      `context.watch` in the tree rebuilds immediately.
  ///
  /// The storage wipe is wrapped in a `try` on purpose: if the platform
  /// channel to secure storage is misbehaving, we still want the in-memory
  /// reset + notification to fire. Leaving the app half-logged-in (screen
  /// still shows the dashboard, but the token is gone) is a worse failure
  /// mode than a stale keychain entry that the next successful login will
  /// overwrite.
  Future<void> logout() async {
    try {
      await _secureStorage.delete(key: _tokenKey);
      await _secureStorage.delete(key: _roleKey);
      await _secureStorage.delete(key: _userIdKey);
      await _secureStorage.delete(key: _fullNameKey);
      await _secureStorage.delete(key: _emailKey);
      await _secureStorage.delete(key: _districtKey);
      await _secureStorage.delete(key: _stateKey);
    } catch (_) {
      // Swallow — see comment above. In-memory state still gets reset.
    }

    _isLoggedIn = false;
    _role = null;
    _userId = null;
    _token = null;
    _fullName = null;
    _email = null;
    _district = null;
    _state = null;
    _lastError = null;
    notifyListeners();
  }
}