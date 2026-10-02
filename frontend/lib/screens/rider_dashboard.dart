import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'login_screen.dart';
import 'rider_account_tab.dart';
import 'rider_active_tab.dart';
import 'rider_available_tab.dart';
import 'rider_common.dart';
import 'rider_earnings_tab.dart';

// ---------------------------------------------------------------------------
// Logout helper — shared by the AppBar icon and (optionally) the Account tab.
// ---------------------------------------------------------------------------

/// Shows the "Are you sure you want to log out?" confirmation dialog, then
/// logs out and navigates to [LoginScreen].
///
/// ## Why this navigates manually
///
/// `login_screen.dart` uses `pushAndRemoveUntil(..., (route) => false)` to
/// route to the dashboard after a successful login. That predicate removes
/// **every** route in the Navigator, including the `MaterialApp.home` route
/// that hosted `_AuthGate`. So by the time the user taps Logout, `_AuthGate`
/// is no longer mounted and cannot react to `notifyListeners()`. The only
/// way back to the login screen is to replace the stack explicitly — which
/// is what this function does.
///
/// ## Order of operations
///
/// `auth.logout()` is awaited first so secure storage is cleared and
/// `_AuthGate` (if it happens to still be alive) gets a chance to rebuild.
/// Then we clear the Navigator. Doing it in the other order risks a rebuild
/// of `_AuthGate` pushing a second `LoginScreen` on top of ours.
///
/// `navigator` is captured **before** the `await` on purpose: after the
/// await, `context` may be stale if the widget has already been disposed.
/// The captured `NavigatorState` remains valid for the frame.
///
/// Exposed with a public name so `rider_account_tab.dart` (in a sibling
/// file) can reuse it:
///
///     import 'rider_dashboard.dart' show confirmAndLogout;
Future<void> confirmAndLogout(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Log out?'),
      content: const Text('Are you sure you want to log out?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: kRiderGreen,
            foregroundColor: Colors.white,
          ),
          child: const Text('Logout'),
        ),
      ],
    ),
  );

  if (confirmed != true || !context.mounted) return;

  final auth = context.read<AuthProvider>();
  final navigator = Navigator.of(context);

  try {
    await auth.logout();
  } catch (_) {
    // Even if secure-storage cleanup threw, we still want to leave the
    // dashboard. Fall through to the navigation below.
  }

  navigator.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (Route<dynamic> route) => false,
  );
}

/// Rider shell: 4-tab bottom navigation hosting the Available feed, Active
/// Trips, Earnings, and Account screens.
class RiderDashboard extends StatefulWidget {
  const RiderDashboard({super.key});

  @override
  State<RiderDashboard> createState() => _RiderDashboardState();
}

class _RiderDashboardState extends State<RiderDashboard> {
  int _currentIndex = 0;

  static const List<String> _titles = [
    'Available Requests',
    'Active Trips',
    'Earnings',
    'Account',
  ];

  void _goToTab(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_currentIndex]),
        backgroundColor: kRiderGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () => confirmAndLogout(context),
          ),
        ],
      ),
      // IndexedStack keeps every tab's state alive across switches, so a
      // partially-loaded Available feed or an in-flight OTP dialog survives
      // a trip to Earnings and back.
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          RiderAvailableTab(),
          RiderActiveTab(),
          RiderEarningsTab(),
          RiderAccountTab(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: _goToTab,
        // Fixed keeps all 4 labels visible regardless of the active tab.
        type: BottomNavigationBarType.fixed,
        selectedItemColor: kRiderGreen,
        unselectedItemColor: Colors.grey.shade600,
        backgroundColor: Colors.white,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.list_alt),
            label: 'Available',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.local_shipping),
            label: 'Active Trips',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet),
            label: 'Earnings',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Account',
          ),
        ],
      ),
    );
  }
}