import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../farmer_account_screen.dart'; // Added for Logout
import 'create_pool_screen.dart';
import 'pool_detail_screen.dart';
import 'pool_models.dart';
import 'pools_api.dart';

const Color _kFarmerGreen = Color(0xFF2E7D32);
const Color _kBackground = Color(0xFFF8F9FA);
const Color _kTextPrimary = Color(0xFF1C1B1F);
const Color _kTextSecondary = Color(0xFF6B7280);

// Enum for the 3 tabs
enum PoolTab { browse, created, joined }

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
  
  // 3-Way Toggle state
  PoolTab _currentTab = PoolTab.browse;

  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    await _fetchLocation();
    await _loadPools();
    
    // Auto-refresh every 5 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _loadPools(silent: true);
    });
  }

  Future<void> _fetchLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
        final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium)
            .timeout(const Duration(seconds: 5));
        if (mounted) {
          setState(() {
            _lat = pos.latitude;
            _lng = pos.longitude;
            _locationFetched = true;
          });
        }
      } else {
        throw Exception("Permission denied");
      }
    } catch (_) {
      // Fallback if timeout or error
      if (mounted) {
        setState(() {
          _lat = 13.1362;
          _lng = 78.1291;
          _locationFetched = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Using approximate location.'), backgroundColor: Colors.orange),
        );
      }
    }
  }

  Future<void> _loadPools({bool silent = false}) async {
    if (!_locationFetched) {
      if (!silent) {
        setState(() {
          _isLoading = false;
          _error = 'Location is required to find nearby pools.';
        });
      }
      return;
    }

    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    final auth = context.read<AuthProvider>();
    try {
      List<Pool> fetchedPools = [];

      if (_currentTab == PoolTab.browse) {
        // Fetch nearby pools
        fetchedPools = await PoolsApi.fetchNearbyPools(
          token: auth.token!,
          lat: _lat,
          lng: _lng,
          radiusKm: 10.0,
        );
      } else {
        // Fetch all my pools, then filter by created vs joined
        final myPools = await PoolsApi.fetchMyPools(token: auth.token!);
        
        if (_currentTab == PoolTab.created) {
          fetchedPools = myPools.where((p) => p.creatorId == auth.userId).toList();
        } else if (_currentTab == PoolTab.joined) {
          fetchedPools = myPools.where((p) => p.creatorId != auth.userId).toList();
        }
      }
      
      if (!mounted) return;
      setState(() {
        _pools = fetchedPools;
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

  void _openCreatePool() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CreatePoolScreen()),
    );
    // After creating, switch to 'Created' tab and refresh
    setState(() => _currentTab = PoolTab.created);
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
        actions: [
          // Replaced Refresh with Logout
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () => showLogoutConfirmation(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // 3-Way Toggle
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Colors.white,
            child: SegmentedButton<PoolTab>(
              segments: const [
                ButtonSegment<PoolTab>(
                  value: PoolTab.browse, 
                  label: Text('Browse'),
                ),
                ButtonSegment<PoolTab>(
                  value: PoolTab.created, 
                  label: Text('Created'),
                ),
                ButtonSegment<PoolTab>(
                  value: PoolTab.joined, 
                  label: Text('Joined'),
                ),
              ],
              selected: {_currentTab},
              onSelectionChanged: (Set<PoolTab> newSelection) {
                setState(() {
                  _currentTab = newSelection.first;
                  _loadPools(silent: false);
                });
              },
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: _kFarmerGreen,
                selectedForegroundColor: Colors.white,
                foregroundColor: _kFarmerGreen,
                side: BorderSide(color: _kFarmerGreen.withOpacity(0.4)),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
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
                onPressed: () => _loadPools(silent: false),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_pools.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _loadPools(silent: false),
        color: _kFarmerGreen,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.2),
            Center(
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
                      child: Icon(
                        _currentTab == PoolTab.browse 
                            ? Icons.local_shipping_outlined 
                            : Icons.folder_open, 
                        size: 64, 
                        color: _kFarmerGreen
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      _currentTab == PoolTab.browse 
                          ? 'No pools found nearby.' 
                          : _currentTab == PoolTab.created 
                              ? 'You haven\'t created any pools yet.' 
                              : 'You haven\'t joined any pools yet.',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _kTextPrimary),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _currentTab == PoolTab.browse 
                          ? 'Start a new pool and invite nearby farmers to share transport!'
                          : _currentTab == PoolTab.created
                              ? 'Tap the button below to create your first pool.'
                              : 'Browse nearby pools to join other farmers.',
                      textAlign: TextAlign.center, 
                      style: const TextStyle(fontSize: 13, color: _kTextSecondary)
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Map Placeholder (Only show on Browse tab)
        if (_currentTab == PoolTab.browse)
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
            onRefresh: () => _loadPools(silent: false),
            color: _kFarmerGreen,
            child: ListView.builder(
              padding: EdgeInsets.only(
                left: 16, 
                right: 16, 
                top: _currentTab == PoolTab.browse ? 0 : 16, 
                bottom: 80 // For FAB
              ),
              itemCount: _pools.length,
              itemBuilder: (context, index) {
                final pool = _pools[index];
                return _PoolCard(pool: pool, onTap: () => _openDetail(pool));
              },
            ),
          ),
        ),

        // Sticky Bottom Cost Calculator (Only on Browse tab)
        if (_currentTab == PoolTab.browse)
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
                  if (pool.distanceKm != null)
                    _buildInfoChip(Icons.directions_car, '${pool.distanceKm!.toStringAsFixed(1)} km away'),
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