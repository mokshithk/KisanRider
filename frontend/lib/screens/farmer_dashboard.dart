import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../widgets/segmented_filter_bar.dart';
import 'farmer_account_screen.dart';
import 'farmer_earnings_tab.dart';
import 'farmer_home_tab.dart';
import 'farmer_orders_tab.dart';

/// Base URL of the FastAPI backend.
String get _kApiBaseUrl => ApiService.baseUrl;

const List<String> _kDistricts = [
  'Bagalkot', 'Ballari', 'Belagavi', 'Bengaluru Rural', 'Bengaluru Urban',
  'Bidar', 'Chamarajanagar', 'Chikkaballapura', 'Chikkamagaluru',
  'Chitradurga', 'Dakshina Kannada', 'Davanagere', 'Dharwad', 'Gadag',
  'Hassan', 'Haveri', 'Kalaburagi', 'Kodagu', 'Kolar', 'Koppal', 'Mandya',
  'Mysuru', 'Raichur', 'Ramanagara', 'Shivamogga', 'Tumakuru', 'Udupi',
  'Uttara Kannada', 'Vijayapura', 'Yadgir', 'Vijayanagara',
];

const Map<String, (double, double)> _kDistrictCenters = {
  'Bagalkot': (16.1817, 75.6958),
  'Ballari': (15.1394, 76.9214),
  'Belagavi': (15.8497, 74.4977),
  'Bengaluru Rural': (13.1500, 77.4000),
  'Bengaluru Urban': (12.9716, 77.5946),
  'Bidar': (17.9104, 77.5199),
  'Chamarajanagar': (11.9261, 76.9437),
  'Chikkaballapura': (13.4355, 77.7315),
  'Chikkamagaluru': (13.3161, 75.7720),
  'Chitradurga': (14.2251, 76.3980),
  'Dakshina Kannada': (12.9141, 74.8560),
  'Davanagere': (14.4644, 75.9218),
  'Dharwad': (15.4589, 75.0078),
  'Gadag': (15.4166, 75.6167),
  'Hassan': (13.0071, 76.0962),
  'Haveri': (14.7935, 75.4040),
  'Kalaburagi': (17.3297, 76.8343),
  'Kodagu': (12.4244, 75.7382),
  'Kolar': (13.1362, 78.1291),
  'Koppal': (15.3510, 76.1550),
  'Mandya': (12.5223, 76.8954),
  'Mysuru': (12.2958, 76.6394),
  'Raichur': (16.2076, 77.3463),
  'Ramanagara': (12.7216, 77.2801),
  'Shivamogga': (13.9299, 75.5681),
  'Tumakuru': (13.3392, 77.1140),
  'Udupi': (13.3409, 74.7421),
  'Uttara Kannada': (14.8050, 74.6300),
  'Vijayapura': (16.8302, 75.7100),
  'Yadgir': (16.7700, 77.1400),
  'Vijayanagara': (15.2689, 76.3909),
};

const Color _kFarmerGreen = Color(0xFF2E7D32);

enum PickupMode { gps, saved, manual }

class FarmerDashboard extends StatefulWidget {
  const FarmerDashboard({super.key});

  @override
  State<FarmerDashboard> createState() => _FarmerDashboardState();
}

class _FarmerDashboardState extends State<FarmerDashboard> {
  int _currentIndex = 0;
  final GlobalKey<FarmerOrdersTabState> _ordersKey =
      GlobalKey<FarmerOrdersTabState>();
  final GlobalKey<FarmerEarningsTabState> _earningsKey =
      GlobalKey<FarmerEarningsTabState>();

  static const List<String> _titles = [
    'KisanRider', 'My Orders', 'Earnings', 'Account',
  ];

  void _goToTab(int index) {
    if (index == 2) {
      _earningsKey.currentState?.refresh();
    }
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  void _openOrdersFilter(String filterTag) {
    _ordersKey.currentState?.selectFilterTag(filterTag);
    _goToTab(1);
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
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: Text(ctx.tr('Book Transport')),
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
        title: Text(context.tr(_titles[_currentIndex])),
        backgroundColor: _kFarmerGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: context.tr('Logout'),
            icon: const Icon(Icons.logout),
            onPressed: () => showLogoutConfirmation(context),
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          FarmerHomeTab(
            onTabSwitch: _handleHomeTabSwitch,
            onOpenOrdersFilter: _openOrdersFilter,
          ),
          FarmerOrdersTab(
            key: _ordersKey,
            onBookTransport: _openBookTransport,
          ),
          FarmerEarningsTab(key: _earningsKey),
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
        items: [
          BottomNavigationBarItem(
            icon: const Icon(Icons.home_outlined),
            activeIcon: const Icon(Icons.home),
            label: context.tr('Home'),
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.inventory_2_outlined),
            activeIcon: const Icon(Icons.inventory_2),
            label: context.tr('My Orders'),
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.account_balance_wallet_outlined),
            activeIcon: const Icon(Icons.account_balance_wallet),
            label: context.tr('Earnings'),
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.person_outline),
            activeIcon: const Icon(Icons.person),
            label: context.tr('Account'),
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

  static final Map<String, List<Map<String, dynamic>>> _mandiCache = {};

  DateTime? _windowStartDate;
  TimeOfDay? _windowStartTime;
  DateTime? _windowEndDate;
  TimeOfDay? _windowEndTime;

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
    final now = DateTime.now();
    _windowStartDate = now;
    _windowStartTime = TimeOfDay.fromDateTime(now);

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
          _gpsError = AppStrings.tr(
            'Location permission denied. Switch to Manual Entry or Saved Places.',
          );
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
        _gpsError = AppStrings.tr(
          'Could not fetch location: {err}',
          args: {'err': '$e'},
        );
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
              AppStrings.tr(
                'Failed to load saved addresses (HTTP {code}).',
                args: {'code': '${response.statusCode}'},
              );
          _isLoadingAddresses = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savedAddressesError = AppStrings.tr(
          'Network error: {err}',
          args: {'err': '$e'},
        );
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
      _selectedMandiIndex = null;
      _mandiError = null;
    });

    if (_mandiCache.containsKey(district) && _mandiCache[district]!.isNotEmpty) {
      setState(() {
        _mandis = _mandiCache[district]!;
        _isLoadingMandis = false;
      });
      return;
    }

    setState(() {
      _mandis = [];
      _isLoadingMandis = true;
    });

    try {
      final uri = Uri.parse('$_kApiBaseUrl/mandi/markets')
          .replace(queryParameters: {'district': district});

      final response = await http.get(
        uri,
        headers: const {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 25));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final list = (data['markets'] as List<dynamic>?) ?? const [];
        final parsed = list.whereType<Map<String, dynamic>>().toList(growable: false);

        _mandiCache[district] = parsed;

        setState(() {
          _mandis = parsed;
          _selectedMandiIndex = null;
          _isLoadingMandis = false;

          if (_mandis.isEmpty) {
            _mandiError = AppStrings.tr(
              'No markets found for "{district}".',
              args: {'district': AppStrings.tr(district)},
            );
          }
        });
      } else {
        setState(() {
          _mandiError = AppStrings.tr(
            'Could not load markets (HTTP {code}).',
            args: {'code': '${response.statusCode}'},
          );
          _isLoadingMandis = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mandiError = AppStrings.tr(
          'Network error: {err}',
          args: {'err': '$e'},
        );
        _isLoadingMandis = false;
      });
    }
  }

  void _showRedSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700),
    );
  }

  ({String address, String landmark, double lat, double lng})? _resolvePickup() {
    switch (_pickupMode) {
      case PickupMode.gps:
        if (_gpsLat == null || _gpsLng == null) {
          _showRedSnack(
            context.trAsync(
              'GPS location unavailable. Please tap Refresh or switch to Manual Entry / Saved Places.',
            ),
          );
          return null;
        }
        return (
          address: _gpsAddress ?? '',
          landmark: _pickupLandmarkController.text.trim(),
          lat: _gpsLat!,
          lng: _gpsLng!,
        );

      case PickupMode.saved:
        if (_selectedSavedIndex == null) {
          setState(
            () => _submitError = AppStrings.tr(
              'Please pick one of your saved places, or switch to another pickup option.',
            ),
          );
          return null;
        }
        final a = _savedAddresses[_selectedSavedIndex!];
        var lat = (a['latitude'] as num?)?.toDouble();
        var lng = (a['longitude'] as num?)?.toDouble();
        if (lat == null || lng == null) {
          final center = _selectedDistrict != null ? _kDistrictCenters[_selectedDistrict!] : null;
          lat = center?.$1 ?? 12.9716;
          lng = center?.$2 ?? 77.5946;
        }
        return (
          address: (a['address_text'] ?? '').toString(),
          landmark: _pickupLandmarkController.text.trim(),
          lat: lat,
          lng: lng,
        );

      case PickupMode.manual:
        final address = _manualAddressController.text.trim();
        if (address.isEmpty) {
          setState(
            () => _submitError = AppStrings.tr(
              'Please enter the village or area name.',
            ),
          );
          return null;
        }
        double lat;
        double lng;
        if (_gpsLat != null && _gpsLng != null) {
          lat = _gpsLat!;
          lng = _gpsLng!;
        } else {
          final center = _selectedDistrict != null ? _kDistrictCenters[_selectedDistrict!] : null;
          lat = center?.$1 ?? 12.9716;
          lng = center?.$2 ?? 77.5946;
        }
        return (
          address: address,
          landmark: _pickupLandmarkController.text.trim(),
          lat: lat,
          lng: lng,
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
    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      setState(() => _submitError = AppStrings.tr('Not signed in.'));
      return;
    }

    // --- Profile Completion Validation ---
    setState(() => _isSubmitting = true);
    Map<String, dynamic>? account;
    try {
      final accResp = await http.get(
        Uri.parse('$_kApiBaseUrl/farmer/account'),
        headers: _headers(auth),
      );
      if (accResp.statusCode == 200) {
        account = jsonDecode(accResp.body) as Map<String, dynamic>;
      }
    } catch (_) {}

    final farmSize = (account?['farm_size_acres'] as num?)?.toDouble() ?? 0.0;
    final primaryCrops = (account?['primary_crops'] ?? '').toString().trim();

    if (farmSize <= 0 || primaryCrops.isEmpty) {
      setState(() => _isSubmitting = false);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(ctx.tr('Farm Details Required')),
          content: Text(
            ctx.tr(
              'Before booking transport, please complete your Farm Details (Farm Size > 0 acres and Primary Crops).\n\nBank and UPI details are optional.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctx.tr('Cancel')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kFarmerGreen),
              onPressed: () async {
                Navigator.pop(ctx);
                await openFarmDetailsSheet(context, account);
              },
              child: Text(ctx.tr('Complete Farm Details')),
            ),
          ],
        ),
      );
      return;
    }

    final hasFarmAddress = (account?['farm_address'] ?? '').toString().trim().isNotEmpty;
    if (_savedAddresses.isEmpty && !hasFarmAddress) {
      await _loadSavedAddresses();
    }
    if (_savedAddresses.isEmpty && !hasFarmAddress) {
      setState(() => _isSubmitting = false);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(ctx.tr('Saved Address Required')),
          content: Text(
            ctx.tr(
              'Before booking transport, you need at least one Saved Farm Address so riders know where to pick up your produce.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctx.tr('Cancel')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kFarmerGreen),
              onPressed: () async {
                Navigator.pop(ctx);
                final res = await openFarmAddressSheet(context, account);
                if (res == true) {
                  await _loadSavedAddresses();
                }
              },
              child: Text(ctx.tr('Add Farm Address')),
            ),
          ],
        ),
      );
      return;
    }

    // --- Pickup Window Validation ---
    if (_windowStartDate == null || _windowStartTime == null) {
      setState(() {
        _isSubmitting = false;
        _submitError = AppStrings.tr(
          'Please select when the pickup window starts.',
        );
      });
      return;
    }
    if (_windowEndDate == null || _windowEndTime == null) {
      setState(() {
        _isSubmitting = false;
        _submitError = AppStrings.tr(
          'Please select when the pickup window ends.',
        );
      });
      return;
    }

    final winStart = DateTime(
      _windowStartDate!.year,
      _windowStartDate!.month,
      _windowStartDate!.day,
      _windowStartTime!.hour,
      _windowStartTime!.minute,
    );

    final winEnd = DateTime(
      _windowEndDate!.year,
      _windowEndDate!.month,
      _windowEndDate!.day,
      _windowEndTime!.hour,
      _windowEndTime!.minute,
    );

    if (winStart.isBefore(DateTime.now().subtract(const Duration(minutes: 5)))) {
      setState(() {
        _isSubmitting = false;
        _submitError = AppStrings.tr(
          'Pickup window start cannot be in the past.',
        );
      });
      return;
    }

    if (!winEnd.isAfter(winStart)) {
      setState(() {
        _isSubmitting = false;
        _submitError = AppStrings.tr(
          'Pickup window end must be later than the start time.',
        );
      });
      return;
    }

    final pickup = _resolvePickup();
    if (pickup == null) {
      setState(() => _isSubmitting = false);
      return;
    }

    if (_selectedMandiIndex == null) {
      setState(() {
        _isSubmitting = false;
        _submitError = AppStrings.tr('Please select a dropoff market.');
      });
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
          'requested_pickup_at': winStart.toUtc().toIso8601String(),
          'pickup_window_start': winStart.toUtc().toIso8601String(),
          'pickup_window_end': winEnd.toUtc().toIso8601String(),
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
          SnackBar(
            content: Text(
              context.trAsync('Request posted. A rider will pick it up soon.'),
            ),
            backgroundColor: _kFarmerGreen,
          ),
        );
      } else {
        setState(() {
          _isSubmitting = false;
          _submitError = _extractError(response) ??
              AppStrings.tr(
                'Could not post request (HTTP {code}).',
                args: {'code': '${response.statusCode}'},
              );
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _submitError = AppStrings.tr(
          'Network error: {err}',
          args: {'err': '$e'},
        );
      });
    }
  }

  Future<void> _submitEdit() async {
    if (_selectedMandiIndex == null) {
      setState(
        () => _submitError = AppStrings.tr('Please select a dropoff market.'),
      );
      return;
    }

    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      setState(() => _submitError = AppStrings.tr('Not signed in.'));
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
            AppStrings.tr(
              'Could not update request (HTTP {code}).',
              args: {'code': '${response.statusCode}'},
            );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _submitError = AppStrings.tr(
          'Network error: {err}',
          args: {'err': '$e'},
        );
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

  BoxDecoration _sectionCardDecoration() => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade300),
      );

  Widget _sectionHeader(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, color: _kFarmerGreen, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1C1B1F),
            ),
          ),
        ),
      ],
    );
  }

  InputDecoration _fieldDecoration({
    required String label,
    String? hint,
    required IconData icon,
    String? suffixText,
    Widget? suffixIcon,
    bool isDense = false,
  }) {
    final radius = BorderRadius.circular(12);
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: const Color(0xFFFAFAFA),
      isDense: isDense,
      prefixIcon: Icon(icon, color: _kFarmerGreen, size: 20),
      suffixText: suffixText,
      suffixIcon: suffixIcon,
      border: OutlineInputBorder(borderRadius: radius),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: _kFarmerGreen, width: 1.5),
      ),
    );
  }

  Widget _pickerButton({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(
        icon,
        size: 16,
        color: isSelected ? _kFarmerGreen : Colors.grey.shade600,
      ),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: isSelected ? const Color(0xFF1C1B1F) : Colors.grey.shade600,
        ),
      ),
      style: OutlinedButton.styleFrom(
        backgroundColor:
            isSelected ? const Color(0xFFF4FAF4) : const Color(0xFFFAFAFA),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(
          color: isSelected
              ? _kFarmerGreen.withValues(alpha: 0.65)
              : Colors.grey.shade300,
        ),
      ),
    );
  }

  Widget _buildPickupWindowCard(ThemeData theme) {
    final startDateStr = _windowStartDate == null
        ? context.tr('Select Date')
        : '${_windowStartDate!.day.toString().padLeft(2, '0')} '
            '${AppStrings.trShortMonth(_windowStartDate!.month)} '
            '${_windowStartDate!.year}';
    final startTimeStr = _windowStartTime == null
        ? context.tr('Select Time')
        : _windowStartTime!.format(context);

    final endDateStr = _windowEndDate == null
        ? context.tr('Select Date')
        : '${_windowEndDate!.day.toString().padLeft(2, '0')} '
            '${AppStrings.trShortMonth(_windowEndDate!.month)} '
            '${_windowEndDate!.year}';
    final endTimeStr = _windowEndTime == null
        ? context.tr('Select Time')
        : _windowEndTime!.format(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _sectionCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            Icons.access_time_filled,
            context.tr('Pickup Window *'),
          ),
          const SizedBox(height: 4),
          Text(
            context.tr(
              'Specify the time window when the rider can arrive for pickup.',
            ),
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 14),
          Text(
            context.tr('Pickup Window Starts'),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _pickerButton(
                  icon: Icons.calendar_today_outlined,
                  label: startDateStr,
                  isSelected: _windowStartDate != null,
                  onPressed: _isSubmitting
                      ? null
                      : () async {
                          final now = DateTime.now();
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _windowStartDate ?? now,
                            firstDate: now,
                            lastDate: now.add(const Duration(days: 30)),
                          );
                          if (picked != null) {
                            setState(() => _windowStartDate = picked);
                          }
                        },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _pickerButton(
                  icon: Icons.alarm_outlined,
                  label: startTimeStr,
                  isSelected: _windowStartTime != null,
                  onPressed: _isSubmitting
                      ? null
                      : () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: _windowStartTime ?? TimeOfDay.now(),
                          );
                          if (picked != null) {
                            setState(() => _windowStartTime = picked);
                          }
                        },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            context.tr('Pickup Window Ends'),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _pickerButton(
                  icon: Icons.calendar_today_outlined,
                  label: endDateStr,
                  isSelected: _windowEndDate != null,
                  onPressed: _isSubmitting
                      ? null
                      : () async {
                          final now = _windowStartDate ?? DateTime.now();
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _windowEndDate ?? now,
                            firstDate: now,
                            lastDate: now.add(const Duration(days: 30)),
                          );
                          if (picked != null) {
                            setState(() => _windowEndDate = picked);
                          }
                        },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _pickerButton(
                  icon: Icons.alarm_outlined,
                  label: endTimeStr,
                  isSelected: _windowEndTime != null,
                  onPressed: _isSubmitting
                      ? null
                      : () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: _windowEndTime ?? TimeOfDay.now(),
                          );
                          if (picked != null) {
                            setState(() => _windowEndTime = picked);
                          }
                        },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }



  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final mandiDropdownEnabled = !_isSubmitting &&
        !_isLoadingMandis &&
        _selectedDistrict != null &&
        _mandis.isNotEmpty;

    final submitLabel = context.tr(
      widget.isEditing ? 'Update Request' : 'Submit Request',
    );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr(
                  widget.isEditing
                      ? 'Edit Produce Request'
                      : 'New Produce Request',
                ),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF1C1B1F),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                context.tr(
                  widget.isEditing
                      ? 'Update the details below. Only PENDING orders can be edited.'
                      : 'Tell us what you\'re sending and where it needs to go.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),

              Container(
                padding: const EdgeInsets.all(16),
                decoration: _sectionCardDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _sectionHeader(
                      Icons.eco_outlined,
                      context.tr('Produce Details'),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _cropController,
                      enabled: !_isSubmitting,
                      textCapitalization: TextCapitalization.words,
                      decoration: _fieldDecoration(
                        label: context.tr('Crop Name'),
                        hint: context.tr('e.g. Tomatoes'),
                        icon: Icons.eco_outlined,
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return context.trAsync('Crop name is required');
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _weightKgController,
                      enabled: !_isSubmitting,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      decoration: _fieldDecoration(
                        label: context.tr('Weight / Quantity (in KG)'),
                        hint: context.tr('e.g., 250'),
                        icon: Icons.scale_outlined,
                        suffixText: context.tr('kg'),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return context.trAsync('Weight is required');
                        }
                        final parsed = double.tryParse(value.trim());
                        if (parsed == null || parsed <= 0) {
                          return context.trAsync('Enter a valid positive weight');
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              widget.isEditing
                  ? _buildEditPickupSection(theme)
                  : _buildPickupSection(theme),
              const SizedBox(height: 14),
              if (!widget.isEditing) ...[
                _buildPickupWindowCard(theme),
                const SizedBox(height: 14),
              ],

              Container(
                padding: const EdgeInsets.all(16),
                decoration: _sectionCardDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _sectionHeader(
                      Icons.storefront_outlined,
                      context.tr('Dropoff Destination'),
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      initialValue: _selectedDistrict,
                      isExpanded: true,
                      decoration: _fieldDecoration(
                        label: context.tr('Dropoff District'),
                        icon: Icons.map_outlined,
                      ),
                      items: _kDistricts
                          .map((d) => DropdownMenuItem<String>(
                                value: d,
                                child: Text(
                                  context.tr(d),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ))
                          .toList(),
                      onChanged: _isSubmitting ? null : _onDistrictChanged,
                      validator: (v) =>
                          v == null ? context.trAsync('Select a district') : null,
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<int>(
                      initialValue: _selectedMandiIndex,
                      isExpanded: true,
                      decoration: _fieldDecoration(
                        label: context.tr('Dropoff Market / APMC Yard'),
                        hint: _selectedDistrict == null
                            ? context.tr('Select a district first')
                            : (_isLoadingMandis
                                ? context.tr('Loading markets…')
                                : context.tr('Select a market')),
                        icon: Icons.storefront_outlined,
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
                                    isApmc
                                        ? context.tr('APMC')
                                        : context.tr('Local'),
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
                      validator: (v) =>
                          v == null ? context.trAsync('Select a market') : null,
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
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _shopController,
                      enabled: !_isSubmitting,
                      decoration: _fieldDecoration(
                        label: context.tr(
                          'Dropoff Shop / Stall Number (optional)',
                        ),
                        hint: context.tr('e.g. Shop #14, Sri Lakshmi Traders'),
                        icon: Icons.store_outlined,
                      ),
                    ),
                  ],
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
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: _kFarmerGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
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
                    : Text(
                        submitLabel,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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
      decoration: _sectionCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionHeader(Icons.pin_drop_outlined, context.tr('Pickup')),
          if (address.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFAFAFA),
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
            decoration: _fieldDecoration(
              label: context.tr('Pickup Notes'),
              hint: context.tr('e.g. Behind the canal, near the yellow gate'),
              icon: Icons.signpost_outlined,
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            context.tr('Pickup location is fixed — contact support to change it.'),
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
      decoration: _sectionCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionHeader(
            Icons.pin_drop_outlined,
            context.tr('Pickup Location'),
          ),
          const SizedBox(height: 12),
          _buildPickupToggle(theme),
          const SizedBox(height: 14),
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
    return SegmentedFilterBar<PickupMode>(
      padding: EdgeInsets.zero,
      options: [
        SegmentedFilterOption(
          value: PickupMode.gps,
          label: context.tr('Current GPS'),
        ),
        SegmentedFilterOption(
          value: PickupMode.saved,
          label: context.tr('Saved Places'),
        ),
        SegmentedFilterOption(
          value: PickupMode.manual,
          label: context.tr('Manual'),
        ),
      ],
      selectedValue: _pickupMode,
      onChanged: _isSubmitting
          ? null
          : (mode) {
              setState(() {
                _pickupMode = mode;
                _submitError = null;
              });
            },
      accentColor: _kFarmerGreen,
    );
  }

  Widget _buildGpsBody(ThemeData theme) {
    final hasGps = !_isFetchingLocation && _gpsError == null && _gpsAddress != null;
    return KeyedSubtree(
      key: const ValueKey('pickup_gps'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: hasGps
                  ? const Color(0xFFF4FAF4)
                  : const Color(0xFFFAFAFA),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hasGps
                    ? _kFarmerGreen.withValues(alpha: 0.35)
                    : Colors.grey.shade300,
              ),
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
                        ? context.tr('Detecting your location…')
                        : (_gpsError ??
                            (_gpsAddress ??
                                context.tr(
                                  'Tap "Refresh" to detect your location.',
                                ))),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF1C1B1F),
                      fontWeight: hasGps ? FontWeight.w500 : FontWeight.normal,
                    ),
                  ),
                ),
                if (!_isFetchingLocation)
                  IconButton(
                    tooltip: context.tr('Refresh location'),
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
            decoration: _fieldDecoration(
              label: context.tr('Landmark / Pickup Notes'),
              hint: context.tr('e.g. Behind the canal, near the yellow gate'),
              icon: Icons.signpost_outlined,
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
                color: const Color(0xFFFAFAFA),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      color: Colors.grey.shade600, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.tr(
                        'No saved places yet. Use Manual Entry and tick "Save this location" to bookmark one for next time.',
                      ),
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
                    title.isEmpty ? context.tr('Saved place') : title,
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
                    color: _kFarmerGreen.withValues(alpha: 0.4),
                  ),
                );
              }),
            ),

          if (_selectedSavedIndex != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF4FAF4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _kFarmerGreen.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.location_on_outlined,
                        size: 18, color: _kFarmerGreen),
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
            decoration: _fieldDecoration(
              label: context.tr('Landmark / Pickup Notes (optional)'),
              hint: context.tr('e.g. Opposite the borewell'),
              icon: Icons.signpost_outlined,
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
            decoration: _fieldDecoration(
              label: context.tr('Village / Area Name'),
              hint: context.tr('e.g. Bangarpet, Kolar'),
              icon: Icons.holiday_village_outlined,
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _pickupLandmarkController,
            enabled: !_isSubmitting,
            textCapitalization: TextCapitalization.sentences,
            decoration: _fieldDecoration(
              label: context.tr('Landmark / Pickup Notes'),
              hint: context.tr('e.g. Second gate on the left after the bridge'),
              icon: Icons.signpost_outlined,
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
              context.tr('Save this location for future bookings'),
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