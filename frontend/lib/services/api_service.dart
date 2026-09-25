import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Centralized API service for KisanRider.
///
/// Exposes a single global [Dio] instance ([ApiService.dio]) that every
/// repository/service in the app should use, so the auth interceptor is
/// applied consistently everywhere.
class ApiService {
  ApiService._internal();

  /// Base URL for the FastAPI backend.
  ///
  /// - Use `http://localhost:8000` for Web / Chrome testing.
  /// - Use `http://10.0.2.2:8000` for Android Emulator.
  static const String baseUrl = 'http://127.0.0.1:8000';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  /// Global Dio instance used across the app.
  static final Dio dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
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