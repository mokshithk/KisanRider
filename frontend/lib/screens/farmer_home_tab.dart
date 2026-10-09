import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;   // <-- ADDED
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/auth_provider.dart';

/// Base URL of the FastAPI backend.
String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

/// Brand green, kept local so this file has no dependency on
/// farmer_dashboard.dart.
const Color _kFarmerGreen = Color(0xFF2E7D32);

/// Districts shown in the header dropdown before the backend responds
/// with its own `available_districts` list. Keeps the selector usable on
/// the very first frame.
const List<String> _kFallbackDistricts = [
  'Kolar',
  'Bengaluru Urban',
  'Bengaluru Rural',
  'Mandya',
  'Belagavi',
  'Davanagere',
  'Mysuru',
  'Tumakuru',
];

/// Home tab of the farmer dashboard. Fetches the farmer's produce requests
/// and today's APMC rates on load, and exposes a district selector that
/// re-fetches rates for the chosen district.
class FarmerHomeTab extends StatefulWidget {
  const FarmerHomeTab({super.key, required this.onTabSwitch});

  /// Called with a bottom-nav tab index (0..3). Used by the header's
  /// "Book Transport" and "My Orders" quick actions, and by the Active
  /// Shipment card's "Track Order" button. Passing the callback down keeps
  /// this widget decoupled from the parent dashboard's state.
  final void Function(int) onTabSwitch;

  @override
  State<FarmerHomeTab> createState() => _FarmerHomeTabState();
}

class _FarmerHomeTabState extends State<FarmerHomeTab> {
  String currentDistrict = 'Kolar';
  List<dynamic> mandiRates = [];
  List<dynamic> availableDistricts = [];
  List<dynamic> myRequests = [];
  bool isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Provider/context is only safe after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  // -------------------------------------------------------------------------
  // Networking
  // -------------------------------------------------------------------------

  Map<String, String> _authHeaders(AuthProvider auth) {
    return {
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
  }

  Future<void> _loadAll() async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      setState(() {
        isLoading = false;
        _error = 'Not signed in.';
      });
      return;
    }

    setState(() {
      isLoading = true;
      _error = null;
    });

    await Future.wait([
      _fetchMyRequests(auth),
      fetchMandiRates(currentDistrict),
    ]);

    if (mounted) setState(() => isLoading = false);
  }

  Future<void> _fetchMyRequests(AuthProvider auth) async {
    try {
      // The backend exposes this list at /produce-requests/farmer/me
      // (there is no plain GET /produce-requests/ — that path only accepts
      // POST).
      final response = await http.get(
        Uri.parse('$_kApiBaseUrl/produce-requests/farmer/me'),
        headers: _authHeaders(auth),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        setState(() {
          myRequests = decoded is List ? decoded : const [];
        });
      }
    } catch (_) {
      // Non-fatal — the KPI cards and Active Shipment section simply stay
      // empty rather than failing the whole screen.
    }
  }

  /// Re-fetches rates for [district]. Called on init and from the header's
  /// district dropdown.
  Future<void> fetchMandiRates(String district) async {
    try {
      final uri = Uri.parse('$_kApiBaseUrl/mandi-rates/')
          .replace(queryParameters: {'district': district});

      final response = await http.get(
        uri,
        headers: const {'Accept': 'application/json'},
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          mandiRates = (data['rates'] as List<dynamic>?) ?? const [];
          final returnedDistricts =
              (data['available_districts'] as List<dynamic>?) ?? const [];
          availableDistricts = returnedDistricts.isEmpty
              ? List<String>.from(_kFallbackDistricts)
              : returnedDistricts;
          currentDistrict =
              (data['selected_district'] ?? district).toString();
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (availableDistricts.isEmpty) {
          availableDistricts = List<String>.from(_kFallbackDistricts);
        }
      });
    }
  }

  // -------------------------------------------------------------------------
  // Derived state
  // -------------------------------------------------------------------------

  /// Union of the current district and whatever the backend advertised, so
  /// the dropdown always has a valid `value` even during a mid-fetch.
  List<String> get _districtOptions {
    final set = <String>{currentDistrict};
    for (final d in availableDistricts) {
      final s = d.toString();
      if (s.isNotEmpty) set.add(s);
    }
    return set.toList();
  }

  /// The first request currently in ACCEPTED or PICKED_UP, if any. Drives
  /// the Active Shipment card.
  Map<String, dynamic>? get _activeOrder {
    for (final r in myRequests) {
      if (r is Map<String, dynamic>) {
        final status = (r['status'] ?? '').toString();
        if (status == 'ACCEPTED' || status == 'PICKED_UP') return r;
      }
    }
    return null;
  }

  int get _activeRequestCount => myRequests.where((r) {
        if (r is! Map) return false;
        final s = (r['status'] ?? '').toString();
        return s == 'PENDING' || s == 'ACCEPTED' || s == 'PICKED_UP';
      }).length;

  int get _completedCount => myRequests.where((r) {
        if (r is! Map) return false;
        final s = (r['status'] ?? '').toString();
        // The produce_request flips to COMPLETED when its Trip reaches
        // DELIVERED, so both values mean "done" here.
        return s == 'COMPLETED' || s == 'DELIVERED';
      }).length;

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _loadAll,
        color: _kFarmerGreen,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 80),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                _ErrorBlock(message: _error!, onRetry: _loadAll)
              else ...[
                _buildHeader(),
                const SizedBox(height: 20),
                if (_activeOrder != null) ...[
                  _ActiveShipmentCard(
                    order: _activeOrder!,
                    onTrack: () => widget.onTabSwitch(2),
                  ),
                  const SizedBox(height: 20),
                ],
                _buildMarketRatesSection(),
                const SizedBox(height: 24),
                _buildQuickActions(),
                const SizedBox(height: 24),
                _buildKpiRow(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Welcome Back, Farmer!',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Here\'s your farm at a glance',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        // District selector — changing it re-fetches live rates.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _kFarmerGreen.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _kFarmerGreen.withOpacity(0.4)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: currentDistrict,
              isDense: true,
              icon: const Icon(Icons.expand_more, color: _kFarmerGreen),
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
              items: _districtOptions
                  .map(
                    (d) => DropdownMenuItem<String>(
                      value: d,
                      child: Text(d, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v == null || v == currentDistrict) return;
                setState(() => currentDistrict = v);
                fetchMandiRates(v);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMarketRatesSection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.trending_up, color: _kFarmerGreen, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Today\'s APMC Rates ($currentDistrict)',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (mandiRates.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'No rates available for $currentDistrict right now.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          SizedBox(
            height: 130,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: mandiRates.length,
              itemBuilder: (context, index) {
                final rate = mandiRates[index];
                if (rate is! Map) return const SizedBox.shrink();
                return _RateCard(
                  crop: (rate['crop'] ?? '').toString(),
                  price: (rate['modal_price'] ?? '').toString(),
                  mandi: (rate['mandi'] ?? '').toString(),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildQuickActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: () => widget.onTabSwitch(1),
          style: FilledButton.styleFrom(
            backgroundColor: _kFarmerGreen,
            padding: const EdgeInsets.symmetric(vertical: 16),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: const Icon(Icons.add_road),
          label: const Text('Book Transport'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => widget.onTabSwitch(2),
          style: OutlinedButton.styleFrom(
            foregroundColor: _kFarmerGreen,
            side: const BorderSide(color: _kFarmerGreen),
            padding: const EdgeInsets.symmetric(vertical: 14),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: const Icon(Icons.receipt_long),
          label: const Text('My Orders'),
        ),
      ],
    );
  }

  Widget _buildKpiRow() {
    return Row(
      children: [
        Expanded(
          child: _KpiCard(
            icon: Icons.pending_actions,
            label: 'Active Requests',
            value: _activeRequestCount.toString(),
            color: Colors.orange.shade800,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _KpiCard(
            icon: Icons.check_circle_outline,
            label: 'Completed Shipments',
            value: _completedCount.toString(),
            color: _kFarmerGreen,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _ActiveShipmentCard extends StatelessWidget {
  const _ActiveShipmentCard({required this.order, required this.onTrack});

  final Map<String, dynamic> order;
  final VoidCallback onTrack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final crop = (order['crop_type'] ?? '').toString();
    final crateCount = ((order['crate_count'] ?? 0) as num).toInt();
    final status = (order['status'] ?? '').toString();
    final otp = (order['pickup_otp'] ?? '').toString();
    final dropoff = (order['dropoff_location'] ?? '').toString();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _kFarmerGreen.withOpacity(0.12),
            _kFarmerGreen.withOpacity(0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kFarmerGreen.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_shipping,
                  color: _kFarmerGreen, size: 20),
              const SizedBox(width: 8),
              Text(
                'Active Shipment',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _kFarmerGreen,
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: status == 'ACCEPTED'
                      ? Colors.blue.withOpacity(0.15)
                      : Colors.purple.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: status == 'ACCEPTED'
                        ? Colors.blue.shade700
                        : Colors.purple.shade700,
                  ),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    color: status == 'ACCEPTED'
                        ? Colors.blue.shade800
                        : Colors.purple.shade800,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '$crop • $crateCount crates',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          if (dropoff.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.flag_outlined,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'To: $dropoff',
                    style: theme.textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          // The OTP badge is the whole point of this card for an ACCEPTED
          // order — the farmer reads it to the rider at handoff.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.amber.shade100,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.lock_outline,
                    size: 18, color: Colors.amber.shade900),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Pickup OTP: ${otp.isEmpty ? "----" : otp}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.amber.shade900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onTrack,
              style: FilledButton.styleFrom(
                backgroundColor: _kFarmerGreen,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.location_searching, size: 18),
              label: const Text('Track Order'),
            ),
          ),
        ],
      ),
    );
  }
}

class _RateCard extends StatelessWidget {
  const _RateCard({
    required this.crop,
    required this.price,
    required this.mandi,
  });

  final String crop;
  final String price;
  final String mandi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 150,
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            crop,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            price,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: _kFarmerGreen,
            ),
          ),
          const Spacer(),
          Row(
            children: [
              Icon(Icons.storefront_outlined,
                  size: 12, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  mandi,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const Spacer(),
              Text(
                value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80),
      child: Column(
        children: [
          Icon(Icons.cloud_off_rounded,
              size: 56, color: theme.colorScheme.error),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}