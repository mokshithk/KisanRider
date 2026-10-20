import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import 'pool_models.dart';
import 'pools_api.dart';

String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

const Color _kFarmerGreen = Color(0xFF2E7D32);
const Color _kBackground = Color(0xFFF8F9FA);
const Color _kTextPrimary = Color(0xFF1C1B1F);
const Color _kTextSecondary = Color(0xFF6B7280);

enum PickupMode { gps, saved, manual }

class PoolDetailScreen extends StatefulWidget {
  final String poolId;

  const PoolDetailScreen({super.key, required this.poolId});

  @override
  State<PoolDetailScreen> createState() => _PoolDetailScreenState();
}

class _PoolDetailScreenState extends State<PoolDetailScreen> {
  PoolDetail? _pool;
  bool _isLoading = true;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadDetail();
      _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _loadDetail(silent: true);
      });
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadDetail({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    final auth = context.read<AuthProvider>();
    try {
      final detail = await PoolsApi.fetchPoolDetail(
        token: auth.token!,
        poolId: widget.poolId,
      );
      if (!mounted) return;
      setState(() {
        _pool = detail;
        if (!silent) _isLoading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _error = e.toString().replaceAll('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  void _showJoinSheet() async {
    final auth = context.read<AuthProvider>();
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _JoinPoolSheet(
        poolId: widget.poolId,
        authToken: auth.token!,
        poolMandiName: _pool?.dropoffMandiName ?? '',
        poolDistrict: _pool?.dropoffDistrict ?? '',
      ),
    );

    if (result == true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Successfully joined the pool!'), backgroundColor: _kFarmerGreen),
        );
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBackground,
      appBar: AppBar(
        title: const Text('Pool Details'),
        backgroundColor: _kFarmerGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadDetail(silent: false),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: _kFarmerGreen));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: () => _loadDetail(silent: false), child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_pool == null) return const SizedBox();

    final auth = context.read<AuthProvider>();
    final pool = _pool!;
    final isCreator = auth.userId == pool.creatorId;
    final isMember = pool.members.any((m) => m.farmerId == auth.userId);
    final canJoin = pool.status == 'OPEN' && !isMember;

    return RefreshIndicator(
      onRefresh: () => _loadDetail(silent: false),
      color: _kFarmerGreen,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeaderCard(pool),
                  const SizedBox(height: 16),
                  _buildInfoCard('Members (${pool.members.length})', [
                    ...pool.members.map((m) {
                      final memberIsMe = m.farmerId == auth.userId;
                      final memberIsCreator = m.farmerId == pool.creatorId;
                      
                      String displayName = m.farmerFullName ?? 'Farmer';
                      if (memberIsMe) {
                        displayName = 'You ($displayName)';
                      } else if (memberIsCreator) {
                        displayName = '$displayName (Creator)';
                      }

                      return ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Color(0x1F2E7D32),
                          child: Icon(Icons.person, color: _kFarmerGreen, size: 20),
                        ),
                        title: Text(
                          displayName,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text('${m.weightKg.toStringAsFixed(0)} kg · ${m.status}', style: const TextStyle(fontSize: 12)),
                        dense: true,
                      );
                    }),
                  ]),
                ],
              ),
            ),
          ),
          if (pool.status == 'OPEN')
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Colors.black12)),
              ),
              child: SafeArea(
                child: ElevatedButton(
                  onPressed: canJoin ? _showJoinSheet : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kFarmerGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(isCreator ? 'You created this pool' : isMember ? 'You have joined this pool' : 'Join Pool'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeaderCard(PoolDetail pool) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${pool.creatorFullName ?? 'Farmer'}\'s Pool',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _kTextPrimary),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.green.shade300),
                ),
                child: Text(pool.status, style: TextStyle(color: Colors.green.shade800, fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildRow(Icons.eco, 'Crop Type', pool.cropType),
          const SizedBox(height: 12),
          _buildRow(Icons.location_on, 'Pickup Area', pool.pickupAddress ?? 'Unknown Location'),
          const SizedBox(height: 12),
          _buildRow(Icons.storefront, 'Destination', pool.dropoffMandiName ?? 'Unknown'),
          const SizedBox(height: 12),
          _buildRow(Icons.scale, 'Capacity', '${pool.currentQty.toStringAsFixed(0)} kg'),
          const SizedBox(height: 12),
          _buildRow(Icons.access_time, 'Window', '${_formatDate(pool.pickupWindowStart)} - ${_formatDate(pool.pickupWindowEnd)}'),
        ],
      ),
    );
  }

  Widget _buildRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: _kTextSecondary),
        const SizedBox(width: 8),
        SizedBox(
          width: 80,
          child: Text(label, style: const TextStyle(fontSize: 13, color: _kTextSecondary)),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kTextPrimary)),
        ),
      ],
    );
  }

  Widget _buildInfoCard(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _kTextPrimary)),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    return '${local.day}/${local.month} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

// ---------------------------------------------------------
// Bottom Sheet for Joining the Pool (Unchanged)
// ---------------------------------------------------------

class _JoinPoolSheet extends StatefulWidget {
  final String poolId;
  final String authToken;
  final String poolMandiName;
  final String poolDistrict;

  const _JoinPoolSheet({
    required this.poolId,
    required this.authToken,
    required this.poolMandiName,
    required this.poolDistrict,
  });

  @override
  State<_JoinPoolSheet> createState() => _JoinPoolSheetState();
}

class _JoinPoolSheetState extends State<_JoinPoolSheet> {
  final _formKey = GlobalKey<FormState>();
  final _cropController = TextEditingController();
  final _weightController = TextEditingController();
  final _pickupLandmarkController = TextEditingController();
  final _manualAddressController = TextEditingController();

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

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSavedAddresses();
    _fetchCurrentLocation();
  }

  @override
  void dispose() {
    _cropController.dispose();
    _weightController.dispose();
    _pickupLandmarkController.dispose();
    _manualAddressController.dispose();
    super.dispose();
  }

  Map<String, String> _headers({bool json = false}) {
    final h = <String, String>{
      'Authorization': 'Bearer ${widget.authToken}',
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
    try {
      final response = await http.get(Uri.parse('$_kApiBaseUrl/farmer/addresses'), headers: _headers());
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
          _showError('Please pick one of your saved places.');
          return null;
        }
        final a = _savedAddresses[_selectedSavedIndex!];
        final lat = (a['latitude'] as num?)?.toDouble();
        final lng = (a['longitude'] as num?)?.toDouble();
        if (lat == null || lng == null) {
          _showError('Selected saved address has no coordinates.');
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

  Future<void> _join() async {
    if (!_formKey.currentState!.validate()) return;

    final pickup = _resolvePickup();
    if (pickup == null) return;

    setState(() => _isLoading = true);

    final weight = double.parse(_weightController.text);
    final crop = _cropController.text.trim();

    try {
      // 1. Silently create Produce Request
      final prResp = await http.post(
        Uri.parse('$_kApiBaseUrl/produce-requests/'),
        headers: _headers(json: true),
        body: jsonEncode({
          'crop_type': crop,
          'weight_kg': weight,
          'latitude': pickup.lat,
          'longitude': pickup.lng,
          'pickup_address': pickup.address,
          'pickup_landmark': pickup.landmark,
          'dropoff_district': widget.poolDistrict,
          'dropoff_mandi_name': widget.poolMandiName,
        }),
      );

      if (!mounted) return;

      if (prResp.statusCode != 201) {
        final body = jsonDecode(prResp.body);
        throw Exception(body['detail']?.toString() ?? 'Failed to create produce request.');
      }

      final prId = jsonDecode(prResp.body)['id'];

      // 2. Join Pool
      await PoolsApi.joinPool(
        token: widget.authToken,
        poolId: widget.poolId,
        produceRequestId: prId,
        weightKg: weight,
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showError(e.toString().replaceAll('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 20, right: 20, top: 20),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(
                child: SizedBox(
                  width: 44,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.all(Radius.circular(2))),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Join Pool', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),

              TextFormField(
                controller: _cropController,
                enabled: !_isLoading,
                decoration: const InputDecoration(labelText: 'Crop Name', hintText: 'e.g. Tomatoes', border: OutlineInputBorder()),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _weightController,
                enabled: !_isLoading,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Weight (kg)', hintText: 'e.g. 250', border: OutlineInputBorder(), suffixText: 'kg'),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  final d = double.tryParse(v.trim());
                  if (d == null || d <= 0) return 'Invalid';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              _buildPickupSection(),
              const SizedBox(height: 24),

              FilledButton(
                onPressed: _isLoading ? null : _join,
                style: FilledButton.styleFrom(backgroundColor: _kFarmerGreen, padding: const EdgeInsets.symmetric(vertical: 14)),
                child: _isLoading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Confirm & Join'),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPickupSection() {
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
              ButtonSegment<PickupMode>(value: PickupMode.gps, icon: Icon(Icons.my_location, size: 16), label: Text('GPS', style: TextStyle(fontSize: 12.5))),
              ButtonSegment<PickupMode>(value: PickupMode.saved, icon: Icon(Icons.bookmark_outline, size: 16), label: Text('Saved', style: TextStyle(fontSize: 12.5))),
              ButtonSegment<PickupMode>(value: PickupMode.manual, icon: Icon(Icons.edit_location_alt_outlined, size: 16), label: Text('Manual', style: TextStyle(fontSize: 12.5))),
            ],
            selected: {_pickupMode},
            onSelectionChanged: _isLoading
                ? null
                : (selection) {
                    if (selection.isEmpty) return;
                    setState(() => _pickupMode = selection.first);
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
              child: _pickupMode == PickupMode.gps
                  ? _buildGpsBody()
                  : _pickupMode == PickupMode.saved
                      ? _buildSavedBody()
                      : _buildManualBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGpsBody() {
    return Column(
      key: const ValueKey('gps'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.grey.shade300)),
          child: Row(
            children: [
              _isFetchingLocation
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(_gpsError != null ? Icons.error_outline : (_gpsAddress != null ? Icons.check_circle_outline : Icons.my_location), color: _gpsError != null ? Colors.red : _kFarmerGreen, size: 20),
              const SizedBox(width: 12),
              Expanded(child: Text(_isFetchingLocation ? 'Detecting…' : (_gpsError ?? (_gpsAddress ?? 'Tap refresh.')), style: const TextStyle(fontSize: 12))),
              if (!_isFetchingLocation) IconButton(icon: const Icon(Icons.refresh, size: 20), color: _kFarmerGreen, onPressed: _isLoading ? null : _fetchCurrentLocation),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _pickupLandmarkController,
          enabled: !_isLoading,
          decoration: const InputDecoration(labelText: 'Landmark (optional)', border: OutlineInputBorder(), isDense: true),
        ),
      ],
    );
  }

  Widget _buildSavedBody() {
    return Column(
      key: const ValueKey('saved'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_isLoadingAddresses)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else if (_savedAddresses.isEmpty)
          const Text('No saved places.', style: TextStyle(fontSize: 12))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(_savedAddresses.length, (i) {
              final a = _savedAddresses[i];
              final title = (a['title'] ?? 'Saved').toString();
              final selected = _selectedSavedIndex == i;
              return ChoiceChip(
                label: Text(title, style: TextStyle(fontSize: 12.5, color: selected ? Colors.white : _kFarmerGreen)),
                selected: selected,
                onSelected: _isLoading ? null : (_) => setState(() => _selectedSavedIndex = i),
                selectedColor: _kFarmerGreen,
                backgroundColor: Colors.white,
                side: BorderSide(color: _kFarmerGreen.withOpacity(0.4)),
              );
            }),
          ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _pickupLandmarkController,
          enabled: !_isLoading,
          decoration: const InputDecoration(labelText: 'Landmark (optional)', border: OutlineInputBorder(), isDense: true),
        ),
      ],
    );
  }

  Widget _buildManualBody() {
    return Column(
      key: const ValueKey('manual'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _manualAddressController,
          enabled: !_isLoading,
          decoration: const InputDecoration(labelText: 'Village / Area Name', border: OutlineInputBorder(), isDense: true),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _pickupLandmarkController,
          enabled: !_isLoading,
          decoration: const InputDecoration(labelText: 'Landmark (optional)', border: OutlineInputBorder(), isDense: true),
        ),
      ],
    );
  }
}