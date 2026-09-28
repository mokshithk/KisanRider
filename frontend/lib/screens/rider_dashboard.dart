import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'rider_account_tab.dart';
import 'rider_active_tab.dart';
import 'rider_available_tab.dart';
import 'rider_common.dart';
import 'rider_earnings_tab.dart';

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
            onPressed: () => context.read<AuthProvider>().logout(),
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