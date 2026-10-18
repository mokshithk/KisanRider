import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'order_detail_screen.dart';

/// Base URL of the FastAPI backend.
String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

const Color _kFarmerGreen = Color(0xFF2E7D32);

/// Polling cadence while at least one order is PENDING.
const Duration _kPollingInterval = Duration(seconds: 5);

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

class FarmerOrder {
  FarmerOrder({
    required this.id,
    required this.cropType,
    required this.weightKg,
    required this.status,
    required this.createdAt,
    this.dropoffLocation,
    this.dropoffDistrict,
    this.dropoffMandiName,
    this.dropoffStallNumber,
  });

  factory FarmerOrder.fromJson(Map<String, dynamic> json) {
    DateTime parsedCreatedAt;
    final rawCreated = json['created_at'];
    if (rawCreated is String) {
      parsedCreatedAt = DateTime.tryParse(rawCreated) ??
          DateTime.fromMillisecondsSinceEpoch(0);
    } else {
      parsedCreatedAt = DateTime.fromMillisecondsSinceEpoch(0);
    }

    return FarmerOrder(
      id: (json['id'] ?? '').toString(),
      cropType: (json['crop_type'] ?? '') as String,
      weightKg: ((json['weight_kg'] ?? 0) as num).toDouble(),
      status: (json['status'] ?? 'PENDING') as String,
      createdAt: parsedCreatedAt,
      dropoffLocation: json['dropoff_location'] as String?,
      dropoffDistrict: json['dropoff_district']?.toString(),
      dropoffMandiName: json['dropoff_mandi_name']?.toString(),
      dropoffStallNumber: json['dropoff_stall_number']?.toString(),
    );
  }

  final String id;
  final String cropType;
  final double weightKg;
  final String status;
  final DateTime createdAt;

  /// Legacy composite dropoff string ("MandiName - Stall"). Used as the
  /// last-resort fallback when structured fields are missing.
  final String? dropoffLocation;

  final String? dropoffDistrict;
  final String? dropoffMandiName;
  final String? dropoffStallNumber;

  bool get isPending => status == 'PENDING';

  /// Normalised tag for filter chips:
  ///   - 'pending'   -> only PENDING
  ///   - 'accepted'  -> ACCEPTED / PICKED_UP / IN_TRANSIT
  ///   - 'completed' -> COMPLETED
  ///   - 'other'     -> CANCELLED etc.
  String get filterTag {
    final s = status.toUpperCase();
    if (s == 'PENDING') return 'pending';
    if (s == 'ACCEPTED' || s == 'PICKED_UP' || s == 'IN_TRANSIT') {
      return 'accepted';
    }
    if (s == 'COMPLETED' || s == 'DELIVERED') return 'completed';
    return 'other';
  }

  /// Human-readable dropoff line for the card. Prefers the structured
  /// mandi + stall, falls back to the legacy composite string.
  String get dropoffDisplay {
    final mandi = (dropoffMandiName ?? '').trim();
    if (mandi.isNotEmpty) {
      final stall = (dropoffStallNumber ?? '').trim();
      return stall.isEmpty ? mandi : '$mandi - $stall';
    }
    final legacy = (dropoffLocation ?? '').trim();
    if (legacy.isNotEmpty) return legacy;
    return '—';
  }

  /// Short display reference — e.g. `#KR-8021`.
  String get shortRef {
    final compact = id.replaceAll('-', '');
    final take = compact.length >= 6 ? compact.substring(0, 6) : compact;
    return '#KR-${take.toUpperCase()}';
  }
}

// ---------------------------------------------------------------------------
// Tab
// ---------------------------------------------------------------------------

class FarmerOrdersTab extends StatefulWidget {
  const FarmerOrdersTab({
    super.key,
    required this.onBookTransport,
  });

  final VoidCallback onBookTransport;

  @override
  State<FarmerOrdersTab> createState() => _FarmerOrdersTabState();
}

class _FarmerOrdersTabState extends State<FarmerOrdersTab> {
  List<FarmerOrder> myRequests = [];
  bool isLoading = true;
  String? _error;

  /// Active filter chip. Index 0 = All (default).
  int _activeFilterIndex = 0;

  Timer? _pollTimer;

  /// Chip definitions. `tag == null` means "all".
  static const List<({String label, String? tag})> _filters = [
    (label: 'All', tag: null),
    (label: 'Pending', tag: 'pending'),
    (label: 'Accepted', tag: 'accepted'),
    (label: 'Completed', tag: 'completed'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchOrders());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }

  Map<String, String> _headers(AuthProvider auth) {
    return {
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
  }

  void _syncPolling() {
    final hasPending = myRequests.any((o) => o.isPending);

    if (hasPending && (_pollTimer == null || !_pollTimer!.isActive)) {
      _pollTimer = Timer.periodic(_kPollingInterval, (_) {
        _fetchOrders(silent: true);
      });
    } else if (!hasPending && _pollTimer != null) {
      _pollTimer!.cancel();
      _pollTimer = null;
    }
  }

  Future<void> _fetchOrders({bool silent = false}) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      if (!silent) {
        setState(() {
          isLoading = false;
          _error = 'Not signed in.';
        });
      }
      return;
    }

    if (!silent) {
      setState(() {
        isLoading = true;
        _error = null;
      });
    }

    try {
      final response = await http.get(
        Uri.parse('$_kApiBaseUrl/produce-requests/farmer/me'),
        headers: _headers(auth),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> decoded =
            jsonDecode(response.body) as List<dynamic>;

        final parsed = decoded
            .whereType<Map<String, dynamic>>()
            .map(FarmerOrder.fromJson)
            .toList();

        parsed.sort((a, b) => b.createdAt.compareTo(a.createdAt));

        setState(() {
          myRequests = parsed;
          isLoading = false;
          _error = null;
        });

        _syncPolling();
      } else {
        if (!silent) {
          setState(() {
            _error = _extractError(response) ??
                'Failed to load orders (HTTP ${response.statusCode}).';
            isLoading = false;
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _error = 'Network error: $e';
          isLoading = false;
        });
      }
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

  /// Visible list after applying the active filter chip.
  List<FarmerOrder> get _filteredOrders {
    final tag = _filters[_activeFilterIndex].tag;
    if (tag == null) return myRequests;
    return myRequests.where((o) => o.filterTag == tag).toList();
  }

  Future<void> _openDetail(FarmerOrder order) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => OrderDetailScreen(orderId: order.id),
      ),
    );
    if (changed == true && mounted) {
      await _fetchOrders(silent: true);
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildFilterBar(),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildFilterBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: List.generate(_filters.length, (i) {
            final selected = i == _activeFilterIndex;
            return Padding(
              padding: EdgeInsets.only(
                right: i == _filters.length - 1 ? 0 : 8,
              ),
              child: ChoiceChip(
                label: Text(
                  _filters[i].label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : _kFarmerGreen,
                  ),
                ),
                selected: selected,
                onSelected: (_) =>
                    setState(() => _activeFilterIndex = i),
                selectedColor: _kFarmerGreen,
                backgroundColor: Colors.white,
                side: BorderSide(
                  color: _kFarmerGreen.withOpacity(
                    selected ? 0.0 : 0.4,
                  ),
                ),
                showCheckmark: false,
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _OrdersErrorState(message: _error!, onRetry: _fetchOrders);
    }

    if (myRequests.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetchOrders,
        color: _kFarmerGreen,
        child: _OrdersEmptyState(onBookTransport: widget.onBookTransport),
      );
    }

    final visible = _filteredOrders;

    if (visible.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetchOrders,
        color: _kFarmerGreen,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding:
              const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
          children: [
            Icon(
              Icons.filter_alt_off_outlined,
              size: 56,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                'No orders match this filter.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade700,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchOrders,
      color: _kFarmerGreen,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final order = visible[index];
          return _OrderCard(
            order: order,
            onTap: () => _openDetail(order),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Order card — three-line minimal design
// ---------------------------------------------------------------------------

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.onTap});

  final FarmerOrder order;
  final VoidCallback onTap;

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatDate(DateTime d) {
    final local = d.toLocal();
    return '${_months[local.month - 1]} ${local.day}, ${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ----- Line 1: crop · weight  |  status badge -----------
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '${order.cropType} · ${order.weightKg.toStringAsFixed(0)} kg',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusChip(status: order.status),
                ],
              ),
              const SizedBox(height: 8),

              // ----- Line 2: dropoff ---------------------------------
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.flag_outlined,
                    size: 15,
                    color: Color(0xFF6B7280),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Dropoff: ${order.dropoffDisplay}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF1C1B1F),
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),

              // ----- Line 3: reference · date -------------------------
              Text(
                '${order.shortRef} · ${_formatDate(order.createdAt)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 12,
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

// ---------------------------------------------------------------------------
// Status badge
// ---------------------------------------------------------------------------

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  static const Map<String, (Color, Color)> _colors = {
    'PENDING': (Color(0xFFB45309), Color(0x26F59E0B)),
    'ACCEPTED': (Color(0xFF1D4ED8), Color(0x261D4ED8)),
    'PICKED_UP': (Color(0xFF6D28D9), Color(0x266D28D9)),
    'IN_TRANSIT': (Color(0xFF6D28D9), Color(0x266D28D9)),
    'DELIVERED': (Color(0xFF166534), Color(0x2616A34A)),
    'COMPLETED': (Color(0xFF166534), Color(0x2616A34A)),
    'CANCELLED': (Color(0xFF991B1B), Color(0x26DC2626)),
  };

  @override
  Widget build(BuildContext context) {
    final (fg, bg) =
        _colors[status.toUpperCase()] ?? (Colors.black54, Colors.black12);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.bold,
          fontSize: 10.5,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty & error states
// ---------------------------------------------------------------------------

class _OrdersEmptyState extends StatelessWidget {
  const _OrdersEmptyState({required this.onBookTransport});

  final VoidCallback onBookTransport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: _kFarmerGreen.withOpacity(0.08),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.local_shipping_outlined,
            size: 64,
            color: _kFarmerGreen,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'No active shipments found.',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Book transport to get started!',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: onBookTransport,
          style: FilledButton.styleFrom(
            backgroundColor: _kFarmerGreen,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          icon: const Icon(Icons.add),
          label: const Text('Book Transport'),
        ),
      ],
    );
  }
}

class _OrdersErrorState extends StatelessWidget {
  const _OrdersErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 56, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              'Could not load orders',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
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
      ),
    );
  }
}