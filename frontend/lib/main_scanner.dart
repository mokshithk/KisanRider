import 'package:flutter/material.dart';

import 'providers/language_provider.dart';
import 'screens/scanner_payment_app.dart';

/// Dedicated entrypoint for App #2 — KisanRider Demo Mandi Payment Scanner.
///
/// Run with:
///   flutter run -t lib/main_scanner.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LanguageProvider.instance.load();
  runApp(const KisanRiderScannerApp());
}
