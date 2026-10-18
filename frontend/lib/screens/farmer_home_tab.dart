import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/auth_provider.dart';
import 'mandi_prices_screen.dart';
import 'order_history_screen.dart';

/// Base URL of the FastAPI backend.
String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

/// Shared brand color + surface palette used by the refactored dashboard.
const Color _kFarmerGreen = Color(0xFF2E7D32);
const Color _kBackground = Color(0xFFF8F9FA);
const Color _kTextPrimary = Color(0xFF1C1B1F);
const Color _kTextSecondary = Color(0xFF6B7280);

/// Support phone number dialed from the bottom banner (digits only —
/// `tel:` URLs don't take spaces or dashes).
const String _kSupportPhone = '1800000000';

// ============================================================================
// Farmer Home Tab
// ============================================================================

/// Home / dashboard tab for the farmer. Renders, top to bottom:
///
///   1. Greeting header (avatar + "Namaste, <name>") with a read-only
///      district chip beneath it.
///   2. Three equal summary metric cards (Active / In Transit / Completed).
///   3. Conditional active-shipment card (only when a rider has accepted).
///   4. 2×2 quick-action grid (New Request, Find Pool, Mandi Prices,
///      Order History).
///   5. "TODAY'S TRIPS" section with up to 3 recent orders.
///   6. Full-width support banner with a phone dialer action.
///
/// The whole page is a single `SingleChildScrollView` so it scrolls
/// naturally on any screen height.
class FarmerHomeTab extends StatefulWidget {
  const FarmerHomeTab({super.key, required this.onTabSwitch});

  /// Called with a logical action index:
  ///   1 = open Book Transport (Create Order) flow
  ///   2 = navigate to the My Orders tab
  ///
  /// The parent dashboard intercepts these and performs the actual
  /// routing (Book Transport as a modal route, My Orders as a tab switch).
  final void Function(int) onTabSwitch;

  @override
  State<FarmerHomeTab> createState() => _FarmerHomeTabState();
}

class _FarmerHomeTabState extends State<FarmerHomeTab> {
  List<Map<String, dynamic>> _requests = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDashboard());
  }

  // -------------------------------------------------------------------------
  // Networking
  // -------------------------------------------------------------------------

  Map<String, String> _headers(AuthProvider auth) => {
        'Authorization': 'Bearer ${auth.token}',
        'Accept': 'application/json',
      };

  Future<void> _loadDashboard() async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      setState(() {
        _isLoading = false;
        _error = 'Not signed in.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final resp = await http.get(
        Uri.parse('$_kApiBaseUrl/produce-requests/farmer/me'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        final list = (decoded is List ? decoded : const [])
            .whereType<Map<String, dynamic>>()
            .toList();

        // Newest-first. The backend already sorts this way, but re-sorting
        // here is defensive and lets the section header ("TODAY'S TRIPS")
        // always render the most recent items first.
        list.sort((a, b) {
          final ad = DateTime.tryParse((a['created_at'] ?? '').toString()) ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final bd = DateTime.tryParse((b['created_at'] ?? '').toString()) ??
              DateTime.fromMillisecondsSinceEpoch(0);
          return bd.compareTo(ad);
        });

        setState(() {
          _requests = list;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Could not load dashboard '
              '(HTTP ${resp.statusCode}).';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Network error: $e';
        _isLoading = false;
      });
    }
  }

  // -------------------------------------------------------------------------
  // Derived state
  // -------------------------------------------------------------------------

  String get _firstName {
    final name = context.read<AuthProvider>().fullName ?? '';
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Farmer';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  String get _initialLetter {
    final n = _firstName;
    if (n.isEmpty) return 'F';
    return n.substring(0, 1).toUpperCase();
  }

  String get _district {
    final d = context.read<AuthProvider>().district ?? '';
    final trimmed = d.trim();
    return trimmed.isEmpty ? 'Karnataka' : trimmed;
  }

  int get _activeCount => _requests.where((r) {
        final s = (r['status'] ?? '').toString().toUpperCase();
        return s == 'PENDING' || s == 'ACCEPTED';
      }).length;

  int get _inTransitCount => _requests.where((r) {
        final s = (r['status'] ?? '').toString().toUpperCase();
        return s == 'PICKED_UP' || s == 'IN_TRANSIT';
      }).length;

  int get _completedCount => _requests.where((r) {
        final s = (r['status'] ?? '').toString().toUpperCase();
        return s == 'COMPLETED' || s == 'DELIVERED';
      }).length;

  /// The first order currently being fulfilled (rider assigned, not yet
  /// delivered/cancelled). Drives the conditional Active Shipment card.
  Map<String, dynamic>? get _activeShipment {
    for (final r in _requests) {
      final s = (r['status'] ?? '').toString().toUpperCase();
      if (s == 'ACCEPTED' || s == 'PICKED_UP' || s == 'IN_TRANSIT') {
        return r;
      }
    }
    return null;
  }

  /// Up to 3 most recent orders for the "TODAY'S TRIPS" section.
  List<Map<String, dynamic>> get _recentTrips =>
      _requests.take(3).toList(growable: false);

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Short, uppercase, human-friendly reference derived from the UUID's
  /// first 6 hex characters. Matches the convention used elsewhere in the
  /// app (e.g. Order History, Order Detail).
  String _shortTripId(String id) {
    final compact = id.replaceAll('-', '');
    final take = compact.length >= 6 ? compact.substring(0, 6) : compact;
    return 'TR-${take.toUpperCase()}';
  }

  /// Category label for the small status tag on each recent-trip row.
  String _categoryStatus(String rawStatus) {
    final s = rawStatus.toUpperCase();
    if (s == 'DELIVERED' || s == 'COMPLETED') return 'delivered';
    if (s == 'CANCELLED') return 'cancelled';
    if (s == 'PICKED_UP' || s == 'IN_TRANSIT') return 'in transit';
    if (s == 'ACCEPTED') return 'in transit';
    return 'pending';
  }

  /// Foreground / background colour pair for the status tag.
  ({Color fg, Color bg}) _categoryColors(String rawStatus) {
    final s = rawStatus.toUpperCase();
    if (s == 'DELIVERED' || s == 'COMPLETED') {
      return (fg: const Color(0xFF166534), bg: const Color(0x1F16A34A));
    }
    if (s == 'CANCELLED') {
      return (fg: const Color(0xFF991B1B), bg: const Color(0x1FDC2626));
    }
    if (s == 'PICKED_UP' || s == 'IN_TRANSIT' || s == 'ACCEPTED') {
      return (fg: const Color(0xFF6D28D9), bg: const Color(0x1F6D28D9));
    }
    return (fg: const Color(0xFFB45309), bg: const Color(0x1FF59E0B));
  }

  /// One-line subtitle shown under the trip ID — driver name when known,
  /// otherwise a short status description.
  String _tripSubtitle(Map<String, dynamic> r) {
    final status = (r['status'] ?? '').toString().toUpperCase();
    final trip = r['trip'] as Map<String, dynamic>?;
    final rider = trip?['rider'] as Map<String, dynamic>?;
    final riderName = (rider?['full_name'] ?? '').toString().trim();

    if (status == 'DELIVERED' || status == 'COMPLETED') {
      return 'Delivered';
    }
    if (status == 'CANCELLED') {
      return 'Cancelled';
    }
    if (riderName.isNotEmpty) {
      return 'Driver: $riderName';
    }
    if (status == 'PENDING') {
      return 'Awaiting rider';
    }
    return status.replaceAll('_', ' ').toLowerCase();
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  void _openNewRequest() => widget.onTabSwitch(1);

  void _openTrackOrder() => widget.onTabSwitch(2);

  void _openFindPool() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Farmer pool matching is coming soon.'),
        ),
      );
  }

  void _openOrderHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const OrderHistoryScreen(),
      ),
    );
  }

  void _openMandiPrices() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const MandiPricesScreen(),
      ),
    );
  }

  Future<void> _callSupport() async {
    final uri = Uri(scheme: 'tel', path: _kSupportPhone);
    try {
      final ok = await launchUrl(uri);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the dialer.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the dialer.')),
        );
      }
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _ErrorBlock(message: _error!, onRetry: _loadDashboard);
    }

    return RefreshIndicator(
      onRefresh: _loadDashboard,
      color: _kFarmerGreen,
      child: Container(
        color: _kBackground,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              const SizedBox(height: 20),
              _buildMetricsRow(),
              const SizedBox(height: 16),
              if (_activeShipment != null) ...[
                _ActiveShipmentCard(
                  order: _activeShipment!,
                  shortId: _shortTripId(
                    (_activeShipment!['id'] ?? '').toString(),
                  ),
                  onTrack: _openTrackOrder,
                ),
                const SizedBox(height: 16),
              ],
              _buildQuickActionsGrid(),
              const SizedBox(height: 24),
              _buildRecentTripsSection(),
              const SizedBox(height: 20),
              _buildSupportBanner(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: _kFarmerGreen.withOpacity(0.12),
              child: Text(
                _initialLetter,
                style: const TextStyle(
                  color: _kFarmerGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Namaste, $_firstName',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: _kTextPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.location_on_outlined,
                size: 14,
                color: _kTextSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                _district,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _kTextPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMetricsRow() {
    return Row(
      children: [
        Expanded(child: _MetricCard(value: _activeCount, label: 'ACTIVE')),
        const SizedBox(width: 10),
        Expanded(
          child: _MetricCard(value: _inTransitCount, label: 'IN TRANSIT'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _MetricCard(value: _completedCount, label: 'COMPLETED'),
        ),
      ],
    );
  }

  Widget _buildQuickActionsGrid() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _QuickActionCard(
                icon: Icons.add_circle_outline,
                title: 'New Request',
                subtitle: 'Add produce',
                onTap: _openNewRequest,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _QuickActionCard(
                icon: Icons.handshake_outlined,
                title: 'Find Pool',
                subtitle: 'Nearby farmers',
                onTap: _openFindPool,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _QuickActionCard(
                icon: Icons.trending_up,
                title: 'Mandi Prices',
                subtitle: 'Compare & earn',
                onTap: _openMandiPrices,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _QuickActionCard(
                icon: Icons.history,
                title: 'Order History',
                subtitle: 'View past shipments',
                onTap: _openOrderHistory,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRecentTripsSection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "TODAY'S TRIPS",
          style: theme.textTheme.labelMedium?.copyWith(
            color: _kTextSecondary,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            fontSize: 11.5,
          ),
        ),
        const SizedBox(height: 10),
        if (_recentTrips.isEmpty)
          const _EmptyTripsPlaceholder()
        else
          ..._recentTrips.map(
            (r) => _RecentTripTile(
              order: r,
              shortId: _shortTripId((r['id'] ?? '').toString()),
              categoryLabel: _categoryStatus(
                (r['status'] ?? '').toString(),
              ),
              categoryColors: _categoryColors(
                (r['status'] ?? '').toString(),
              ),
              subtitle: _tripSubtitle(r),
            ),
          ),
      ],
    );
  }

  Widget _buildSupportBanner() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.headset_mic_outlined,
            color: _kFarmerGreen,
            size: 22,
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Need help with your shipment?',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _kTextPrimary,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Call KisanRider Support',
                  style: TextStyle(
                    fontSize: 12,
                    color: _kTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Call Support',
            onPressed: _callSupport,
            icon: const Icon(Icons.phone, color: _kFarmerGreen),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Metric card
// ============================================================================

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value.toString(),
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: _kTextPrimary,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: _kTextSecondary,
              letterSpacing: 0.6,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Quick action card
// ============================================================================

class _QuickActionCard extends StatelessWidget {
  const _QuickActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _kFarmerGreen.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: _kFarmerGreen, size: 18),
              ),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: _kTextPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: _kTextSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Active shipment card
// ============================================================================

class _ActiveShipmentCard extends StatelessWidget {
  const _ActiveShipmentCard({
    required this.order,
    required this.shortId,
    required this.onTrack,
  });

  final Map<String, dynamic> order;
  final String shortId;
  final VoidCallback onTrack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final crop = (order['crop_type'] ?? '').toString().trim();
    final weightKg = ((order['weight_kg'] ?? 0) as num).toDouble();
    final rawStatus = (order['status'] ?? '').toString().toUpperCase();
    final dropoff = (order['dropoff_location'] ?? '').toString().trim();
    final otp = (order['pickup_otp'] ?? '').toString().trim();

    final headerLabel = crop.isEmpty
        ? '${weightKg.toStringAsFixed(0)} kg'
        : '$crop · ${weightKg.toStringAsFixed(0)} kg';

    return Container(
      padding: const EdgeInsets.all(14),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headerLabel,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: _kTextPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      shortId,
                      style: const TextStyle(
                        fontSize: 11,
                        color: _kTextSecondary,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _RawStatusBadge(status: rawStatus),
            ],
          ),
          if (dropoff.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.flag_outlined,
                  size: 14,
                  color: _kTextSecondary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'To: $dropoff',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: _kTextPrimary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          // Pickup OTP highlight banner
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 9,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7E0),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFFE0A3)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 16,
                  color: Color(0xFF8A5A00),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Pickup OTP: ${otp.isEmpty ? "----" : otp}',
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF8A5A00),
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onTrack,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kFarmerGreen,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
              child: const Text('Track Order'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small pill that shows the *raw* status verbatim (e.g. "ACCEPTED",
/// "PICKED_UP"). Used only on the Active Shipment card, where the exact
/// backend status is the most useful label.
class _RawStatusBadge extends StatelessWidget {
  const _RawStatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final s = status.toUpperCase();
    final Color fg;
    final Color bg;
    if (s == 'ACCEPTED') {
      fg = const Color(0xFF1D4ED8);
      bg = const Color(0x1F1D4ED8);
    } else if (s == 'PICKED_UP' || s == 'IN_TRANSIT') {
      fg = const Color(0xFF6D28D9);
      bg = const Color(0x1F6D28D9);
    } else if (s == 'DELIVERED' || s == 'COMPLETED') {
      fg = const Color(0xFF166534);
      bg = const Color(0x1F16A34A);
    } else if (s == 'CANCELLED') {
      fg = const Color(0xFF991B1B);
      bg = const Color(0x1FDC2626);
    } else {
      fg = const Color(0xFFB45309);
      bg = const Color(0x1FF59E0B);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg.withOpacity(0.55)),
      ),
      child: Text(
        s,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w700,
          fontSize: 10.5,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ============================================================================
// Recent trip tile
// ============================================================================

class _RecentTripTile extends StatelessWidget {
  const _RecentTripTile({
    required this.order,
    required this.shortId,
    required this.categoryLabel,
    required this.categoryColors,
    required this.subtitle,
  });

  final Map<String, dynamic> order;
  final String shortId;
  final String categoryLabel;
  final ({Color fg, Color bg}) categoryColors;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final crop = (order['crop_type'] ?? '').toString().trim();
    final weightKg = ((order['weight_kg'] ?? 0) as num).toDouble();
    final weightLabel =
        weightKg > 0 ? '${weightKg.toStringAsFixed(0)} kg' : '';
    final titleParts = [shortId];
    if (crop.isNotEmpty) titleParts.add(crop);
    if (weightLabel.isNotEmpty) titleParts.add(weightLabel);
    final titleLine = titleParts.join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _kFarmerGreen.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.local_shipping_outlined,
              color: _kFarmerGreen,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titleLine,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: _kTextPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: _kTextSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 9,
              vertical: 3,
            ),
            decoration: BoxDecoration(
              color: categoryColors.bg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: categoryColors.fg.withOpacity(0.55)),
            ),
            child: Text(
              categoryLabel,
              style: TextStyle(
                color: categoryColors.fg,
                fontWeight: FontWeight.w700,
                fontSize: 10.5,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyTripsPlaceholder extends StatelessWidget {
  const _EmptyTripsPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: const Row(
        children: [
          Icon(
            Icons.inbox_outlined,
            color: _kTextSecondary,
            size: 22,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'No trips yet — post your first request to get started.',
              style: TextStyle(
                fontSize: 12.5,
                color: _kTextSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Error block
// ============================================================================

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 24),
      child: Column(
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 56,
            color: theme.colorScheme.error,
          ),
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