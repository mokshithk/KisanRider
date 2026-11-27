import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;

const String _kEnvApiBaseUrl = String.fromEnvironment('API_BASE_URL');

/// Centralized API service for KisanRider.
///
/// Exposes a single global [Dio] instance ([ApiService.dio]) that every
/// repository/service in the app should use, so the auth interceptor is
/// applied consistently everywhere.
class ApiService {
  ApiService._internal();

  /// Base URL for the FastAPI backend.
  ///
  /// - Uses `--dart-define=API_BASE_URL=...` when provided.
  /// - Web/Chrome defaults to `http://localhost:8000` for local testing.
  /// - Android/iOS builds connect to the hosted Render backend.
  static String get baseUrl {
    if (_kEnvApiBaseUrl.isNotEmpty) {
      return _kEnvApiBaseUrl;
    }
    if (kIsWeb) {
      // Running in Chrome / Web browser
      return 'http://localhost:8000';
    } else if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      // Running on a physical phone
      return 'https://kisanrider.onrender.com';
    }
    // Fallback for desktop apps
    return 'http://localhost:8000';
  }

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  /// Global Dio instance used across the app.
  static final Dio dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 45),
      receiveTimeout: const Duration(seconds: 45),
      sendTimeout: const Duration(seconds: 45),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ),
  );

  static bool _interceptorsInitialized = false;

  /// Registers the request interceptor that attaches the JWT bearer token
  /// (if present in secure storage) to every outgoing request.
  ///
  /// Safe to call multiple times — interceptors are only added once.
  static void setupInterceptors() {
    if (_interceptorsInitialized) return;
    _interceptorsInitialized = true;

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          try {
            final token = await _secureStorage.read(key: 'jwt_token');
            if (token != null && token.isNotEmpty) {
              options.headers['Authorization'] = 'Bearer $token';
            }
          } catch (_) {
            // If secure storage read fails, proceed without the auth header.
          }
          handler.next(options);
        },
        onError: (DioException error, handler) {
          handler.next(error);
        },
      ),
    );

    // Development logging interceptor
    dio.interceptors.add(
      LogInterceptor(
        requestBody: true,
        responseBody: true,
        error: true,
      ),
    );
  }
}