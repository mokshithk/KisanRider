import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'l10n/app_strings.dart';
import 'providers/auth_provider.dart';
import 'providers/language_provider.dart';
import 'screens/farmer_dashboard.dart';
import 'screens/login_screen.dart';
import 'screens/rider_dashboard.dart';
import 'services/api_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ApiService.setupInterceptors();
  await LanguageProvider.instance.load();
  runApp(const KisanRiderApp());
}

class KisanRiderApp extends StatelessWidget {
  const KisanRiderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider.value(value: LanguageProvider.instance),
      ],
      child: Builder(
        builder: (context) {
          final lang = context.watch<LanguageProvider>();
          return MaterialApp(
            title: AppStrings.tr('KisanRider', lang: lang.languageCode),
            locale: Locale(lang.languageCode),
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF2E7D32), // agricultural green
              ),
              fontFamily: 'AppRoboto',
              useMaterial3: true,
            ),
            home: const _AuthGate(),
          );
        },
      ),
    );
  }
}

/// Decides which screen to show based on the current [AuthProvider] state:
/// - Still checking secure storage -> loading splash.
/// - Not logged in -> [LoginScreen].
/// - Logged in as FARMER -> [FarmerDashboard].
/// - Logged in as RIDER -> [RiderDashboard].
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    if (auth.isInitializing) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (!auth.isLoggedIn) {
      return const LoginScreen();
    }

    switch (auth.role) {
      case 'FARMER':
        return const FarmerDashboard();
      case 'RIDER':
        return const RiderDashboard();
      default:
        // Defensive fallback: unrecognized/missing role -> force re-login.
        return const LoginScreen();
    }
  }
}