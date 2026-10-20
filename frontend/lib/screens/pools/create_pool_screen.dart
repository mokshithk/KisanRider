import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import 'pool_discovery_screen.dart';

String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

const Color _kFarmerGreen = Color(0xFF2E7D32);

const List<String> _kDistricts = [
  'Bagalkot', 'Ballari', 'Belagavi', 'Bengaluru Rural', 'Bengaluru Urban',
  'Bidar', 'Chamarajanagar', 'Chikkaballapura', 'Chikkamagaluru',
  'Chitradurga', 'Dakshina Kannada', 'Davanagere', 'Dharwad', 'Gadag',
  'Hassan', 'Haveri', 'Kalaburagi', 'Kodagu', 'Kolar', 'Koppal', 'Mandya',
  'Mysuru', 'Raichur', 'Ramanagara', 'Shivamogga', 'Tumakuru', 'Udupi',
  'Uttara Kannada', 'Vijayapura', 'Yadgir', 'Vijayanagara',
];

enum PickupMode { gps, saved, manual }

class CreatePoolScreen extends StatefulWidget {
  const CreatePoolScreen({super.key});

  @override
  State<CreatePoolScreen> createState() => _CreatePoolScreenState();
}

class _CreatePoolScreenState extends State<CreatePoolScreen> {
  final _formKey = GlobalKey<FormState>();

  final _cropController = TextEditingController();
  final _weightController = TextEditingController();
  final _pickupLandmarkController = TextEditingController();
  final _manualAddressController = TextEditingController();
  final _shopController = TextEditingController();

  PickupMode _pickupMode = PickupMode.gps;
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

  DateTime? _windowStart;
  DateTime? _windowEnd;

  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSavedAddresses();
      _fetchCurrentLocation();
    });
  }

  @override
  void dispose() {
    _cropController.dispose();
    _weightController.dispose();
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
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() {
          _isFetchingLocation = false;
          _gpsError = 'Location permission denied. Switch to Manual Entry.';
        });
        return;
      }

      final Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium);

      String? readable;
      try {
        final placemarks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          final parts = <String>[
            if ((p.name ?? '').isNotEmpty) p.name!,
            if ((p.subLocality ?? '').isNotEmpty) p.subLocality!,
            if ((p.locality ?? '').isNotEmpty) p.locality!,
            if ((p.subAdministrativeArea ?? '').isNotEmpty) p.subAdministrativeArea!,
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
            ? '${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}'
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
        final List<dynamic> decoded = jsonDecode(response.body) as List<dynamic>;
        setState(() {
          _savedAddresses = decoded.whereType<Map<String, dynamic>>().toList();
          _isLoadingAddresses = false;
        });
      } else {
        setState(() {
          _savedAddressesError = 'Failed to load saved addresses.';
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
      final uri = Uri.parse('$_kApiBaseUrl/mandi/markets').replace(queryParameters: {'district': district});
      final response = await http.get(uri, headers: const {'Accept': 'application/json'});
      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final list = (data['markets'] as List<dynamic>?) ?? const [];

        setState(() {
          _mandis = list.whereType<Map<String, dynamic>>().toList(growable: false);
          _selectedMandiIndex = null;
          _isLoadingMandis = false;
          if (_mandis.isEmpty) {
            _mandiError = 'No markets found for "$district".';
          }
        });
      } else {
        setState(() {
          _mandiError = 'Could not load markets.';
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

  Future<void> _pickDateTime({required bool isStart}) async {
    final initialDate = DateTime.now().add(const Duration(days: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 30)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: _kFarmerGreen),
          ),
          child: child!,
        );
      },
    );
    if (date == null) return;

    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(primary: _kFarmerGreen),
          ),
          child: child!,
        );
      },
    );
    if (time == null) return;

    final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isStart) {
        _windowStart = dt;
        if (_windowEnd != null && _windowEnd!.isBefore(dt)) {
          _windowEnd = null;
        }
      } else {
        _windowEnd = dt;
      }
    });
  }

  String _formatDateTime(DateTime? dt) {
    if (dt == null) return 'Select Date & Time';
    return '${dt.day}/${dt.month}/${dt.year} at ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700),
    );
  }

  ({String address, String landmark, double lat, double lng})? _resolvePickup() {
    switch (_pickupMode) {
      case PickupMode.gps:
        if (_gpsLat == null || _gpsLng == null) {
          _showError('Cannot submit without GPS location. Please tap Refresh to detect your location.');
          return null;
        }
        return (address: _gpsAddress ?? '', landmark: _pickupLandmarkController.text.trim(), lat: _gpsLat!, lng: _gpsLng!);
      case PickupMode.saved:
        if (_selectedSavedIndex == null) {
          _showError('Please pick one of your saved places, or switch to another pickup option.');
          return null;
        }
        final a = _savedAddresses[_selectedSavedIndex!];
        final lat = (a['latitude'] as num?)?.toDouble();
        final lng = (a['longitude'] as num?)?.toDouble();
        if (lat == null || lng == null) {
          _showError('Selected saved address has no coordinates. Please update it or choose another option.');
          return null;
        }
        return (address: (a['address_text'] ?? '').toString(), landmark: _pickupLandmarkController.text.trim(), lat: lat, lng: lng);
      case PickupMode.manual:
        final address = _manualAddressController.text.trim();
        if (address.isEmpty) {
          _showError('Please enter the village or area name.');
          return null;
        }
        if (_gpsLat == null || _gpsLng == null) {
          _fetchCurrentLocation();
          _showError('Please wait for location detection before submitting.');
          return null;
        }
        return (address: address, landmark: _pickupLandmarkController.text.trim(), lat: _gpsLat!, lng: _gpsLng!);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final pickup = _resolvePickup();
    if (pickup == null) return;

    if (_selectedMandiIndex == null) {
      _showError('Please select a dropoff market.');
      return;
    }

    if (_windowStart == null || _windowEnd == null) {
      _showError('Please select the pickup window.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    final auth = context.read<AuthProvider>();
    final mandi = _mandis[_selectedMandiIndex!];
    final mandiName = (mandi['name'] ?? '').toString();
    final mandiId = (mandi['id'] ?? '').toString();
    final shop = _shopController.text.trim();
    final dropoff = shop.isEmpty ? mandiName : '$mandiName - $shop';
    final weightKg = double.parse(_weightController.text);

    try {
      // 1. Silently create Produce Request
      final prResp = await http.post(
        Uri.parse('$_kApiBaseUrl/produce-requests/'),
        headers: _headers(auth, json: true),
        body: jsonEncode({
          'crop_type': _cropController.text.trim(),
          'weight_kg': weightKg,
          'latitude': pickup.lat,
          'longitude': pickup.lng,
          'pickup_address': pickup.address,
          'pickup_landmark': pickup.landmark,
          'dropoff_district': _selectedDistrict,
          'dropoff_mandi_id': mandiId.isEmpty ? null : mandiId,
          'dropoff_mandi_name': mandiName,
          'dropoff_stall_number': shop.isEmpty ? null : shop,
          'dropoff_location': dropoff,
        }),
      );

      if (!mounted) return;

      if (prResp.statusCode != 201) {
        final body = jsonDecode(prResp.body);
        throw Exception(body['detail']?.toString() ?? 'Failed to create produce request.');
      }

      final prId = jsonDecode(prResp.body)['id'];

      // 2. Create Pool
      final poolResp = await http.post(
        Uri.parse('$_kApiBaseUrl/pools/'),
        headers: _headers(auth, json: true),
        body: jsonEncode({
          'produce_request_id': prId,
          'weight_kg': weightKg,
          'crop_type': _cropController.text.trim(),
          'pickup_window_start': _windowStart!.toUtc().toIso8601String(),
          'pickup_window_end': _windowEnd!.toUtc().toIso8601String(),
          'min_qty': 50.0,
          // max_qty omitted (backend defaults to 1000)
          'dropoff_district': _selectedDistrict,
          'dropoff_mandi_name': mandiName,
          'auto_approve': true,
        }),
      );

      if (!mounted) return;

      if (poolResp.statusCode == 201) {
        // Navigate directly to DiscoveryScreen as requested
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const PoolDiscoveryScreen()),
        );
      } else {
        final body = jsonDecode(poolResp.body);
        setState(() {
          _isSubmitting = false;
          _error = body['detail']?.toString() ?? 'Failed to create pool.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _error = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create a Pool'),
        backgroundColor: _kFarmerGreen,
        foregroundColor: Colors.white,
      ),
      body: _buildForm(Theme.of(context)),
    );
  }

  Widget _buildForm(ThemeData theme) {
    final mandiDropdownEnabled = !_isSubmitting && !_isLoadingMandis && _selectedDistrict != null && _mandis.isNotEmpty;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Pool Details', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Combine your harvest with nearby farmers to share transport costs.', style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey.shade600)),
              const SizedBox(height: 24),

              TextFormField(
                controller: _cropController,
                enabled: !_isSubmitting,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Crop Name', hintText: 'e.g. Tomatoes', border: OutlineInputBorder(), prefixIcon: Icon(Icons.eco_outlined)),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 16),

              TextFormField(
                controller: _weightController,
                enabled: !_isSubmitting,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: const InputDecoration(labelText: 'Weight (kg)', hintText: 'e.g. 250', border: OutlineInputBorder(), prefixIcon: Icon(Icons.scale_outlined), suffixText: 'kg'),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  final d = double.tryParse(v.trim());
                  if (d == null || d <= 0) return 'Invalid';
                  return null;
                },
              ),
              const SizedBox(height: 24),

              Text('Pickup Location', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: _kFarmerGreen)),
              const SizedBox(height: 12),
              _buildPickupSection(theme),
              const SizedBox(height: 24),

              DropdownButtonFormField<String>(
                value: _selectedDistrict,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Dropoff District', border: OutlineInputBorder(), prefixIcon: Icon(Icons.map_outlined)),
                items: _kDistricts.map((d) => DropdownMenuItem<String>(value: d, child: Text(d, overflow: TextOverflow.ellipsis))).toList(),
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
                  hintText: _selectedDistrict == null ? 'Select a district first' : (_isLoadingMandis ? 'Loading markets…' : 'Select a market'),
                  suffixIcon: _isLoadingMandis ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))) : null,
                ),
                items: List<DropdownMenuItem<int>>.generate(_mandis.length, (i) {
                  final m = _mandis[i];
                  final name = (m['name'] ?? '').toString();
                  final type = (m['type'] ?? '').toString();
                  final isApmc = type == 'APMC_YARD';
                  return DropdownMenuItem<int>(
                    value: i,
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: isApmc ? Colors.blue.shade50 : Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: isApmc ? Colors.blue.shade200 : Colors.orange.shade200),
                          ),
                          child: Text(isApmc ? 'APMC' : 'Local', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: isApmc ? Colors.blue.shade800 : Colors.orange.shade800)),
                        ),
                        const SizedBox(width: 6),
                        Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  );
                }),
                onChanged: mandiDropdownEnabled ? (i) => setState(() => _selectedMandiIndex = i) : null,
                validator: (v) => v == null ? 'Select a market' : null,
              ),
              if (_mandiError != null) ...[
                const SizedBox(height: 6),
                Text(_mandiError!, style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
              ],
              const SizedBox(height: 16),

              TextFormField(
                controller: _shopController,
                enabled: !_isSubmitting,
                decoration: const InputDecoration(labelText: 'Dropoff Shop / Stall Number (optional)', hintText: 'e.g. Shop #14', border: OutlineInputBorder(), prefixIcon: Icon(Icons.store_outlined)),
              ),
              const SizedBox(height: 24),

              Text('Pickup Window', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              InkWell(
                onTap: _isSubmitting ? null : () => _pickDateTime(isStart: true),
                child: InputDecorator(
                  decoration: const InputDecoration(border: OutlineInputBorder(), prefixIcon: Icon(Icons.calendar_today), labelText: 'Starts'),
                  child: Text(_formatDateTime(_windowStart)),
                ),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _isSubmitting ? null : () => _pickDateTime(isStart: false),
                child: InputDecorator(
                  decoration: const InputDecoration(border: OutlineInputBorder(), prefixIcon: Icon(Icons.calendar_today), labelText: 'Ends'),
                  child: Text(_formatDateTime(_windowEnd)),
                ),
              ),
              const SizedBox(height: 32),

              if (_error != null) ...[
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                const SizedBox(height: 16),
              ],

              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                style: FilledButton.styleFrom(backgroundColor: _kFarmerGreen, padding: const EdgeInsets.symmetric(vertical: 16)),
                child: _isSubmitting
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Create Pool'),
              ),
            ],
          ),
        ),
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
          SegmentedButton<PickupMode>(
            segments: const [
              ButtonSegment<PickupMode>(value: PickupMode.gps, icon: Icon(Icons.my_location, size: 16), label: Text('Current GPS', style: TextStyle(fontSize: 12.5))),
              ButtonSegment<PickupMode>(value: PickupMode.saved, icon: Icon(Icons.bookmark_outline, size: 16), label: Text('Saved', style: TextStyle(fontSize: 12.5))),
              ButtonSegment<PickupMode>(value: PickupMode.manual, icon: Icon(Icons.edit_location_alt_outlined, size: 16), label: Text('Manual', style: TextStyle(fontSize: 12.5))),
            ],
            selected: {_pickupMode},
            onSelectionChanged: _isSubmitting
                ? null
                : (selection) {
                    if (selection.isEmpty) return;
                    setState(() {
                      _pickupMode = selection.first;
                      _error = null;
                    });
                  },
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: _kFarmerGreen,
              selectedForegroundColor: Colors.white,
              foregroundColor: _kFarmerGreen,
              side: BorderSide(color: _kFarmerGreen.withOpacity(0.4)),
              visualDensity: VisualDensity.compact,
            ),
          ),
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

  Widget _buildGpsBody(ThemeData theme) {
    return KeyedSubtree(
      key: const ValueKey('pickup_gps'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.grey.shade300)),
            child: Row(
              children: [
                _isFetchingLocation
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(_gpsError != null ? Icons.error_outline : (_gpsAddress != null ? Icons.check_circle_outline : Icons.my_location), color: _gpsError != null ? theme.colorScheme.error : _kFarmerGreen, size: 20),
                const SizedBox(width: 12),
                Expanded(child: Text(_isFetchingLocation ? 'Detecting your location…' : (_gpsError ?? (_gpsAddress ?? 'Tap refresh to detect location.')), style: theme.textTheme.bodySmall)),
                if (!_isFetchingLocation) IconButton(icon: const Icon(Icons.refresh, size: 20), color: _kFarmerGreen, onPressed: _isSubmitting ? null : _fetchCurrentLocation),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _pickupLandmarkController,
            enabled: !_isSubmitting,
            decoration: const InputDecoration(labelText: 'Landmark / Pickup Notes', border: OutlineInputBorder(), prefixIcon: Icon(Icons.signpost_outlined), isDense: true),
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
            const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
          else if (_savedAddressesError != null)
            Text(_savedAddressesError!, style: TextStyle(color: theme.colorScheme.error, fontSize: 12))
          else if (_savedAddresses.isEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.grey.shade300)),
              child: Text('No saved places yet. Use Manual Entry to bookmark one.', style: theme.textTheme.bodySmall),
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
                  label: Text(title.isEmpty ? 'Saved place' : title, style: TextStyle(fontSize: 12.5, color: selected ? Colors.white : _kFarmerGreen, fontWeight: FontWeight.w600)),
                  selected: selected,
                  onSelected: _isSubmitting ? null : (_) => setState(() => _selectedSavedIndex = i),
                  selectedColor: _kFarmerGreen,
                  backgroundColor: Colors.white,
                  side: BorderSide(color: _kFarmerGreen.withOpacity(0.4)),
                );
              }),
            ),
          if (_selectedSavedIndex != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.grey.shade300)),
              child: Text((_savedAddresses[_selectedSavedIndex!]['address_text'] ?? '').toString(), style: theme.textTheme.bodyMedium),
            ),
          ],
          const SizedBox(height: 12),
          TextFormField(
            controller: _pickupLandmarkController,
            enabled: !_isSubmitting,
            decoration: const InputDecoration(labelText: 'Landmark / Pickup Notes (optional)', border: OutlineInputBorder(), prefixIcon: Icon(Icons.signpost_outlined), isDense: true),
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
            decoration: const InputDecoration(labelText: 'Village / Area Name', hintText: 'e.g. Bangarpet, Kolar', border: OutlineInputBorder(), prefixIcon: Icon(Icons.holiday_village_outlined), isDense: true),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _pickupLandmarkController,
            enabled: !_isSubmitting,
            decoration: const InputDecoration(labelText: 'Landmark / Pickup Notes', border: OutlineInputBorder(), prefixIcon: Icon(Icons.signpost_outlined), isDense: true),
          ),
        ],
      ),
    );
  }
}