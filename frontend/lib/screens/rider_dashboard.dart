import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/auth_provider.dart';

/// Base URL of the FastAPI backend.
///
/// NOTE: `127.0.0.1` only works from Flutter Desktop / Chrome on the same
/// machine. On an Android emulator use `10.0.2.2`, on a physical device use
/// your machine's LAN IP.
const String _kApiBaseUrl = 'http://127.0.0.1:8000';

/// Rider's current position — used as the center point for the nearby search.
/// Mocked for MVP; swap for a real geolocation lookup later.
const double _kRiderLat = 13.1362;
const double _kRiderLng = 78.1291;
const double _kSearchRadiusKm = 50.0;

// ---------------------------------------------------------------------------
// Google Maps helper
// ---------------------------------------------------------------------------

/// Opens Google Maps in the platform's external app, searching for [query].
///
/// [query] can be either a `"lat,lng"` string or a free-text address — the
/// Maps search endpoint accepts both. Shows a SnackBar if the platform
/// refuses to launch (no Maps app, no browser, etc.).
Future<void> _launchMaps(BuildContext context, String query) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return;

  final Uri url = Uri.parse(
    'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(trimmed)}',
  );

  try {
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Google Maps')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Google Maps')),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// One PENDING produce request surfaced by `GET /produce-requests/nearby`.
class AvailableRequest {
  AvailableRequest({
    required this.id,
    required this.cropType,
    required this.crateCount,
    required this.weightKg,
    required this.latitude,
    required this.longitude,
    required this.distanceKm,
    required this.status,
    this.dropoffLocation,
  });

  factory AvailableRequest.fromJson(Map<String, dynamic> json) {
    return AvailableRequest(
      id: (json['id'] ?? '').toString(),
      cropType: (json['crop_type'] ?? '') as String,
      crateCount: ((json['crate_count'] ?? 0) as num).toInt(),
      weightKg: ((json['weight_kg'] ?? 0) as num).toDouble(),
      latitude: ((json['latitude'] ?? 0) as num).toDouble(),
      longitude: ((json['longitude'] ?? 0) as num).toDouble(),
      distanceKm: ((json['distance_km'] ?? 0) as num).toDouble(),
      status: (json['status'] ?? 'PENDING') as String,
      dropoffLocation: json['dropoff_location'] as String?,
    );
  }

  final String id;
  final String cropType;
  final int crateCount;
  final double weightKg;
  final double latitude;
  final double longitude;
  final double distanceKm;
  final String status;
  final String? dropoffLocation;
}

/// Embedded produce-request info inside an active trip response.
class ActiveTripProduceRequest {
  ActiveTripProduceRequest({
    required this.id,
    required this.cropType,
    required this.crateCount,
    required this.weightKg,
    required this.latitude,
    required this.longitude,
    required this.status,
    this.dropoffLocation,
  });

  factory ActiveTripProduceRequest.fromJson(Map<String, dynamic> json) {
    return ActiveTripProduceRequest(
      id: (json['id'] ?? '').toString(),
      cropType: (json['crop_type'] ?? '') as String,
      crateCount: ((json['crate_count'] ?? 0) as num).toInt(),
      weightKg: ((json['weight_kg'] ?? 0) as num).toDouble(),
      latitude: ((json['latitude'] ?? 0) as num).toDouble(),
      longitude: ((json['longitude'] ?? 0) as num).toDouble(),
      status: (json['status'] ?? '') as String,
      dropoffLocation: json['dropoff_location'] as String?,
    );
  }

  final String id;
  final String cropType;
  final int crateCount;
  final double weightKg;
  final double latitude;
  final double longitude;
  final String status;
  final String? dropoffLocation;
}

/// One of the rider's active trips, from `GET /trips/active`.
class ActiveTrip {
  ActiveTrip({
    required this.id,
    required this.status,
    required this.produceRequest,
  });

  factory ActiveTrip.fromJson(Map<String, dynamic> json) {
    return ActiveTrip(
      id: (json['id'] ?? '').toString(),
      status: (json['status'] ?? '') as String,
      produceRequest: ActiveTripProduceRequest.fromJson(
        json['produce_request'] as Map<String, dynamic>,
      ),
    );
  }

  final String id;
  final String status;
  final ActiveTripProduceRequest produceRequest;
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

class RiderDashboard extends StatelessWidget {
  const RiderDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Rider Dashboard'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.list_alt), text: 'Available'),
              Tab(icon: Icon(Icons.delivery_dining), text: 'Active Trips'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Logout',
              icon: const Icon(Icons.logout),
              onPressed: () => context.read<AuthProvider>().logout(),
            ),
          ],
        ),
        body: const TabBarView(
          children: [
            _AvailableRequestsTab(),
            _ActiveTripsTab(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 1 — Available requests
// ---------------------------------------------------------------------------

class _AvailableRequestsTab extends StatefulWidget {
  const _AvailableRequestsTab();

  @override
  State<_AvailableRequestsTab> createState() => _AvailableRequestsTabState();
}

class _AvailableRequestsTabState extends State<_AvailableRequestsTab>
    with AutomaticKeepAliveClientMixin {
  final List<AvailableRequest> _requests = [];
  bool _isLoading = true;
  String? _error;
  String? _acceptingId;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  Map<String, String> _headers(AuthProvider auth, {bool json = false}) {
    final h = <String, String>{
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  Future<void> _fetch() async {
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
      final uri = Uri.parse('$_kApiBaseUrl/produce-requests/nearby').replace(
        queryParameters: {
          'lat': _kRiderLat.toString(),
          'lng': _kRiderLng.toString(),
          'radius_km': _kSearchRadiusKm.toString(),
        },
      );

      final response = await http.get(uri, headers: _headers(auth));
      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> decoded = jsonDecode(response.body) as List<dynamic>;
        setState(() {
          _requests
            ..clear()
            ..addAll(
              decoded.map(
                (e) => AvailableRequest.fromJson(e as Map<String, dynamic>),
              ),
            );
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = _extractError(response) ??
              'Failed to load requests (HTTP ${response.statusCode}).';
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

  Future<void> _accept(AvailableRequest request) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;

    setState(() => _acceptingId = request.id);

    try {
      final uri = Uri.parse('$_kApiBaseUrl/trips/accept')
          .replace(queryParameters: {'request_id': request.id});

      final response = await http.post(uri, headers: _headers(auth));

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Trip Accepted!'),
            backgroundColor: Color(0xFF2E7D32),
          ),
        );
        setState(() {
          _requests.removeWhere((r) => r.id == request.id);
          _acceptingId = null;
        });
      } else {
        setState(() => _acceptingId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _extractError(response) ??
                  'Could not accept (HTTP ${response.statusCode}).',
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
        await _fetch();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _acceptingId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Network error: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
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
    super.build(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _fetch);
    }

    if (_requests.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetch,
        child: ListView(
          children: const [
            SizedBox(height: 160),
            Icon(Icons.inbox_outlined, size: 64, color: Colors.black26),
            SizedBox(height: 12),
            Center(
              child: Text(
                'No pickup requests nearby right now.',
                style: TextStyle(fontSize: 15, color: Colors.black54),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _requests.length,
        itemBuilder: (context, index) {
          final r = _requests[index];
          return _AvailableRequestCard(
            request: r,
            isAccepting: _acceptingId == r.id,
            onAccept: _acceptingId == null ? () => _accept(r) : null,
          );
        },
      ),
    );
  }
}

class _AvailableRequestCard extends StatelessWidget {
  const _AvailableRequestCard({
    required this.request,
    required this.isAccepting,
    required this.onAccept,
  });

  final AvailableRequest request;
  final bool isAccepting;
  final VoidCallback? onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dropoff = request.dropoffLocation ?? '';

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    request.cropType,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.blue.shade700),
                  ),
                  child: Text(
                    '${request.distanceKm.toStringAsFixed(1)} km',
                    style: TextStyle(
                      color: Colors.blue.shade800,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(
              icon: Icons.inventory_2_outlined,
              label: '${request.crateCount} crates · '
                  '${request.weightKg.toStringAsFixed(0)} kg',
            ),
            const SizedBox(height: 6),
            _InfoRow(
              icon: Icons.location_on_outlined,
              label: 'Pickup: '
                  '${request.latitude.toStringAsFixed(4)}, '
                  '${request.longitude.toStringAsFixed(4)}',
              onNavigate: () => _launchMaps(
                context,
                '${request.latitude},${request.longitude}',
              ),
            ),
            const SizedBox(height: 6),
            _InfoRow(
              icon: Icons.flag_outlined,
              label: 'Dropoff: ${dropoff.isEmpty ? "—" : dropoff}',
              onNavigate: dropoff.isEmpty
                  ? null
                  : () => _launchMaps(context, dropoff),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onAccept,
                icon: isAccepting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check),
                label: Text(isAccepting ? 'Accepting…' : 'Accept Request'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 2 — Active trips (multiple)
// ---------------------------------------------------------------------------

class _ActiveTripsTab extends StatefulWidget {
  const _ActiveTripsTab();

  @override
  State<_ActiveTripsTab> createState() => _ActiveTripsTabState();
}

class _ActiveTripsTabState extends State<_ActiveTripsTab>
    with AutomaticKeepAliveClientMixin {
  final List<ActiveTrip> _trips = [];

  /// IDs of trips with an in-flight status update, so each card can show its
  /// own spinner without blocking the others.
  final Set<String> _updatingTripIds = {};

  bool _isLoading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  Map<String, String> _headers(AuthProvider auth, {bool json = false}) {
    final h = <String, String>{
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  Future<void> _fetch() async {
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
      final response = await http.get(
        Uri.parse('$_kApiBaseUrl/trips/active'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);

        // Defensive: the endpoint currently returns a single object. When it
        // is upgraded to return a list, this branch keeps working without a
        // client change.
        final List<dynamic> items;
        if (decoded is List) {
          items = decoded;
        } else if (decoded is Map<String, dynamic>) {
          items = [decoded];
        } else {
          items = const [];
        }

        setState(() {
          _trips
            ..clear()
            ..addAll(
              items.map((e) => ActiveTrip.fromJson(e as Map<String, dynamic>)),
            );
          _isLoading = false;
        });
      } else if (response.statusCode == 404) {
        setState(() {
          _trips.clear();
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = _extractError(response) ??
              'Failed to load active trips (HTTP ${response.statusCode}).';
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

  Future<void> _updateStatus(ActiveTrip trip, String newStatus) async {
    if (_updatingTripIds.contains(trip.id)) return;

    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;

    setState(() => _updatingTripIds.add(trip.id));

    try {
      final response = await http.patch(
        Uri.parse('$_kApiBaseUrl/trips/${trip.id}/status'),
        headers: _headers(auth, json: true),
        body: jsonEncode({'status': newStatus}),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${trip.produceRequest.cropType} → $newStatus'),
            backgroundColor: const Color(0xFF2E7D32),
          ),
        );
        await _fetch();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _extractError(response) ??
                  'Update failed (HTTP ${response.statusCode}).',
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Network error: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _updatingTripIds.remove(trip.id));
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
    super.build(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _fetch);
    }

    if (_trips.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetch,
        child: ListView(
          children: const [
            SizedBox(height: 160),
            Icon(Icons.delivery_dining_outlined,
                size: 64, color: Colors.black26),
            SizedBox(height: 12),
            Center(
              child: Text(
                'No active trips. Accept a request to get started.',
                style: TextStyle(fontSize: 15, color: Colors.black54),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _trips.length,
        itemBuilder: (context, index) {
          final trip = _trips[index];
          return _ActiveTripCard(
            trip: trip,
            isUpdating: _updatingTripIds.contains(trip.id),
            onUpdateStatus: (newStatus) => _updateStatus(trip, newStatus),
          );
        },
      ),
    );
  }
}

class _ActiveTripCard extends StatelessWidget {
  const _ActiveTripCard({
    required this.trip,
    required this.isUpdating,
    required this.onUpdateStatus,
  });

  final ActiveTrip trip;
  final bool isUpdating;
  final void Function(String newStatus) onUpdateStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pr = trip.produceRequest;
    final dropoff = pr.dropoffLocation ?? '';

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    pr.cropType,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                _StatusBadge(status: trip.status),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(
              icon: Icons.inventory_2_outlined,
              label: '${pr.crateCount} crates · '
                  '${pr.weightKg.toStringAsFixed(0)} kg',
            ),
            const SizedBox(height: 6),
            _InfoRow(
              icon: Icons.location_on_outlined,
              label: 'Pickup: '
                  '${pr.latitude.toStringAsFixed(4)}, '
                  '${pr.longitude.toStringAsFixed(4)}',
              onNavigate: () => _launchMaps(
                context,
                '${pr.latitude},${pr.longitude}',
              ),
            ),
            const SizedBox(height: 6),
            _InfoRow(
              icon: Icons.flag_outlined,
              label: 'Dropoff: ${dropoff.isEmpty ? "—" : dropoff}',
              onNavigate: dropoff.isEmpty
                  ? null
                  : () => _launchMaps(context, dropoff),
            ),
            const SizedBox(height: 16),
            _buildActionButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton() {
    if (trip.status == 'ACCEPTED') {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: isUpdating ? null : () => onUpdateStatus('PICKED_UP'),
          icon: isUpdating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.inventory_2),
          label: Text(isUpdating ? 'Updating…' : 'Mark Picked Up'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      );
    }

    if (trip.status == 'PICKED_UP') {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: isUpdating ? null : () => onUpdateStatus('DELIVERED'),
          icon: isUpdating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.check_circle_outline),
          label: Text(isUpdating ? 'Updating…' : 'Mark Delivered'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF2E7D32),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      );
    }

    // Terminal state (shouldn't normally appear here — the endpoint filters
    // to ACCEPTED/PICKED_UP — but render something sane if it does).
    return const SizedBox.shrink();
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

/// One line of info (icon + label). If [onNavigate] is provided, a small
/// "Navigate" button is rendered at the trailing end that opens Google Maps.
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    this.onNavigate,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onNavigate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
        if (onNavigate != null)
          IconButton(
            icon: const Icon(Icons.navigation_outlined),
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            tooltip: 'Navigate',
            color: theme.colorScheme.primary,
            onPressed: onNavigate,
          ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  static const Map<String, (Color, Color)> _colors = {
    'PENDING': (Color(0xFFB45309), Color(0x26F59E0B)),
    'ACCEPTED': (Color(0xFF1D4ED8), Color(0x261D4ED8)),
    'PICKED_UP': (Color(0xFF6D28D9), Color(0x266D28D9)),
    'COMPLETED': (Color(0xFF166534), Color(0x2616A34A)),
    'DELIVERED': (Color(0xFF166534), Color(0x2616A34A)),
    'CANCELLED': (Color(0xFF991B1B), Color(0x26DC2626)),
  };

  @override
  Widget build(BuildContext context) {
    final (fg, bg) =
        _colors[status.toUpperCase()] ?? (Colors.black54, Colors.black12);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
          fontSize: 12,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

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
      ),
    );
  }
}