import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/auth_provider.dart';
import 'screens/farmer_dashboard.dart';
import 'screens/login_screen.dart';
import 'screens/rider_dashboard.dart';
import 'services/api_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ApiService.setupInterceptors();
  runApp(const KisanRiderApp());
}

class KisanRiderApp extends StatelessWidget {
  const KisanRiderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AuthProvider(),
      child: MaterialApp(
        title: 'KisanRider',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2E7D32), // agricultural green
          ),
          useMaterial3: true,
        ),
        home: const _AuthGate(),
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