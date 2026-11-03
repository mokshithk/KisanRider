import 'package:intl/intl.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'rider_common.dart';
import 'pools/pool_models.dart';
import 'pools/rider_pool_detail_screen.dart';

const Duration _kPollingInterval = Duration(seconds: 3);
const Duration _kPositionRefreshInterval = Duration(minutes: 5);

class RiderAvailableTab extends StatefulWidget {
  const RiderAvailableTab({super.key});

  @override
  State<RiderAvailableTab> createState() => _RiderAvailableTabState();
}

class _RiderAvailableTabState extends State<RiderAvailableTab>
    with AutomaticKeepAliveClientMixin {
  final List<AvailableRequest> _requests = [];
  final List<Pool> _pools = [];
  bool _showPools = false;

  bool _isLoading = true;
  String? _error;
  String? _acceptingId;

  Timer? _pollTimer;
  Position? _lastKnownPosition;
  DateTime? _lastPositionFetch;
  bool _permissionDenied = false;
  bool _isResolvingPosition = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _fetch();
      _startPolling();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_kPollingInterval, (_) {
      if (_acceptingId != null) return;
      _fetch(silent: true);
    });
  }

  Future<Position?> _resolveRiderPosition({bool forceRefresh = false}) async {
    if (!forceRefresh && _lastKnownPosition != null && _lastPositionFetch != null) {
      final age = DateTime.now().difference(_lastPositionFetch!);
      if (age < _kPositionRefreshInterval) return _lastKnownPosition;
    }

    if (_isResolvingPosition) return _lastKnownPosition;
    _isResolvingPosition = true;

    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        if (mounted) setState(() => _permissionDenied = true);
        return _lastKnownPosition;
      }
      if (mounted && _permissionDenied) setState(() => _permissionDenied = false);

      try {
        final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium);
        _lastKnownPosition = pos;
        _lastPositionFetch = DateTime.now();
        return pos;
      } catch (_) {
        return _lastKnownPosition;
      }
    } finally {
      _isResolvingPosition = false;
    }
  }

  Map<String, String> _headers(AuthProvider auth, {bool json = false}) {
    final h = <String, String>{
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  Future<void> _fetch({bool silent = false}) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      if (!silent) setState(() { _isLoading = false; _error = 'Not signed in.'; });
      return;
    }

    if (!silent) setState(() { _isLoading = true; _error = null; });

    final Position? position = await _resolveRiderPosition(forceRefresh: !silent);
    if (position == null) {
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _isLoading = false;
          if (!_permissionDenied) _error = 'Could not determine your location.';
        });
      }
      return;
    }

    try {
      final endpoint = _showPools ? '/pools/nearby' : '/produce-requests/nearby';
      final uri = Uri.parse('$kApiBaseUrl$endpoint').replace(
        queryParameters: {
          'lat': position.latitude.toString(),
          'lng': position.longitude.toString(),
          'radius_km': kSearchRadiusKm.toString(),
        },
      );

      final response = await http.get(uri, headers: _headers(auth));
      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> decoded = jsonDecode(response.body) as List<dynamic>;

        if (_showPools) {
          final next = decoded.whereType<Map<String, dynamic>>().map(Pool.fromJson).toList();
          next.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          setState(() {
            _pools..clear()..addAll(next);
            if (!silent) _isLoading = false;
            _error = null;
          });
        } else {
          final next = decoded.whereType<Map<String, dynamic>>().map(AvailableRequest.fromJson).toList();
          next.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          setState(() {
            _requests..clear()..addAll(next);
            if (!silent) _isLoading = false;
            _error = null;
          });
        }
      } else {
        if (!silent) {
          setState(() {
            _error = _extractError(response) ?? 'Failed to load (HTTP ${response.statusCode}).';
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      if (!silent) setState(() { _error = 'Network error: $e'; _isLoading = false; });
    }
  }

  Future<DateTime?> _promptExpectedPickup(DateTime windowStart, DateTime windowEnd) async {
    final now = DateTime.now();
    final localStart = windowStart.toLocal();
    final localEnd = windowEnd.toLocal();

    if (localEnd.isBefore(now)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This request has expired as the pickup window has ended.'),
          backgroundColor: Colors.red,
        ),
      );
      return null;
    }

    DateTime selected = now.isAfter(localStart) ? now : localStart;
    selected = DateTime(selected.year, selected.month, selected.day, selected.hour, selected.minute);
    final format = DateFormat('dd MMM, hh:mm a');

    final result = await showDialog<DateTime>(
      context: context,
      builder: (ctx) {
        DateTime currentSelection = selected;
        String? errorText;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('Set Expected Pickup Time', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Farmer\'s Pickup Window:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Text(
                      '${format.format(localStart)} — ${format.format(localEnd)}',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.green.shade900),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Your Expected Arrival:',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade800),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final pickedDate = await showDatePicker(
                              context: context,
                              initialDate: currentSelection,
                              firstDate: localStart.isBefore(now) ? localStart : now,
                              lastDate: localEnd.add(const Duration(days: 1)),
                            );
                            if (pickedDate != null) {
                              setDialogState(() {
                                currentSelection = DateTime(
                                  pickedDate.year,
                                  pickedDate.month,
                                  pickedDate.day,
                                  currentSelection.hour,
                                  currentSelection.minute,
                                );
                                errorText = null;
                              });
                            }
                          },
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text(DateFormat('dd MMM').format(currentSelection)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final pickedTime = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay.fromDateTime(currentSelection),
                            );
                            if (pickedTime != null) {
                              setDialogState(() {
                                currentSelection = DateTime(
                                  currentSelection.year,
                                  currentSelection.month,
                                  currentSelection.day,
                                  pickedTime.hour,
                                  pickedTime.minute,
                                );
                                errorText = null;
                              });
                            }
                          },
                          icon: const Icon(Icons.access_time, size: 16),
                          label: Text(DateFormat('hh:mm a').format(currentSelection)),
                        ),
                      ),
                    ],
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorText!,
                      style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: kRiderGreen),
                  onPressed: () {
                    if (currentSelection.isBefore(localStart.subtract(const Duration(seconds: 59)))) {
                      setDialogState(() {
                        errorText = 'Cannot be earlier than window start (${format.format(localStart)}).';
                      });
                      return;
                    }
                    if (currentSelection.isAfter(localEnd.add(const Duration(seconds: 59)))) {
                      setDialogState(() {
                        errorText = 'Cannot be later than window end (${format.format(localEnd)}).';
                      });
                      return;
                    }
                    Navigator.pop(ctx, currentSelection);
                  },
                  child: const Text('Confirm & Accept'),
                ),
              ],
            );
          },
        );
      },
    );

    return result;
  }

  Future<void> _accept(AvailableRequest request) async {
    final expectedPickup = await _promptExpectedPickup(request.pickupWindowStart, request.pickupWindowEnd);
    if (expectedPickup == null) return;

    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;
    setState(() => _acceptingId = request.id);

    try {
      final uri = Uri.parse('$kApiBaseUrl/trips/accept').replace(queryParameters: {'request_id': request.id});
      final payload = jsonEncode({
        'rider_expected_pickup_at': expectedPickup.toUtc().toIso8601String(),
      });
      final response = await http.post(uri, headers: _headers(auth, json: true), body: payload);

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Trip Accepted!'), backgroundColor: kRiderGreen),
        );
        setState(() {
          _requests.removeWhere((r) => r.id == request.id);
          _acceptingId = null;
        });
      } else {
        setState(() => _acceptingId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_extractError(response) ?? 'Could not accept.'), backgroundColor: Colors.red.shade700),
        );
        await _fetch();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _acceptingId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Network error: $e'), backgroundColor: Colors.red.shade700),
      );
    }
  }

  Future<void> _acceptPool(Pool pool) async {
    final expectedPickup = await _promptExpectedPickup(pool.pickupWindowStart, pool.pickupWindowEnd);
    if (expectedPickup == null) return;

    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;
    setState(() => _acceptingId = pool.id);

    try {
      final uri = Uri.parse('$kApiBaseUrl/pools/${pool.id}/accept');
      final payload = jsonEncode({
        'rider_expected_pickup_at': expectedPickup.toUtc().toIso8601String(),
      });
      final response = await http.post(uri, headers: _headers(auth, json: true), body: payload);

      if (!mounted) return;

      if (response.statusCode == 201 || response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pool Accepted!'), backgroundColor: kRiderGreen),
        );
        setState(() {
          _pools.removeWhere((p) => p.id == pool.id);
          _acceptingId = null;
        });
      } else {
        setState(() => _acceptingId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_extractError(response) ?? 'Could not accept pool.'), backgroundColor: Colors.red.shade700),
        );
        await _fetch();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _acceptingId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Network error: $e'), backgroundColor: Colors.red.shade700),
      );
    }
  }

  String? _extractError(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['detail'] != null) return body['detail'].toString();
    } catch (_) {}
    return null;
  }

  Widget _buildToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('Individual')),
          ButtonSegment(value: true, label: Text('Pooled')),
        ],
        selected: {_showPools},
        onSelectionChanged: (Set<bool> newSelection) {
          setState(() {
            _showPools = newSelection.first;
            _isLoading = true;
            _error = null;
          });
          _fetch();
        },
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: kRiderGreen,
          selectedForegroundColor: Colors.white,
          foregroundColor: kRiderGreen,
          side: BorderSide(color: kRiderGreen.withOpacity(0.4)),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    Widget body;

    if (_permissionDenied) {
      body = _LocationPermissionDeniedState(onRetry: () async => _fetch());
    } else if (_isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = ErrorView(message: _error!, onRetry: _fetch);
    } else if (_showPools ? _pools.isEmpty : _requests.isEmpty) {
      body = RefreshIndicator(
        onRefresh: _fetch,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 80),
          children: [
            Icon(
              _showPools ? Icons.groups_outlined : Icons.inbox_outlined,
              size: 72,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 16),
            Text(
              _showPools ? 'No open pools nearby' : 'No requests found nearby',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1C1B1F),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _showPools
                  ? 'There are currently no available pooled transportation requests in your area. Please check again later.'
                  : 'There are currently no available transportation requests in your area. Please check again later.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 24),
            Center(
              child: FilledButton.icon(
                onPressed: _fetch,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh'),
                style: FilledButton.styleFrom(
                  backgroundColor: kRiderGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _fetch,
        child: ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: _showPools ? _pools.length : _requests.length,
          itemBuilder: (context, index) {
            if (_showPools) {
              final p = _pools[index];
              return _PoolCard(
                pool: p,
                isAccepting: _acceptingId == p.id,
                onAccept: _acceptingId == null ? () => _acceptPool(p) : null,
              );
            } else {
              final r = _requests[index];
              return _AvailableRequestCard(
                request: r,
                isAccepting: _acceptingId == r.id,
                onAccept: _acceptingId == null ? () => _accept(r) : null,
              );
            }
          },
        ),
      );
    }

    return Column(
      children: [
        _buildToggle(),
        Expanded(child: body),
      ],
    );
  }
}

class _LocationPermissionDeniedState extends StatelessWidget {
  const _LocationPermissionDeniedState({required this.onRetry});
  final Future<void> Function() onRetry;

  Future<void> _openSettings() async {
    try {
      await Geolocator.openAppSettings();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: onRetry,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
        children: [
          Icon(Icons.location_off_outlined, size: 64, color: Colors.grey.shade500),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Location needed to show nearby requests',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: FilledButton.icon(
              onPressed: _openSettings,
              style: FilledButton.styleFrom(backgroundColor: kRiderGreen),
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('Open Settings'),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () => onRetry(),
              child: const Text('I have enabled it — retry'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AvailableRequestCard extends StatelessWidget {
  Widget _buildPickupTimeRow(AvailableRequest request) {
    final now = DateTime.now();
    final pickupTime = request.requestedPickupAt?.toLocal();
    final isUrgent = pickupTime != null && pickupTime.isAfter(now) && pickupTime.difference(now).inHours <= 3;
    final isOverdue = pickupTime != null && pickupTime.isBefore(now);

    final Color badgeColor = isOverdue
        ? Colors.red.shade700
        : (isUrgent ? Colors.orange.shade800 : kRiderGreen);

    final Color bgColor = isOverdue
        ? Colors.red.shade50
        : (isUrgent ? Colors.orange.shade50 : kRiderGreen.withOpacity(0.08));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: badgeColor.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 16, color: badgeColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              request.displayRequestedPickup,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: badgeColor,
              ),
            ),
          ),
          if (isUrgent && !isOverdue)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.orange.shade700,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'SOON',
                style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
    );
  }

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
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.blue.shade700),
                  ),
                  child: Text(
                    '${request.distanceKm.toStringAsFixed(1)} km',
                    style: TextStyle(color: Colors.blue.shade800, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            InfoRow(icon: Icons.inventory_2_outlined, label: '${request.weightKg.toStringAsFixed(0)} kg'),
            if (request.displayRequestedPickup.isNotEmpty) ...[
              const SizedBox(height: 6),
              _buildPickupTimeRow(request),
            ],
            const SizedBox(height: 6),
            InfoRow(
              icon: Icons.location_on_outlined,
              label: 'Pickup: ${request.displayPickup}',
              onNavigate: () => launchMaps(context, request.mapsQuery),
            ),
            const SizedBox(height: 6),
            InfoRow(
              icon: Icons.flag_outlined,
              label: 'Dropoff: ${dropoff.isEmpty ? "—" : dropoff}',
              onNavigate: dropoff.isEmpty ? null : () => launchMaps(context, dropoff),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onAccept,
                icon: isAccepting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check),
                label: Text(isAccepting ? 'Accepting…' : 'Accept Request'),
                style: FilledButton.styleFrom(backgroundColor: kRiderGreen, padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PoolCard extends StatelessWidget {
  final Pool pool;
  final bool isAccepting;
  final VoidCallback? onAccept;

  const _PoolCard({
    required this.pool,
    required this.isAccepting,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final start = pool.pickupWindowStart.toLocal();
    final end = pool.pickupWindowEnd.toLocal();
    final windowStr = '${start.day}/${start.month} ${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')} - '
        '${end.day}/${end.month} ${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => RiderPoolDetailScreen(poolId: pool.id),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${pool.cropType} Pool',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.green.shade700),
                    ),
                    child: Text(
                      'Pooled',
                      style: TextStyle(color: Colors.green.shade800, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              InfoRow(icon: Icons.scale, label: 'Capacity: ${pool.currentQty.toStringAsFixed(0)} / ${pool.maxQty.toStringAsFixed(0)} kg'),
              const SizedBox(height: 6),
              InfoRow(icon: Icons.storefront, label: 'To: ${pool.dropoffMandiName ?? "Unknown"}'),
              const SizedBox(height: 6),
              InfoRow(icon: Icons.access_time, label: 'Window: $windowStr'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => RiderPoolDetailScreen(poolId: pool.id),
                          ),
                        );
                      },
                      icon: const Icon(Icons.map_outlined, size: 16),
                      label: const Text('View Route'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kRiderGreen,
                        side: const BorderSide(color: kRiderGreen),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onAccept,
                      icon: isAccepting
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.check_circle_outline, size: 16),
                      label: Text(isAccepting ? 'Accepting…' : 'Accept Pool'),
                      style: FilledButton.styleFrom(backgroundColor: kRiderGreen),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
