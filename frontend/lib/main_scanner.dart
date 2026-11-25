import 'package:flutter/material.dart';

import 'screens/scanner_payment_app.dart';

/// Dedicated entrypoint for App #2 — KisanRider Demo Mandi Payment Scanner.
///
/// Run with:
///   flutter run -t lib/main_scanner.dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KisanRiderScannerApp());
}
