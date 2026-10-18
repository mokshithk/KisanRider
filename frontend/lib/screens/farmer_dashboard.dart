import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
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

/// Fallback coordinates if the farmer picks a mode but the client can't
/// resolve a real position — Kolar-area mock used by the previous MVP so
/// a booking still succeeds if GPS is denied or a saved address has no
/// coordinates. The backend requires lat/lng, so we always have *some*
/// value to send.
const double _kFallbackPickupLat = 13.1362;
const double _kFallbackPickupLng = 78.1291;

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

/// The three pickup-source modes the farmer can pick from. The enum
/// keeps the toggle's index arithmetic readable — the UI iterates over
/// `PickupMode.values` and renders one segment per entry.
enum PickupMode { gps, saved, manual }

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

  // ----- Produce details --------------------------------------------------
  final TextEditingController _cropController = TextEditingController();

  /// Weight in kilograms. This is the sole quantity metric on the booking
  /// (the previous crate-count field was replaced by this field as part of
  /// the Book Transport refactor — the payload now sends `weight_kg` as a
  /// double).
  final TextEditingController _weightKgController = TextEditingController();

  // ----- Pickup (3-way selector) ------------------------------------------
  PickupMode _pickupMode = PickupMode.gps;

  /// Landmark field, shared by the GPS and Manual modes. Saved mode fills
  /// it from the chip the farmer taps. Always sent to the backend.
  final TextEditingController _pickupLandmarkController =
      TextEditingController();

  /// Manual mode's address field. Ignored (and hidden) in GPS mode.
  final TextEditingController _manualAddressController = TextEditingController();

  /// Manual mode's "save for next time" checkbox.
  bool _saveAddressForFuture = false;

  /// GPS state.
  bool _isFetchingLocation = false;
  String? _gpsAddress;
  double? _gpsLat;
  double? _gpsLng;
  String? _gpsError;

  /// Saved-addresses state.
  List<Map<String, dynamic>> _savedAddresses = [];
  bool _isLoadingAddresses = false;
  String? _savedAddressesError;

  /// Index into `_savedAddresses` for the currently-picked chip, or null
  /// when the farmer hasn't picked one yet.
  int? _selectedSavedIndex;

  // ----- Dropoff ----------------------------------------------------------
  final TextEditingController _shopController = TextEditingController();

  /// Selected dropoff district. Pre-selected from the farmer's registered
  /// district (via AuthProvider) on first frame when it matches one of the
  /// 31 supported Karnataka districts — the dropdown stays fully editable
  /// afterwards, so the farmer can switch to any other district.
  String? _selectedDistrict;

  /// Markets returned by GET /mandi/markets — the merged list of official
  /// APMC yards (type == 'APMC_YARD') and web-searched local markets
  /// (type == 'LOCAL_MARKET'). Each entry is `{id, name, type, district,
  /// address, lat, lng}`.
  List<Map<String, dynamic>> _mandis = [];
  int? _selectedMandiIndex;
  bool _isLoadingMandis = false;
  String? _mandiError;

  bool _isSubmitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    // Provider/context is only safe after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _loadSavedAddresses();
      // GPS fetch is opportunistic: if the farmer leaves it alone, we
      // fall back to the mock coordinates on submit.
      _fetchCurrentLocation();
      await _preselectProfileDistrict();
    });
  }

  /// Pre-selects the farmer's registered district (from AuthProvider) if
  /// it matches one of the 31 supported Karnataka districts, and kicks off
  /// the market lookup for it. The dropdown remains editable — this only
  /// saves the farmer a tap on the common case.
  Future<void> _preselectProfileDistrict() async {
    final auth = context.read<AuthProvider>();
    final profileDistrict = (auth.district ?? '').trim();
    if (profileDistrict.isEmpty || !_kDistricts.contains(profileDistrict)) {
      return;
    }
    if (!mounted) return;
    setState(() => _selectedDistrict = profileDistrict);
    await _onDistrictChanged(profileDistrict);
  }

  @override
  void dispose() {
    _cropController.dispose();
    _weightKgController.dispose();
    _pickupLandmarkController.dispose();
    _manualAddressController.dispose();
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
  // GPS mode
  // -------------------------------------------------------------------------

  /// Asks the platform for the current position, then reverse-geocodes
  /// the coordinates into a readable address. Every failure path is
  /// rendered as a status line under the toggle — the farmer can still
  /// fall back to Manual or Saved without losing the form.
  Future<void> _fetchCurrentLocation() async {
    setState(() {
      _isFetchingLocation = true;
      _gpsError = null;
    });

    try {
      // 1. Permission. If the user hasn't decided yet, request it now;
      //    if they've denied it permanently, we can only point them at
      //    the settings screen, which we surface as an error.
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() {
          _isFetchingLocation = false;
          _gpsError = 'Location permission denied. Switch to Manual Entry '
              'or Saved Places.';
        });
        return;
      }

      // 2. Fix. `getCurrentPosition` with a medium accuracy hint is fast
      //    enough for a farm address and precise enough for the 50 km
      //    rider search radius.
      final Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );

      // 3. Reverse geocode. Failures here are non-fatal — we still have
      //    usable coordinates, we just can't pretty-print them.
      String? readable;
      try {
        final placemarks = await placemarkFromCoordinates(
          pos.latitude,
          pos.longitude,
        );
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          final parts = <String>[
            if ((p.name ?? '').isNotEmpty) p.name!,
            if ((p.subLocality ?? '').isNotEmpty) p.subLocality!,
            if ((p.locality ?? '').isNotEmpty) p.locality!,
            if ((p.subAdministrativeArea ?? '').isNotEmpty)
              p.subAdministrativeArea!,
            if ((p.administrativeArea ?? '').isNotEmpty) p.administrativeArea!,
          ];
          readable = parts.join(', ');
        }
      } catch (_) {
        // Swallow — coordinates are still valid.
      }

      if (!mounted) return;
      setState(() {
        _isFetchingLocation = false;
        _gpsLat = pos.latitude;
        _gpsLng = pos.longitude;
        _gpsAddress = (readable == null || readable.isEmpty)
            ? '${pos.latitude.toStringAsFixed(4)}, '
                '${pos.longitude.toStringAsFixed(4)}'
            : readable;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isFetchingLocation = false;
        _gpsError = 'Could not fetch location: $e';
      });
    }
  }

  // -------------------------------------------------------------------------
  // Saved addresses
  // -------------------------------------------------------------------------

  Future<void> _loadSavedAddresses() async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;

    setState(() {
      _isLoadingAddresses = true;
      _savedAddressesError = null;
    });

    try {
      final response = await http.get(
        Uri.parse('$_kApiBaseUrl/farmer/addresses'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> decoded =
            jsonDecode(response.body) as List<dynamic>;
        setState(() {
          _savedAddresses = decoded
              .whereType<Map<String, dynamic>>()
              .toList(growable: false);
          _isLoadingAddresses = false;
        });
      } else {
        setState(() {
          _savedAddressesError = _extractError(response) ??
              'Failed to load saved addresses '
              '(HTTP ${response.statusCode}).';
          _isLoadingAddresses = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savedAddressesError = 'Network error: $e';
        _isLoadingAddresses = false;
      });
    }
  }

  void _selectSavedAddress(int index) {
    final a = _savedAddresses[index];
    setState(() {
      _selectedSavedIndex = index;
      _pickupLandmarkController.text = (a['landmark'] ?? '').toString();
    });
  }

  // -------------------------------------------------------------------------
  // Mandi lookup
  // -------------------------------------------------------------------------

  /// Fires when the user picks a district. Clears any prior mandi selection,
  /// hits the dual-source `/mandi/markets` endpoint, and populates the
  /// dropdown with the merged APMC + local market list.
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
      final uri = Uri.parse('$_kApiBaseUrl/mandi/markets')
          .replace(queryParameters: {'district': district});

      final response = await http.get(
        uri,
        headers: const {'Accept': 'application/json'},
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        // New response shape: `{district, markets: [...]}`. Each entry
        // carries `{id, name, type, district, address, lat, lng}` where
        // `type` is either 'APMC_YARD' or 'LOCAL_MARKET'.
        final list = (data['markets'] as List<dynamic>?) ?? const [];

        setState(() {
          _mandis = list
              .whereType<Map<String, dynamic>>()
              .toList(growable: false);
          _selectedMandiIndex = null;
          _isLoadingMandis = false;

          if (_mandis.isEmpty) {
            _mandiError = 'No markets found for "$district".';
          }
        });
      } else {
        setState(() {
          _mandiError = 'Could not load markets (HTTP ${response.statusCode}).';
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

  /// Resolve the pickup (address, landmark, lat, lng) that will be sent
  /// to the backend, based on which mode is active.
  ///
  /// Returns null on a validation failure — the caller has already set
  /// `_submitError` by then, so it just needs to bail out.
  ({String address, String landmark, double lat, double lng})? _resolvePickup() {
    switch (_pickupMode) {
      case PickupMode.gps:
        // GPS is optional in practice — if the fix failed we still send
        // the fallback coordinates with an empty address, and the
        // backend stores a valid booking.
        return (
          address: _gpsAddress ?? '',
          landmark: _pickupLandmarkController.text.trim(),
          lat: _gpsLat ?? _kFallbackPickupLat,
          lng: _gpsLng ?? _kFallbackPickupLng,
        );

      case PickupMode.saved:
        if (_selectedSavedIndex == null) {
          setState(() => _submitError =
              'Please pick one of your saved places, or switch to another '
              'pickup option.');
          return null;
        }
        final a = _savedAddresses[_selectedSavedIndex!];
        return (
          address: (a['address_text'] ?? '').toString(),
          landmark: _pickupLandmarkController.text.trim(),
          lat: (a['latitude'] as num?)?.toDouble() ?? _kFallbackPickupLat,
          lng: (a['longitude'] as num?)?.toDouble() ?? _kFallbackPickupLng,
        );

      case PickupMode.manual:
        final address = _manualAddressController.text.trim();
        if (address.isEmpty) {
          setState(() => _submitError =
              'Please enter the village or area name.');
          return null;
        }
        return (
          address: address,
          landmark: _pickupLandmarkController.text.trim(),
          lat: _kFallbackPickupLat,
          lng: _kFallbackPickupLng,
        );
    }
  }

  Future<void> _submit() async {
    setState(() => _submitError = null);
    if (!_formKey.currentState!.validate()) return;

    // Pickup resolution happens before the "select a mandi" check because
    // it's a smaller, more targeted error to surface first.
    final pickup = _resolvePickup();
    if (pickup == null) return;

    if (_selectedMandiIndex == null) {
      setState(() => _submitError = 'Please select a dropoff market.');
      return;
    }

    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      setState(() => _submitError = 'Not signed in.');
      return;
    }

    final mandi = _mandis[_selectedMandiIndex!];
    final mandiName = (mandi['name'] ?? '').toString();
    final mandiId = (mandi['id'] ?? '').toString();
    final shop = _shopController.text.trim();
    final dropoff = shop.isEmpty ? mandiName : '$mandiName - $shop';

    // Weight is the sole quantity metric — parse the single input value
    // once and reuse it for both the payload and (implicitly) the fare
    // calculation that runs on the backend.
    final weightKg = double.parse(_weightKgController.text.trim());

    // The auto-save flag is only meaningful for Manual and GPS — saved
    // mode is already booked. We still send `true` for those so the
    // backend can decide.
    final saveForFuture =
        _pickupMode != PickupMode.saved && _saveAddressForFuture;

    setState(() {
      _isSubmitting = true;
    });

    try {
      final response = await http.post(
        Uri.parse('$_kApiBaseUrl/produce-requests/'),
        headers: _headers(auth, json: true),
        body: jsonEncode({
          'crop_type': _cropController.text.trim(),
          // Sole quantity metric — sent as a float/double.
          'weight_kg': weightKg,
          'latitude': pickup.lat,
          'longitude': pickup.lng,
          'pickup_address': pickup.address,
          'pickup_landmark': pickup.landmark,
          'save_address_for_future': saveForFuture,
          // Structured dropoff fields — the backend writes these to
          // first-class columns. `dropoff_location` is still sent as a
          // legacy composite so older display code keeps working.
          'dropoff_district': _selectedDistrict,
          'dropoff_mandi_id': mandiId.isEmpty ? null : mandiId,
          'dropoff_mandi_name': mandiName,
          'dropoff_stall_number': shop.isEmpty ? null : shop,
          'dropoff_location': dropoff,
        }),
      );

      if (!mounted) return;

      if (response.statusCode == 201) {
        // Reset produce + dropoff state; keep the pickup selection alive
        // since a farmer booking a second load from the same barn almost
        // always uses the same pickup.
        _cropController.clear();
        _weightKgController.clear();
        _shopController.clear();
        setState(() {
          _selectedDistrict = null;
          _mandis = [];
          _selectedMandiIndex = null;
          _isSubmitting = false;
        });

        // A freshly-saved address should show up in the chip row.
        if (saveForFuture) {
          unawaited(_loadSavedAddresses());
        }

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

              // ============================================================
              // PRODUCE DETAILS
              // ============================================================

              // ----- Crop name --------------------------------------------
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

              // ----- Weight (in KG) ---------------------------------------
              // Replaces the previous "Crate Count" field. The fare is
              // calculated from this weight on the backend, so it's the
              // sole quantity metric on the payload.
              TextFormField(
                controller: _weightKgController,
                enabled: !_isSubmitting,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Weight / Quantity (in KG)',
                  hintText: 'e.g., 250',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.scale_outlined),
                  suffixText: 'kg',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Weight is required';
                  }
                  final parsed = double.tryParse(value.trim());
                  if (parsed == null || parsed <= 0) {
                    return 'Enter a valid positive weight';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 24),

              // ============================================================
              // PICKUP LOCATION
              // ============================================================
              _buildPickupSection(theme),
              const SizedBox(height: 24),

              // ============================================================
              // DROPOFF / MANDI
              // ============================================================

              // ----- District dropdown ------------------------------------
              // Pre-selected from the farmer's profile on first frame when
              // the profile district is one of the 31 supported districts.
              // The dropdown stays fully editable.
              DropdownButtonFormField<String>(
                value: _selectedDistrict,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Dropoff District',
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

              // ----- Market / APMC dropdown -------------------------------
              // Backed by /mandi/markets, which merges official APMC yards
              // (type == 'APMC_YARD') with locally-searched markets
              // (type == 'LOCAL_MARKET'). Each row shows a small badge so
              // the farmer can tell which one they're picking.
              DropdownButtonFormField<int>(
                value: _selectedMandiIndex,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Dropoff Market / APMC Yard',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.storefront_outlined),
                  hintText: _selectedDistrict == null
                      ? 'Select a district first'
                      : (_isLoadingMandis
                          ? 'Loading markets…'
                          : 'Select a market'),
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
                  (i) {
                    final m = _mandis[i];
                    final name = (m['name'] ?? '').toString();
                    final type = (m['type'] ?? '').toString();
                    final isApmc = type == 'APMC_YARD';
                    return DropdownMenuItem<int>(
                      value: i,
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: isApmc
                                  ? Colors.blue.shade50
                                  : Colors.orange.shade50,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: isApmc
                                    ? Colors.blue.shade200
                                    : Colors.orange.shade200,
                              ),
                            ),
                            child: Text(
                              isApmc ? 'APMC' : 'Local',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: isApmc
                                    ? Colors.blue.shade800
                                    : Colors.orange.shade800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                onChanged: mandiDropdownEnabled
                    ? (i) => setState(() => _selectedMandiIndex = i)
                    : null,
                validator: (v) => v == null ? 'Select a market' : null,
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

              // ----- Shop / stall (optional) ------------------------------
              TextFormField(
                controller: _shopController,
                enabled: !_isSubmitting,
                decoration: const InputDecoration(
                  labelText: 'Dropoff Shop / Stall Number (optional)',
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

  // -------------------------------------------------------------------------
  // Pickup section sub-widgets
  // -------------------------------------------------------------------------

  Widget _buildPickupSection(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kFarmerGreen.withOpacity(0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kFarmerGreen.withOpacity(0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.pin_drop_outlined,
                  color: _kFarmerGreen, size: 20),
              const SizedBox(width: 8),
              Text(
                'Pickup Location',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _kFarmerGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ----- Toggle ---------------------------------------------------
          _buildPickupToggle(theme),
          const SizedBox(height: 16),

          // ----- Body (mode-specific) ------------------------------------
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: _pickupMode == PickupMode.gps
                  ? _buildGpsBody(theme)
                  : _pickupMode == PickupMode.saved
                      ? _buildSavedBody(theme)
                      : _buildManualBody(theme),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPickupToggle(ThemeData theme) {
    return SegmentedButton<PickupMode>(
      segments: const [
        ButtonSegment<PickupMode>(
          value: PickupMode.gps,
          icon: Icon(Icons.my_location, size: 16),
          label: Text('Current GPS', style: TextStyle(fontSize: 12.5)),
        ),
        ButtonSegment<PickupMode>(
          value: PickupMode.saved,
          icon: Icon(Icons.bookmark_outline, size: 16),
          label: Text('Saved Places', style: TextStyle(fontSize: 12.5)),
        ),
        ButtonSegment<PickupMode>(
          value: PickupMode.manual,
          icon: Icon(Icons.edit_location_alt_outlined, size: 16),
          label: Text('Manual', style: TextStyle(fontSize: 12.5)),
        ),
      ],
      selected: {_pickupMode},
      onSelectionChanged: _isSubmitting
          ? null
          : (selection) {
              if (selection.isEmpty) return;
              setState(() {
                _pickupMode = selection.first;
                // Clear the submit error so a mode switch doesn't leave a
                // stale "please enter the village name" from a prior
                // attempt.
                _submitError = null;
              });
            },
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: _kFarmerGreen,
        selectedForegroundColor: Colors.white,
        foregroundColor: _kFarmerGreen,
        side: BorderSide(color: _kFarmerGreen.withOpacity(0.4)),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  // ----- GPS mode body ----------------------------------------------------

  Widget _buildGpsBody(ThemeData theme) {
    return KeyedSubtree(
      key: const ValueKey('pickup_gps'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Row(
              children: [
                _isFetchingLocation
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _gpsError != null
                            ? Icons.error_outline
                            : (_gpsAddress != null
                                ? Icons.check_circle_outline
                                : Icons.my_location),
                        color: _gpsError != null
                            ? theme.colorScheme.error
                            : _kFarmerGreen,
                        size: 20,
                      ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _isFetchingLocation
                        ? 'Detecting your location…'
                        : (_gpsError ??
                            (_gpsAddress ??
                                'Tap "Refresh" to detect your location.')),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (!_isFetchingLocation)
                  IconButton(
                    tooltip: 'Refresh location',
                    icon: const Icon(Icons.refresh, size: 20),
                    color: _kFarmerGreen,
                    onPressed: _isSubmitting
                        ? null
                        : () => _fetchCurrentLocation(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Landmark field, shared with Manual mode.
          TextFormField(
            controller: _pickupLandmarkController,
            enabled: !_isSubmitting,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Landmark / Pickup Notes',
              hintText: 'e.g. Behind the canal, near the yellow gate',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.signpost_outlined),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }

  // ----- Saved places body ------------------------------------------------

  Widget _buildSavedBody(ThemeData theme) {
    return KeyedSubtree(
      key: const ValueKey('pickup_saved'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isLoadingAddresses)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_savedAddressesError != null)
            Text(
              _savedAddressesError!,
              style: TextStyle(
                color: theme.colorScheme.error,
                fontSize: 12,
              ),
            )
          else if (_savedAddresses.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      color: Colors.grey.shade600, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'No saved places yet. Use Manual Entry and tick '
                      '"Save this location" to bookmark one for next time.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(_savedAddresses.length, (i) {
                final a = _savedAddresses[i];
                final title = (a['title'] ?? '').toString();
                final selected = _selectedSavedIndex == i;
                return ChoiceChip(
                  label: Text(
                    title.isEmpty ? 'Saved place' : title,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: selected ? Colors.white : _kFarmerGreen,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  avatar: Icon(
                    Icons.bookmark,
                    size: 16,
                    color: selected ? Colors.white : _kFarmerGreen,
                  ),
                  selected: selected,
                  onSelected: _isSubmitting
                      ? null
                      : (_) => _selectSavedAddress(i),
                  selectedColor: _kFarmerGreen,
                  backgroundColor: Colors.white,
                  side: BorderSide(
                    color: _kFarmerGreen.withOpacity(0.4),
                  ),
                );
              }),
            ),

          if (_selectedSavedIndex != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.location_on_outlined,
                        size: 18, color: Colors.black54),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      (_savedAddresses[_selectedSavedIndex!]['address_text'] ??
                              '')
                          .toString(),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextFormField(
            controller: _pickupLandmarkController,
            enabled: !_isSubmitting,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Landmark / Pickup Notes (optional)',
              hintText: 'e.g. Opposite the borewell',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.signpost_outlined),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }

  // ----- Manual entry body ------------------------------------------------

  Widget _buildManualBody(ThemeData theme) {
    return KeyedSubtree(
      key: const ValueKey('pickup_manual'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _manualAddressController,
            enabled: !_isSubmitting,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Village / Area Name',
              hintText: 'e.g. Bangarpet, Kolar',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.holiday_village_outlined),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _pickupLandmarkController,
            enabled: !_isSubmitting,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Landmark / Pickup Notes',
              hintText: 'e.g. Second gate on the left after the bridge',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.signpost_outlined),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          CheckboxListTile(
            value: _saveAddressForFuture,
            onChanged: _isSubmitting
                ? null
                : (v) => setState(
                      () => _saveAddressForFuture = v ?? false,
                    ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeColor: _kFarmerGreen,
            title: Text(
              'Save this location for future bookings',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small helper — `unawaited` is available from dart:async but importing it
// here pulls in a lot of surface area for one call. Define a tiny wrapper.
// ---------------------------------------------------------------------------

void unawaited(Future<void> future) {
  // Fire-and-forget: we don't care about the result.
  future.catchError((_) {});
}