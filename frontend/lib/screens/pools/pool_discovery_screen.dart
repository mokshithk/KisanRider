import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import 'create_pool_screen.dart';
import 'pool_detail_screen.dart';
import 'pool_models.dart';
import 'pools_api.dart';

const Color _kFarmerGreen = Color(0xFF2E7D32);
const Color _kBackground = Color(0xFFF8F9FA);
const Color _kTextPrimary = Color(0xFF1C1B1F);
const Color _kTextSecondary = Color(0xFF6B7280);

class PoolDiscoveryScreen extends StatefulWidget {
  const PoolDiscoveryScreen({super.key});

  @override
  State<PoolDiscoveryScreen> createState() => _PoolDiscoveryScreenState();
}

class _PoolDiscoveryScreenState extends State<PoolDiscoveryScreen> {
  List<Pool> _pools = [];
  bool _isLoading = true;
  String? _error;
  double _lat = 0.0;
  double _lng = 0.0;
  bool _locationFetched = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    await _fetchLocation();
    await _loadPools();
  }

  Future<void> _fetchLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
        final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium);
        if (mounted) {
          setState(() {
            _lat = pos.latitude;
            _lng = pos.longitude;
            _locationFetched = true;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _loadPools() async {
    if (!_locationFetched) {
      setState(() {
        _isLoading = false;
        _error = 'Location is required to find nearby pools.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final auth = context.read<AuthProvider>();
    try {
      final pools = await PoolsApi.fetchNearbyPools(
        token: auth.token!,
        lat: _lat,
        lng: _lng,
        radiusKm: 10.0, // Hardcoded 10km as per spec
      );
      if (!mounted) return;
      setState(() {
        _pools = pools;
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

  void _openCreatePool() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CreatePoolScreen()),
    );
    _loadPools();
  }

  void _openDetail(Pool pool) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PoolDetailScreen(poolId: pool.id)),
    );
    _loadPools();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBackground,
      appBar: AppBar(
        title: const Text('Find Pools'),
        backgroundColor: _kFarmerGreen,
        foregroundColor: Colors.white,
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreatePool,
        backgroundColor: _kFarmerGreen,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Create Pool'),
      ),
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
              OutlinedButton.icon(
                onPressed: _init,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_pools.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: _kFarmerGreen.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.local_shipping_outlined, size: 64, color: _kFarmerGreen),
              ),
              const SizedBox(height: 24),
              const Text('No pools found nearby.', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _kTextPrimary)),
              const SizedBox(height: 8),
              const Text('Start a new pool and invite nearby farmers to share transport!', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: _kTextSecondary)),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        // Map Placeholder
        Container(
          height: 180,
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F5E9), // Light green map background
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _kFarmerGreen.withOpacity(0.2)),
          ),
          child: Stack(
            children: [
              // Mock map dots for pool locations
              Positioned(top: 30, left: 40, child: _buildMapDot()),
              Positioned(top: 80, left: 100, child: _buildMapDot()),
              Positioned(top: 40, right: 60, child: _buildMapDot()),
              Positioned(top: 120, right: 80, child: _buildMapDot()),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 2))],
                  ),
                  child: Text(
                    '${_pools.length} pools within 10 km',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kTextPrimary),
                  ),
                ),
              ),
            ],
          ),
        ),
        
        // Pool List
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadPools,
            color: _kFarmerGreen,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _pools.length,
              itemBuilder: (context, index) {
                final pool = _pools[index];
                return _PoolCard(pool: pool, onTap: () => _openDetail(pool));
              },
            ),
          ),
        ),

        // Sticky Bottom Cost Calculator
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, -4))],
          ),
          child: SafeArea(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Est. Shared Freight:', style: TextStyle(color: _kTextSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                Text(
                  '₹${_calculateAverageCost().toStringAsFixed(0)}',
                  style: const TextStyle(color: _kFarmerGreen, fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  double _calculateAverageCost() {
    if (_pools.isEmpty) return 0.0;
    // Dummy calculation for mockup: base 500 + 10 per kg of the first pool, divided by members
    final firstPool = _pools.first;
    final totalFare = 50.0 + (firstPool.currentQty * 2.0);
    final members = firstPool.memberCount > 0 ? firstPool.memberCount : 1;
    return totalFare / members;
  }

  Widget _buildMapDot() {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: _kFarmerGreen,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4)],
      ),
    );
  }
}

class _PoolCard extends StatelessWidget {
  final Pool pool;
  final VoidCallback onTap;

  const _PoolCard({required this.pool, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${pool.creatorFullName ?? 'Farmer'}\'s Pool',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _kTextPrimary),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.green.shade300),
                    ),
                    child: Text(pool.status, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.green.shade800)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.storefront, size: 14, color: _kTextSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      pool.dropoffMandiName ?? 'Unknown Destination',
                      style: const TextStyle(fontSize: 13, color: _kTextPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _buildInfoChip(Icons.scale, '${pool.currentQty.toStringAsFixed(0)} kg'),
                  const SizedBox(width: 8),
                  _buildInfoChip(Icons.directions_car, '${pool.distanceKm?.toStringAsFixed(1) ?? '0.0'} km away'),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.access_time, size: 14, color: _kTextSecondary),
                  const SizedBox(width: 6),
                  Text('Starts ${_formatDate(pool.pickupWindowStart)}', style: const TextStyle(fontSize: 12, color: _kTextSecondary)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _kBackground,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: _kTextSecondary),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kTextSecondary)),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    return '${local.day}/${local.month} at ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}