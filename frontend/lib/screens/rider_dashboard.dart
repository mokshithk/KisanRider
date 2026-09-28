import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Brand green used across the rider UI.
const Color _kRiderGreen = Color(0xFF2E7D32);

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
// OTP submission result
// ---------------------------------------------------------------------------

enum _OtpSubmitResult { success, invalidOtp, otherError }

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
// Dashboard shell — 4-tab bottom navigation
// ---------------------------------------------------------------------------

class RiderDashboard extends StatefulWidget {
  const RiderDashboard({super.key});

  @override
  State<RiderDashboard> createState() => _RiderDashboardState();
}

class _RiderDashboardState extends State<RiderDashboard> {
  int _currentIndex = 0;

  static const List<String> _titles = [
    'Available Requests',
    'Active Trips',
    'Earnings',
    'Account',
  ];

  void _goToTab(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_currentIndex]),
        backgroundColor: _kRiderGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () => context.read<AuthProvider>().logout(),
          ),
        ],
      ),
      // IndexedStack keeps every tab's state alive across switches, so a
      // partially-loaded Available feed or an in-flight OTP dialog survives
      // a trip to Earnings and back.
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          _AvailableRequestsTab(),
          _ActiveTripsTab(),
          _EarningsTab(),
          _DriverAccountTab(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: _goToTab,
        // Fixed keeps all 4 labels visible regardless of the active tab.
        type: BottomNavigationBarType.fixed,
        selectedItemColor: _kRiderGreen,
        unselectedItemColor: Colors.grey.shade600,
        backgroundColor: Colors.white,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.list_alt),
            label: 'Available',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.local_shipping),
            label: 'Active Trips',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet),
            label: 'Earnings',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Account',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 0 — Available requests
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
            backgroundColor: _kRiderGreen,
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
                  backgroundColor: _kRiderGreen,
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
// Tab 1 — Active trips (multiple)
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
            backgroundColor: _kRiderGreen,
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

  /// Verifies the 4-digit pickup OTP against the backend.
  ///
  /// The verify endpoint targets the ProduceRequest id (not the Trip id) —
  /// `trip.produceRequest.id`. On a successful verify, the ProduceRequest's
  /// status flips to PICKED_UP on the server, but the Trip status stays
  /// ACCEPTED (they're independent state machines). Since the rider's card
  /// reads the Trip status, we follow up with a PATCH to sync the two —
  /// otherwise the card would still say "ACCEPTED" and the OTP button would
  /// keep appearing.
  ///
  /// If the PATCH fails, we still return success — the OTP was verified,
  /// which is the essential operation. The user sees the green SnackBar and
  /// the list refreshes; the card may still show ACCEPTED until the next
  /// successful status PATCH. Backend-side, folding the trip transition
  /// into the verify endpoint would remove this two-call dance entirely.
  Future<_OtpSubmitResult> _submitOtp(ActiveTrip trip, String otp) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return _OtpSubmitResult.otherError;

    try {
      final verifyResp = await http.post(
        Uri.parse(
          '$_kApiBaseUrl/produce-requests/${trip.produceRequest.id}/verify-otp',
        ),
        headers: _headers(auth, json: true),
        body: jsonEncode({'otp': otp}),
      );

      if (verifyResp.statusCode == 400) {
        return _OtpSubmitResult.invalidOtp;
      }
      if (verifyResp.statusCode != 200) {
        return _OtpSubmitResult.otherError;
      }

      // OTP verified — now sync the trip status to PICKED_UP so the card
      // reflects the handoff. Failure here is non-fatal for the OTP flow.
      try {
        await http.patch(
          Uri.parse('$_kApiBaseUrl/trips/${trip.id}/status'),
          headers: _headers(auth, json: true),
          body: jsonEncode({'status': 'PICKED_UP'}),
        );
      } catch (_) {
        // Swallowed deliberately — OTP verification already succeeded.
      }

      return _OtpSubmitResult.success;
    } catch (_) {
      return _OtpSubmitResult.otherError;
    }
  }

  Future<void> _openOtpDialog(ActiveTrip trip) async {
    final success = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _OtpDialog(
        cropName: trip.produceRequest.cropType,
        onSubmit: (otp) => _submitOtp(trip, otp),
      ),
    );

    if (!mounted) return;

    if (success == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('OTP Verified! Order marked as PICKED UP.'),
          backgroundColor: _kRiderGreen,
        ),
      );
      await _fetch();
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
            onEnterOtp: () => _openOtpDialog(trip),
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
    required this.onEnterOtp,
  });

  final ActiveTrip trip;
  final bool isUpdating;
  final void Function(String newStatus) onUpdateStatus;
  final VoidCallback onEnterOtp;

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
      // Primary action: verify the 4-digit OTP the farmer reads out. This
      // is what actually confirms the handoff on the backend.
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: isUpdating ? null : onEnterOtp,
          icon: isUpdating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.pin),
          label: const Text('Enter Pickup OTP'),
          style: FilledButton.styleFrom(
            backgroundColor: _kRiderGreen,
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
            backgroundColor: _kRiderGreen,
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
// Tab 2 — Earnings
// ---------------------------------------------------------------------------

class _EarningsTab extends StatefulWidget {
  const _EarningsTab();

  @override
  State<_EarningsTab> createState() => _EarningsTabState();
}

class _EarningsTabState extends State<_EarningsTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _settlements = [];
  bool _isLoading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  Map<String, String> _headers(AuthProvider auth) {
    return {
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
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
      // Payout history for this rider, newest first. The endpoint already
      // exists — the Earnings tab is a thin view over it. No new backend
      // work required.
      final response = await http.get(
        Uri.parse('$_kApiBaseUrl/settlements/me'),
        headers: _headers(auth),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> decoded = jsonDecode(response.body) as List<dynamic>;
        setState(() {
          _settlements = decoded
              .whereType<Map<String, dynamic>>()
              .toList(growable: false);
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = _extractError(response) ??
              'Failed to load earnings (HTTP ${response.statusCode}).';
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

  String? _extractError(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['detail'] != null) {
        return body['detail'].toString();
      }
    } catch (_) {}
    return null;
  }

  /// Sum of total_payout for settlements created today (local time).
  /// Falls back to 0.0 if timestamps are malformed.
  double get _todayEarnings {
    final now = DateTime.now();
    double sum = 0;
    for (final s in _settlements) {
      final raw = s['created_at'];
      if (raw is String) {
        final parsed = DateTime.tryParse(raw);
        if (parsed != null &&
            parsed.year == now.year &&
            parsed.month == now.month &&
            parsed.day == now.day) {
          sum += ((s['total_payout'] ?? 0) as num).toDouble();
        }
      }
    }
    return sum;
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

    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: _fetch,
      color: _kRiderGreen,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          // ----- Today's earnings header -------------------------------
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _kRiderGreen.withOpacity(0.15),
                  _kRiderGreen.withOpacity(0.05),
                ],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _kRiderGreen.withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.account_balance_wallet,
                        color: _kRiderGreen, size: 22),
                    const SizedBox(width: 8),
                    Text(
                      'Today\'s Earnings',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: _kRiderGreen,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '₹${_todayEarnings.toStringAsFixed(0)}',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _kRiderGreen,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_settlements.length} completed trip'
                  '${_settlements.length == 1 ? "" : "s"}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ----- Section title -----------------------------------------
          Text(
            'Recent Trip History',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),

          // ----- List or empty state -----------------------------------
          if (_settlements.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withOpacity(0.4),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                children: [
                  Icon(Icons.receipt_long_outlined,
                      size: 56, color: Colors.grey.shade400),
                  const SizedBox(height: 12),
                  Text(
                    'No completed trips yet',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Completed deliveries will appear here '
                    'along with their payout amounts.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          else
            ..._settlements.map((s) => _SettlementTile(settlement: s)),
        ],
      ),
    );
  }
}

class _SettlementTile extends StatelessWidget {
  const _SettlementTile({required this.settlement});

  final Map<String, dynamic> settlement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final payout =
        ((settlement['total_payout'] ?? 0) as num).toDouble();
    final status = (settlement['status'] ?? 'PENDING').toString();

    DateTime? created;
    final raw = settlement['created_at'];
    if (raw is String) created = DateTime.tryParse(raw);

    final dateLabel = created == null
        ? '—'
        : '${created.day.toString().padLeft(2, '0')}/'
            '${created.month.toString().padLeft(2, '0')}/'
            '${created.year} '
            '${created.hour.toString().padLeft(2, '0')}:'
            '${created.minute.toString().padLeft(2, '0')}';

    final isPaid = status.toUpperCase() == 'PAID';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _kRiderGreen.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.currency_rupee,
                color: _kRiderGreen, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '₹${payout.toStringAsFixed(0)}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  dateLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: isPaid
                  ? _kRiderGreen.withOpacity(0.12)
                  : Colors.amber.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isPaid ? _kRiderGreen : Colors.amber.shade800,
              ),
            ),
            child: Text(
              status.toUpperCase(),
              style: TextStyle(
                color: isPaid ? _kRiderGreen : Colors.amber.shade900,
                fontWeight: FontWeight.bold,
                fontSize: 10,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 3 — Account
// ---------------------------------------------------------------------------

class _DriverAccountTab extends StatefulWidget {
  const _DriverAccountTab();

  @override
  State<_DriverAccountTab> createState() => _DriverAccountTabState();
}

class _DriverAccountTabState extends State<_DriverAccountTab>
    with AutomaticKeepAliveClientMixin {
  /// Local-only online/offline flag. Flip it and the card subtitle changes,
  /// but nothing else happens yet — hook it up to a backend "rider
  /// availability" endpoint when that exists, and gate /trips/accept on it.
  bool _isOnline = false;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final auth = context.read<AuthProvider>();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ----- Profile header ----------------------------------------
            //
            // NOTE: /users/me doesn't exist on the backend yet, so the name
            // and phone are placeholders. When that endpoint lands, fetch
            // here and setState. `auth.userId` is available today if you
            // want a non-name identifier in the meantime.
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    _kRiderGreen.withOpacity(0.12),
                    _kRiderGreen.withOpacity(0.04),
                  ],
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: _kRiderGreen.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: _kRiderGreen, width: 2),
                    ),
                    child: const Icon(Icons.person,
                        size: 36, color: _kRiderGreen),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Rider',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.star,
                                size: 14, color: Colors.amber),
                            const SizedBox(width: 4),
                            Text(
                              '4.8',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Icon(Icons.phone,
                                size: 13,
                                color: theme.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                '—',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Signed in as RIDER',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ----- Online / Offline toggle -------------------------------
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: (_isOnline ? _kRiderGreen : Colors.grey)
                          .withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _isOnline ? Icons.wifi_tethering : Icons.wifi_tethering_off,
                      color: _isOnline ? _kRiderGreen : Colors.grey.shade700,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isOnline ? 'Online' : 'Offline',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: _isOnline
                                ? _kRiderGreen
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _isOnline
                              ? 'You will receive new trip requests'
                              : 'You will not receive new requests',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _isOnline,
                    activeColor: _kRiderGreen,
                    onChanged: (v) => setState(() => _isOnline = v),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ----- Vehicle details ---------------------------------------
            Container(
              padding: const EdgeInsets.all(16),
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
                      const Icon(Icons.two_wheeler,
                          color: _kRiderGreen, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Vehicle Details',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const _DetailRow(label: 'Model', value: '—'),
                  const SizedBox(height: 8),
                  const _DetailRow(label: 'Registration Number', value: '—'),
                  const SizedBox(height: 8),
                  const _DetailRow(
                      label: 'Max Payload Capacity', value: '—'),
                  const SizedBox(height: 12),
                  Text(
                    'Vehicle details coming soon. Contact support to update '
                    'your vehicle information.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ----- Logout -------------------------------------------------
            OutlinedButton.icon(
              onPressed: () => auth.logout(),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade700,
                side: BorderSide(color: Colors.red.shade300),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.logout),
              label: const Text('Log Out'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 4,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          flex: 6,
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// OTP verification dialog
// ---------------------------------------------------------------------------

class _OtpDialog extends StatefulWidget {
  const _OtpDialog({
    required this.cropName,
    required this.onSubmit,
  });

  final String cropName;

  /// Performs the actual network calls. Returns a result the dialog uses
  /// to decide whether to close (success) or show an inline error and let
  /// the rider retry without losing the dialog.
  final Future<_OtpSubmitResult> Function(String otp) onSubmit;

  @override
  State<_OtpDialog> createState() => _OtpDialogState();
}

class _OtpDialogState extends State<_OtpDialog> {
  final _formKey = GlobalKey<FormState>();
  final _controller = TextEditingController();
  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    final result = await widget.onSubmit(_controller.text.trim());
    if (!mounted) return;

    if (result == _OtpSubmitResult.success) {
      Navigator.of(context).pop(true);
      return;
    }

    setState(() {
      _isSubmitting = false;
      _error = result == _OtpSubmitResult.invalidOtp
          ? 'Invalid OTP. Please check with the farmer.'
          : 'Could not verify OTP. Please try again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter Pickup OTP'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Ask the farmer for the 4-digit code shown on their screen.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _controller,
              enabled: !_isSubmitting,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 26,
                letterSpacing: 8,
                fontWeight: FontWeight.bold,
              ),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                counterText: '',
                hintText: '••••',
              ),
              validator: (v) {
                final value = (v ?? '').trim();
                if (value.isEmpty) return 'Enter the OTP';
                if (value.length != 4) return 'OTP must be 4 digits';
                return null;
              },
              onFieldSubmitted: (_) {
                if (!_isSubmitting) _submit();
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isSubmitting ? null : _submit,
          icon: _isSubmitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.check, size: 18),
          label: Text(_isSubmitting ? 'Verifying…' : 'Verify & Pick Up'),
          style: FilledButton.styleFrom(
            backgroundColor: _kRiderGreen,
          ),
        ),
      ],
    );
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