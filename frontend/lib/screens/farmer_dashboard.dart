import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';

/// Base URL of the FastAPI backend.
///
/// NOTE: `127.0.0.1` only works from Flutter Desktop / Chrome on the same
/// machine. On an Android emulator the host is reachable at `10.0.2.2`, and
/// on a physical device you need your machine's LAN IP (e.g. 192.168.x.x).
/// Change this one constant when you switch targets.
const String _kApiBaseUrl = 'http://127.0.0.1:8000';

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
  int _currentIndex = 0;

  static const List<String> _titles = [
    'KisanRider',
    'Book Transport',
    'My Orders',
    'Account',
  ];

  void _goToTab(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_currentIndex]),
        backgroundColor: _kFarmerGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () => authProvider.logout(),
          ),
        ],
      ),
      // IndexedStack keeps each tab's state alive across switches, so a
      // half-filled Book Transport form survives a trip to Home and back.
      body: IndexedStack(
        index: _currentIndex,
        children: [
          FarmerHomeTab(onBookTransport: () => _goToTab(1)),
          const FarmerBookTransportTab(),
          const FarmerOrdersTab(),
          const FarmerAccountTab(),
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
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.add_circle_outline),
            label: 'Book Transport',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.local_shipping),
            label: 'My Orders',
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

// ---------------------------------------------------------------------------
// Tab 0 — Home
// ---------------------------------------------------------------------------

class FarmerHomeTab extends StatelessWidget {
  const FarmerHomeTab({super.key, required this.onBookTransport});

  /// Switches the parent to the Book Transport tab. Passed down because a
  /// child widget can't change the parent's _currentIndex directly.
  final VoidCallback onBookTransport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authProvider = Provider.of<AuthProvider>(context);

    // The API doesn't expose a "get my profile" endpoint yet, so we fall
    // back to a generic greeting rather than showing a blank name.
    final greeting = 'Welcome back';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: _kFarmerGreen.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.agriculture_rounded,
                size: 72,
                color: _kFarmerGreen,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              greeting,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Need to move your produce to the mandi? '
              'Book a rider in a few taps.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: onBookTransport,
              style: FilledButton.styleFrom(
                backgroundColor: _kFarmerGreen,
                padding: const EdgeInsets.symmetric(vertical: 18),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Book Transport'),
            ),
            const SizedBox(height: 40),
            // Small section explaining what the app does, so a brand-new
            // farmer isn't dropped into a blank screen with one button.
            Text(
              'How it works',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const _HowItWorksStep(
              number: '1',
              title: 'Post your pickup',
              body: 'Tell us the crop, crate count, and your district.',
            ),
            const _HowItWorksStep(
              number: '2',
              title: 'Pick a mandi',
              body: 'Choose the APMC yard you want the produce delivered to.',
            ),
            const _HowItWorksStep(
              number: '3',
              title: 'Rider picks up',
              body: 'A nearby rider accepts and delivers to the mandi.',
            ),
            const SizedBox(height: 8),
            Text(
              'Signed in as ${authProvider.role ?? "FARMER"}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HowItWorksStep extends StatelessWidget {
  const _HowItWorksStep({
    required this.number,
    required this.title,
    required this.body,
  });

  final String number;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: _kFarmerGreen,
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 1 — Book Transport (district -> mandi form)
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

// ---------------------------------------------------------------------------
// Tab 2 — My Orders (placeholder)
// ---------------------------------------------------------------------------

class FarmerOrdersTab extends StatelessWidget {
  const FarmerOrdersTab({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: _kFarmerGreen.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.local_shipping,
                  size: 64,
                  color: _kFarmerGreen,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'My Orders & Shipments',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Coming Soon',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 3 — Account (placeholder)
// ---------------------------------------------------------------------------

class FarmerAccountTab extends StatelessWidget {
  const FarmerAccountTab({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: _kFarmerGreen.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.person,
                  size: 64,
                  color: _kFarmerGreen,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Farmer Profile & Mandi Rates',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Coming Soon',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}