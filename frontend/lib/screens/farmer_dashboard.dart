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

const double _kFallbackPickupLat = 13.1362;
const double _kFallbackPickupLng = 78.1291;

const List<String> _kDistricts = [
  'Bagalkot', 'Ballari', 'Belagavi', 'Bengaluru Rural', 'Bengaluru Urban',
  'Bidar', 'Chamarajanagar', 'Chikkaballapura', 'Chikkamagaluru',
  'Chitradurga', 'Dakshina Kannada', 'Davanagere', 'Dharwad', 'Gadag',
  'Hassan', 'Haveri', 'Kalaburagi', 'Kodagu', 'Kolar', 'Koppal', 'Mandya',
  'Mysuru', 'Raichur', 'Ramanagara', 'Shivamogga', 'Tumakuru', 'Udupi',
  'Uttara Kannada', 'Vijayapura', 'Yadgir', 'Vijayanagara',
];

const Color _kFarmerGreen = Color(0xFF2E7D32);

enum PickupMode { gps, saved, manual }

class FarmerDashboard extends StatefulWidget {
  const FarmerDashboard({super.key});

  @override
  State<FarmerDashboard> createState() => _FarmerDashboardState();
}

class _FarmerDashboardState extends State<FarmerDashboard> {
  int _currentIndex = 0;

  static const List<String> _titles = [
    'KisanRider', 'My Orders', 'Earnings', 'Account',
  ];

  void _goToTab(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  void _handleHomeTabSwitch(int requestedIndex) {
    switch (requestedIndex) {
      case 1:
        _openBookTransport();
        break;
      case 2:
        _goToTab(1);
        break;
    }
  }

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
// Book Transport form — supports BOTH create and edit modes.
// ---------------------------------------------------------------------------

class FarmerBookTransportTab extends StatefulWidget {
  const FarmerBookTransportTab({
    super.key,
    this.editOrderId,
    this.initialCropType,
    this.initialWeightKg,
    this.initialDropoffDistrict,
    this.initialDropoffMandiName,
    this.initialDropoffStallNumber,
    this.initialPickupAddress,
    this.initialPickupLandmark,
  });

  final String? editOrderId;
  final String? initialCropType;
  final double? initialWeightKg;
  final String? initialDropoffDistrict;
  final String? initialDropoffMandiName;
  final String? initialDropoffStallNumber;
  final String? initialPickupAddress;
  final String? initialPickupLandmark;

  bool get isEditing => editOrderId != null;

  @override
  State<FarmerBookTransportTab> createState() => _FarmerBookTransportTabState();
}

class _FarmerBookTransportTabState extends State<FarmerBookTransportTab> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController _cropController = TextEditingController();
  final TextEditingController _weightKgController = TextEditingController();
  final TextEditingController _pickupLandmarkController = TextEditingController();
  final TextEditingController _manualAddressController = TextEditingController();
  final TextEditingController _shopController = TextEditingController();

  PickupMode _pickupMode = PickupMode.gps;
  bool _saveAddressForFuture = false;

  bool _isFetchingLocation = false;
  String? _gpsAddress;
  double? _gpsLat;
  double? _gpsLng;
  String? _gpsError;

  List<Map<String, dynamic>> _savedAddresses = [];
  bool _isLoadingAddresses = false;
  String? _savedAddressesError;
  int? _selectedSavedIndex;

  String? _selectedDistrict;
  List<Map<String, dynamic>> _mandis = [];
  int? _selectedMandiIndex;
  bool _isLoadingMandis = false;
  String? _mandiError;

  bool _isSubmitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();

    if (widget.isEditing) {
      _cropController.text = widget.initialCropType ?? '';
      _weightKgController.text = widget.initialWeightKg != null
          ? widget.initialWeightKg!.toStringAsFixed(0)
          : '';
      _pickupLandmarkController.text = widget.initialPickupLandmark ?? '';
      _shopController.text = widget.initialDropoffStallNumber ?? '';
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.isEditing) {
        await _initializeEditMode();
      } else {
        _loadSavedAddresses();
        _fetchCurrentLocation();
        await _preselectProfileDistrict();
      }
    });
  }

  Future<void> _initializeEditMode() async {
    final district = widget.initialDropoffDistrict;
    if (district == null ||
        district.trim().isEmpty ||
        !_kDistricts.contains(district)) {
      return;
    }
    if (!mounted) return;
    setState(() => _selectedDistrict = district);
    await _onDistrictChanged(district);

    final mandiName = widget.initialDropoffMandiName?.trim();
    if (mandiName == null || mandiName.isEmpty) return;
    final idx = _mandis.indexWhere(
      (m) =>
          (m['name'] ?? '').toString().trim().toLowerCase() ==
          mandiName.toLowerCase(),
    );
    if (idx != -1 && mounted) {
      setState(() => _selectedMandiIndex = idx);
    }
  }

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

  Map<String, String> _headers(AuthProvider auth, {bool json = false}) {
    final h = <String, String>{
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  Future<void> _fetchCurrentLocation() async {
    setState(() {
      _isFetchingLocation = true;
      _gpsError = null;
    });

    try {
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

      final Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      );

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
      } catch (_) {}

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

  ({String address, String landmark, double lat, double lng})? _resolvePickup() {
    switch (_pickupMode) {
      case PickupMode.gps:
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
          setState(() =>
              _submitError = 'Please enter the village or area name.');
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

    if (widget.isEditing) {
      await _submitEdit();
    } else {
      await _submitCreate();
    }
  }

  Future<void> _submitCreate() async {
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
    final weightKg = double.parse(_weightKgController.text.trim());
    final saveForFuture =
        _pickupMode != PickupMode.saved && _saveAddressForFuture;

    setState(() => _isSubmitting = true);

    try {
      final response = await http.post(
        Uri.parse('$_kApiBaseUrl/produce-requests/'),
        headers: _headers(auth, json: true),
        body: jsonEncode({
          'crop_type': _cropController.text.trim(),
          'weight_kg': weightKg,
          'latitude': pickup.lat,
          'longitude': pickup.lng,
          'pickup_address': pickup.address,
          'pickup_landmark': pickup.landmark,
          'save_address_for_future': saveForFuture,
          'dropoff_district': _selectedDistrict,
          'dropoff_mandi_id': mandiId.isEmpty ? null : mandiId,
          'dropoff_mandi_name': mandiName,
          'dropoff_stall_number': shop.isEmpty ? null : shop,
          'dropoff_location': dropoff,
        }),
      );

      if (!mounted) return;

      if (response.statusCode == 201) {
        _cropController.clear();
        _weightKgController.clear();
        _shopController.clear();
        setState(() {
          _selectedDistrict = null;
          _mandis = [];
          _selectedMandiIndex = null;
          _isSubmitting = false;
        });

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

  Future<void> _submitEdit() async {
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
    final shop = _shopController.text.trim();
    final weightKg = double.parse(_weightKgController.text.trim());

    setState(() => _isSubmitting = true);

    try {
      final response = await http.put(
        Uri.parse('$_kApiBaseUrl/farmer/orders/${widget.editOrderId}'),
        headers: _headers(auth, json: true),
        body: jsonEncode({
          'crop_name': _cropController.text.trim(),
          'weight_kg': weightKg,
          'dropoff_district': _selectedDistrict,
          'dropoff_mandi': mandiName,
          'dropoff_stall_number': shop.isEmpty ? null : shop,
          'pickup_notes': _pickupLandmarkController.text.trim(),
        }),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        Navigator.of(context).pop(true);
        return;
      }

      setState(() {
        _isSubmitting = false;
        _submitError = _extractError(response) ??
            'Could not update request (HTTP ${response.statusCode}).';
      });
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final mandiDropdownEnabled = !_isSubmitting &&
        !_isLoadingMandis &&
        _selectedDistrict != null &&
        _mandis.isNotEmpty;

    final submitLabel =
        widget.isEditing ? 'Update Request' : 'Submit Request';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.isEditing
                    ? 'Edit Produce Request'
                    : 'New Produce Request',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                widget.isEditing
                    ? 'Update the details below. Only PENDING orders '
                        'can be edited.'
                    : 'Tell us what you\'re sending and where it needs to go.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),

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

              widget.isEditing
                  ? _buildEditPickupSection(theme)
                  : _buildPickupSection(theme),
              const SizedBox(height: 24),

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
                    : Text(submitLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEditPickupSection(ThemeData theme) {
    final address = (widget.initialPickupAddress ?? '').trim();
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
                'Pickup',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _kFarmerGreen,
                ),
              ),
            ],
          ),
          if (address.isNotEmpty) ...[
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
                        size: 16, color: Colors.black54),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      address,
                      style: theme.textTheme.bodySmall,
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
              labelText: 'Pickup Notes',
              hintText: 'e.g. Behind the canal, near the yellow gate',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.signpost_outlined),
              isDense: true,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Pickup location is fixed — contact support to change it.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

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
          _buildPickupToggle(theme),
          const SizedBox(height: 16),
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

void unawaited(Future<void> future) {
  future.catchError((_) {});
}