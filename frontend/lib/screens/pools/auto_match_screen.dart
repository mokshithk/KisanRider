import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import 'pool_detail_screen.dart';
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

class AutoMatchScreen extends StatefulWidget {
  const AutoMatchScreen({super.key});

  @override
  State<AutoMatchScreen> createState() => _AutoMatchScreenState();
}

class _AutoMatchScreenState extends State<AutoMatchScreen> {
  bool _isLoading = true;
  String? _error;

  // User's anchor PR
  Map<String, dynamic>? _myPr;

  // Nearby farmers
  List<NearbyFarmer> _nearbyFarmers = [];
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      setState(() {
        _isLoading = false;
        _error = 'Not signed in.';
      });
      return;
    }

    try {
      // 1. Get current location
      Position? pos;
      try {
        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
          pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium);
        }
      } catch (_) {}

      if (pos == null) {
        throw Exception('Could not determine location. Please enable GPS.');
      }

      // 2. Fetch my PENDING PR to use as the anchor
      final prResp = await http.get(
        Uri.parse('$_kApiBaseUrl/produce-requests/farmer/me'),
        headers: {'Authorization': 'Bearer ${auth.token}', 'Accept': 'application/json'},
      );
      if (prResp.statusCode == 200) {
        final list = (jsonDecode(prResp.body) as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .where((r) => r['status'] == 'PENDING')
            .toList();
        if (list.isNotEmpty) {
          _myPr = list.first;
        }
      }

      if (_myPr == null) {
        throw Exception('You need an active PENDING request to start a pool.');
      }

      // 3. Fetch nearby farmers
      final farmers = await PoolsApi.fetchNearbyFarmers(
        token: auth.token!,
        lat: pos.latitude,
        lng: pos.longitude,
      );

      // Filter by same crop type to match the mockup
      final crop = _myPr!['crop_type'];
      final filtered = farmers.where((f) => f.cropType.toLowerCase() == crop.toString().toLowerCase()).toList();

      if (!mounted) return;
      setState(() {
        _nearbyFarmers = filtered;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  void _toggleFarmer(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  // Cost calculation logic exactly matching `_compute_settlement_values`
  double _computeRiderFare(double totalWeight, double distanceKm) {
    const baseFare = 50.0;
    const distanceRatePerKm = 15.0;
    const weightFreeKg = 50.0;
    const weightSurchargePerKg = 2.0;

    final distanceFare = distanceKm * distanceRatePerKm;
    final weightSurcharge = (totalWeight > weightFreeKg ? totalWeight - weightFreeKg : 0.0) * weightSurchargePerKg;
    return baseFare + distanceFare + weightSurcharge;
  }

  Future<void> _requestSharedTrip() async {
    if (_myPr == null) return;
    
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;

    setState(() => _isLoading = true);

    // Default window: tomorrow 6AM to 12PM
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day + 1, 6, 0);
    final end = DateTime(now.year, now.month, now.day + 1, 12, 0);

    try {
      final pool = await PoolsApi.groupPool(
        token: auth.token!,
        creatorProduceRequestId: _myPr!['id'],
        otherProduceRequestIds: _selectedIds.toList(),
        pickupWindowStart: start,
        pickupWindowEnd: end,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => PoolDetailScreen(poolId: pool.id)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', '')), backgroundColor: Colors.red),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBackground,
      appBar: AppBar(
        title: const Text('Nearby Farmers'),
        backgroundColor: _kFarmerGreen,
        foregroundColor: Colors.white,
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
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 64, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _init, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final totalWeight = (_myPr!['weight_kg'] as num? ?? 0).toDouble() +
        _nearbyFarmers
            .where((f) => _selectedIds.contains(f.produceRequestId))
            .fold(0.0, (sum, f) => sum + f.weightKg);
    
    // Using a dummy distance of 15 km for the cost estimate to match the mockup
    const dummyDistanceKm = 15.0;
    final totalFare = _computeRiderFare(totalWeight, dummyDistanceKm);
    final farmerCount = _selectedIds.length + 1; // Include self
    final farePerFarmer = totalFare / farmerCount;

    return Column(
      children: [
        // Filter chip
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _kFarmerGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _kFarmerGreen.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Text(
                      '${_myPr!['crop_type']} • ≤10 km',
                      style: const TextStyle(color: _kFarmerGreen, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_drop_down, color: _kFarmerGreen, size: 18),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Map Placeholder
        Container(
          height: 140,
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F5E9), // Light green map placeholder
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _kFarmerGreen.withOpacity(0.2)),
          ),
          child: Stack(
            children: [
              // Mock dots
              Positioned(top: 30, left: 40, child: _buildMapDot()),
              Positioned(top: 60, left: 120, child: _buildMapDot()),
              Positioned(top: 20, right: 60, child: _buildMapDot()),
              Positioned(top: 80, right: 40, child: _buildMapDot()),
              Positioned(bottom: 20, left: 80, child: _buildMapDot()),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 2)),
                    ],
                  ),
                  child: Text(
                    '${_nearbyFarmers.length + 1} matches within 10 km',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kTextPrimary),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // List
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              const Text(
                'COMPATIBLE REQUESTS',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kTextSecondary, letterSpacing: 1.2),
              ),
              const SizedBox(height: 12),
              
              // Creator's own request (locked)
              _buildFarmerCard(
                name: 'You (Creator)',
                weight: (_myPr!['weight_kg'] as num).toDouble(),
                crop: _myPr!['crop_type'].toString(),
                distance: '0 km',
                isSelected: true,
                isLocked: true,
                onToggle: () {},
              ),

              ..._nearbyFarmers.map((f) {
                final isSelected = _selectedIds.contains(f.produceRequestId);
                return _buildFarmerCard(
                  name: f.farmerName,
                  weight: f.weightKg,
                  crop: f.cropType,
                  distance: '${f.distanceKm.toStringAsFixed(1)} km',
                  isSelected: isSelected,
                  isLocked: false,
                  onToggle: () => _toggleFarmer(f.produceRequestId),
                );
              }),

              if (_nearbyFarmers.isEmpty)
                Container(
                  padding: const EdgeInsets.all(32),
                  alignment: Alignment.center,
                  child: const Text('No other farmers found nearby.', style: TextStyle(color: _kTextSecondary)),
                ),
            ],
          ),
        ),

        // Bottom Summary
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [
              BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, -4)),
            ],
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Pooled total:',
                      style: TextStyle(color: _kTextSecondary, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${totalWeight.toStringAsFixed(0)} kg / $farmerCount farmers',
                      style: const TextStyle(color: _kTextPrimary, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Est. shared freight:',
                      style: TextStyle(color: _kTextSecondary, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    Row(
                      children: [
                        Text(
                          '₹${totalFare.toStringAsFixed(0)}',
                          style: TextStyle(color: _kTextSecondary, fontSize: 13, decoration: TextDecoration.lineThrough),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '₹${farePerFarmer.toStringAsFixed(0)} each',
                          style: const TextStyle(color: _kFarmerGreen, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _selectedIds.isEmpty ? null : _requestSharedTrip,
                    style: FilledButton.styleFrom(
                      backgroundColor: _kFarmerGreen,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Request shared trip', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMapDot() {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: _kFarmerGreen,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4),
        ],
      ),
    );
  }

  Widget _buildFarmerCard({
    required String name,
    required double weight,
    required String crop,
    required String distance,
    required bool isSelected,
    required bool isLocked,
    required VoidCallback onToggle,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isSelected ? _kFarmerGreen.withOpacity(0.5) : Colors.grey.shade300),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: _kFarmerGreen.withOpacity(0.1),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : 'F',
              style: const TextStyle(color: _kFarmerGreen, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _kTextPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  '$crop • ${weight.toStringAsFixed(0)} kg',
                  style: const TextStyle(fontSize: 12, color: _kTextSecondary),
                ),
              ],
            ),
          ),
          Text(
            distance,
            style: const TextStyle(fontSize: 12, color: _kTextSecondary, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: isLocked ? null : onToggle,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: isSelected ? _kFarmerGreen : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(color: isSelected ? _kFarmerGreen : Colors.grey.shade400, width: 2),
              ),
              child: isSelected
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}