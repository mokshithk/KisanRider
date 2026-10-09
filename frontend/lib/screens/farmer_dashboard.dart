import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;   // <-- ADDED
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'farmer_account_screen.dart';
import 'farmer_earnings_tab.dart';
import 'farmer_home_tab.dart';
import 'farmer_orders_tab.dart';

/// Base URL of the FastAPI backend.
String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

/// Rough weight estimate the backend needs but the form doesn't collect.
const double _kKgPerCrate = 25.0;

/// Mock pickup coordinates (Kolar-area) — the farmer's own field isn't
/// captured yet, so pickup stays hard-coded for MVP. Dropoff comes from the
/// mandi the farmer picks in the form.
const double _kMockPickupLat = 13.1362;
const double _kMockPickupLng = 78.1291;

/// Fixed list of districts for the dropdown. Extend as coverage grows.
const List<String> _kDistricts = [
  'Bagalkot',
  'Ballari',
  'Belagavi',
  'Bengaluru Rural',
  'Bengaluru Urban',
  'Bidar',
  'Chamarajanagar',
  'Chikkaballapura',
  'Chikkamagaluru',
  'Chitradurga',
  'Dakshina Kannada',
  'Davanagere',
  'Dharwad',
  'Gadag',
  'Hassan',
  'Haveri',
  'Kalaburagi',
  'Kodagu',
  'Kolar',
  'Koppal',
  'Mandya',
  'Mysuru',
  'Raichur',
  'Ramanagara',
  'Shivamogga',
  'Tumakuru',
  'Udupi',
  'Uttara Kannada',
  'Vijayapura',
  'Yadgir',
  'Vijayanagara',
];

/// Brand color used across the farmer-side UI.
const Color _kFarmerGreen = Color(0xFF2E7D32);

// ---------------------------------------------------------------------------
// Root dashboard with bottom navigation
// ---------------------------------------------------------------------------

class FarmerDashboard extends StatefulWidget {
  const FarmerDashboard({super.key});

  @override
  State<FarmerDashboard> createState() => _FarmerDashboardState();
}

class _FarmerDashboardState extends State<FarmerDashboard> {
  // Position within the IndexedStack. Maps 1:1 with the BottomNavigationBar
  // items below — 0 = Home, 1 = My Orders, 2 = Earnings, 3 = Account.
  // Book Transport is not a tab; it opens as a modal route (see
  // _openBookTransport).
  int _currentIndex = 0;

  static const List<String> _titles = [
    'KisanRider',
    'My Orders',
    'Earnings',
    'Account',
  ];

  void _goToTab(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  /// Called by FarmerHomeTab for its quick actions.
  ///
  /// The home tab still uses its original convention: 1 = "Book Transport",
  /// 2 = "My Orders". Since Book Transport is no longer a bottom-nav tab,
  /// we intercept that here and open it as a modal route, rather than
  /// renumbering the tabs (which would require editing farmer_home_tab.dart).
  void _handleHomeTabSwitch(int requestedIndex) {
    switch (requestedIndex) {
      case 1:
        _openBookTransport();
        break;
      case 2:
        // My Orders now lives at stack index 1 (was 2 in the old layout).
        _goToTab(1);
        break;
    }
  }

  /// Pushes the Book Transport form as a full-screen page with its own
  /// AppBar. Kept as a route rather than a bottom-nav tab so the nav bar
  /// stays focused on persistent sections (Home / My Orders / Earnings /
  /// Account).
  void _openBookTransport() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('Book Transport'),
            backgroundColor: _kFarmerGreen,
            foregroundColor: Colors.white,
          ),
          body: const FarmerBookTransportTab(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_currentIndex]),
        backgroundColor: _kFarmerGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () => showLogoutConfirmation(context),
          ),
        ],
      ),
      // IndexedStack keeps every tab's state alive across switches, so a
      // partially-loaded orders list or an in-progress fetch survives a
      // trip to Earnings and back.
      body: IndexedStack(
        index: _currentIndex,
        children: [
          FarmerHomeTab(onTabSwitch: _handleHomeTabSwitch),
          FarmerOrdersTab(onBookTransport: _openBookTransport),
          const FarmerEarningsTab(),
          const FarmerAccountScreen(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: _goToTab,
        // Fixed keeps all 4 labels visible regardless of the active tab.
        type: BottomNavigationBarType.fixed,
        selectedItemColor: _kFarmerGreen,
        unselectedItemColor: Colors.grey.shade600,
        backgroundColor: Colors.white,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.inventory_2_outlined),
            activeIcon: Icon(Icons.inventory_2),
            label: 'My Orders',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet_outlined),
            activeIcon: Icon(Icons.account_balance_wallet),
            label: 'Earnings',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person),
            label: 'Account',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Book Transport form
//
// Reached as a pushed route rather than a bottom-nav tab. Kept in this file
// since nothing else references it — move it into its own file if this one
// gets too large.
// ---------------------------------------------------------------------------

class FarmerBookTransportTab extends StatefulWidget {
  const FarmerBookTransportTab({super.key});

  @override
  State<FarmerBookTransportTab> createState() => _FarmerBookTransportTabState();
}

class _FarmerBookTransportTabState extends State<FarmerBookTransportTab> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController _cropController = TextEditingController();
  final TextEditingController _crateCountController = TextEditingController();
  final TextEditingController _shopController = TextEditingController();

  // District / mandi state.
  String? _selectedDistrict;
  List<Map<String, dynamic>> _mandis = [];
  int? _selectedMandiIndex;
  bool _isLoadingMandis = false;
  String? _mandiError;

  bool _isSubmitting = false;
  String? _submitError;

  @override
  void dispose() {
    _cropController.dispose();
    _crateCountController.dispose();
    _shopController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Auth helper
  // -------------------------------------------------------------------------

  Map<String, String> _headers(AuthProvider auth, {bool json = false}) {
    final h = <String, String>{
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  // -------------------------------------------------------------------------
  // Mandi lookup
  // -------------------------------------------------------------------------

  /// Fires when the user picks a district. Clears any prior mandi selection,
  /// hits the backend `/mandis/search` proxy, and populates the dropdown.
  Future<void> _onDistrictChanged(String? district) async {
    if (district == null) return;

    setState(() {
      _selectedDistrict = district;
      _mandis = [];
      _selectedMandiIndex = null;
      _mandiError = null;
      _isLoadingMandis = true;
    });

    try {
      final uri = Uri.parse('$_kApiBaseUrl/mandis/search')
          .replace(queryParameters: {'district': district});

      final response = await http.get(
        uri,
        headers: const {'Accept': 'application/json'},
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final list = (data['mandis'] as List<dynamic>?) ?? const [];

        setState(() {
          _mandis = list
              .whereType<Map<String, dynamic>>()
              .toList(growable: false);
          _selectedMandiIndex = null;
          _isLoadingMandis = false;

          if (_mandis.isEmpty) {
            _mandiError = 'No mandis found for "$district".';
          }
        });
      } else {
        setState(() {
          _mandiError = 'Could not load mandis (HTTP ${response.statusCode}).';
          _isLoadingMandis = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mandiError = 'Network error: $e';
        _isLoadingMandis = false;
      });
    }
  }

  // -------------------------------------------------------------------------
  // Submit
  // -------------------------------------------------------------------------

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedMandiIndex == null) return;

    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      setState(() => _submitError = 'Not signed in.');
      return;
    }

    final mandi = _mandis[_selectedMandiIndex!];
    final mandiName = (mandi['name'] ?? '').toString();
    final shop = _shopController.text.trim();
    final dropoff = shop.isEmpty ? mandiName : '$mandiName - $shop';

    setState(() {
      _isSubmitting = true;
      _submitError = null;
    });

    try {
      final response = await http.post(
        Uri.parse('$_kApiBaseUrl/produce-requests/'),
        headers: _headers(auth, json: true),
        body: jsonEncode({
          'crop_type': _cropController.text.trim(),
          'crate_count': int.parse(_crateCountController.text.trim()),
          'weight_kg':
              int.parse(_crateCountController.text.trim()) * _kKgPerCrate,
          'latitude': _kMockPickupLat,
          'longitude': _kMockPickupLng,
          'dropoff_location': dropoff,
        }),
      );

      if (!mounted) return;

      if (response.statusCode == 201) {
        // Reset the form for the next booking.
        _cropController.clear();
        _crateCountController.clear();
        _shopController.clear();
        setState(() {
          _selectedDistrict = null;
          _mandis = [];
          _selectedMandiIndex = null;
          _isSubmitting = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Request posted. A rider will pick it up soon.'),
            backgroundColor: _kFarmerGreen,
          ),
        );
      } else {
        setState(() {
          _isSubmitting = false;
          _submitError = _extractError(response) ??
              'Could not post request (HTTP ${response.statusCode}).';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _submitError = 'Network error: $e';
      });
    }
  }

  String? _extractError(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['detail'] != null) {
        return body['detail'].toString();
      }
    } catch (_) {}
    return null;
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final mandiDropdownEnabled = !_isSubmitting &&
        !_isLoadingMandis &&
        _selectedDistrict != null &&
        _mandis.isNotEmpty;

    return SafeArea(
      child: SingleChildScrollView(
        // The Scaffold handles keyboard inset automatically; just pad the
        // bottom so the last field isn't hidden behind the keyboard.
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'New Produce Request',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Tell us what you\'re sending and where it needs to go.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),

              // ----- Crop name ---------------------------------------------
              TextFormField(
                controller: _cropController,
                enabled: !_isSubmitting,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Crop Name',
                  hintText: 'e.g. Tomatoes',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.eco_outlined),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Crop name is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // ----- Crate count -------------------------------------------
              TextFormField(
                controller: _crateCountController,
                enabled: !_isSubmitting,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Crate Count',
                  hintText: 'e.g. 25',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.inventory_2_outlined),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Crate count is required';
                  }
                  final parsed = int.tryParse(value.trim());
                  if (parsed == null || parsed <= 0) {
                    return 'Enter a valid positive number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // ----- District dropdown -------------------------------------
              DropdownButtonFormField<String>(
                value: _selectedDistrict,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'District',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.map_outlined),
                ),
                items: _kDistricts
                    .map((d) => DropdownMenuItem<String>(
                          value: d,
                          child: Text(d, overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: _isSubmitting ? null : _onDistrictChanged,
                validator: (v) => v == null ? 'Select a district' : null,
              ),
              const SizedBox(height: 16),

              // ----- Mandi dropdown ----------------------------------------
              DropdownButtonFormField<int>(
                value: _selectedMandiIndex,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'APMC Mandi',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.storefront_outlined),
                  hintText: _selectedDistrict == null
                      ? 'Select a district first'
                      : (_isLoadingMandis
                          ? 'Loading mandis…'
                          : 'Select a mandi'),
                  suffixIcon: _isLoadingMandis
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                ),
                items: List<DropdownMenuItem<int>>.generate(
                  _mandis.length,
                  (i) => DropdownMenuItem<int>(
                    value: i,
                    child: Text(
                      (_mandis[i]['name'] ?? '').toString(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                onChanged: mandiDropdownEnabled
                    ? (i) => setState(() => _selectedMandiIndex = i)
                    : null,
                validator: (v) => v == null ? 'Select a mandi' : null,
              ),
              if (_mandiError != null) ...[
                const SizedBox(height: 6),
                Text(
                  _mandiError!,
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 16),

              // ----- Shop / stall (optional) -------------------------------
              TextFormField(
                controller: _shopController,
                enabled: !_isSubmitting,
                decoration: const InputDecoration(
                  labelText: 'Shop / Stall Number (optional)',
                  hintText: 'e.g. Shop #14, Sri Lakshmi Traders',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.store_outlined),
                ),
              ),

              if (_submitError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _submitError!,
                  style:
                      TextStyle(color: theme.colorScheme.error, fontSize: 13),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: _kFarmerGreen,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Submit Request'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}