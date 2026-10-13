import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'rider_common.dart';

/// How often the Available tab silently re-fetches the nearby feed.
///
/// 3 seconds is short enough that a freshly-posted request appears almost
/// instantly while a rider is staring at the screen, long enough that an
/// idle tab isn't hammering the backend. The fetch is silent — the list
/// updates in place without flipping the full-screen spinner, so scroll
/// position and in-flight taps are preserved.
const Duration _kPollingInterval = Duration(seconds: 3);

/// Tab 0 of the rider shell: a feed of PENDING produce requests near the
/// rider's (mocked) location, each accepting → POST /trips/accept.
///
/// ## Auto-refresh
///
/// A [Timer.periodic] fires every [_kPollingInterval] seconds and calls
/// `_fetch(silent: true)`. The silent path skips the `isLoading` flip and
/// keeps the existing list rendered while the network call is in flight,
/// so the UI never flickers or loses scroll position. Errors on a silent
/// tick are swallowed (the previous list stays on screen) — the user
/// still sees errors the moment they pull-to-refresh or open the tab.
///
/// The timer is cancelled in [dispose] so switching tabs (the shell uses
/// an IndexedStack, so this widget stays alive) or leaving the dashboard
/// doesn't leave a stray network loop running.
class RiderAvailableTab extends StatefulWidget {
  const RiderAvailableTab({super.key});

  @override
  State<RiderAvailableTab> createState() => _RiderAvailableTabState();
}

class _RiderAvailableTabState extends State<RiderAvailableTab>
    with AutomaticKeepAliveClientMixin {
  final List<AvailableRequest> _requests = [];
  bool _isLoading = true;
  String? _error;
  String? _acceptingId;

  /// The background refresh timer. Non-null and active for the lifetime
  /// of the widget; cancelled in [dispose].
  Timer? _pollTimer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Provider/context is only safe after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetch();
      _startPolling();
    });
  }

  @override
  void dispose() {
    // Cancel BEFORE super.dispose() so no callback can fire on a dead
    // State. Without this, a tick during teardown would call setState on
    // a disposed widget and throw.
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Polling control
  // -------------------------------------------------------------------------

  /// Starts the periodic background refresh. Idempotent — calling it twice
  /// won't stack timers.
  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_kPollingInterval, (_) {
      // Skip a tick if an accept request is in flight. Otherwise the
      // silent fetch would race the accept and could briefly re-render
      // the card we're trying to remove.
      if (_acceptingId != null) return;
      _fetch(silent: true);
    });
  }

  // -------------------------------------------------------------------------
  // Networking
  // -------------------------------------------------------------------------

  Map<String, String> _headers(AuthProvider auth, {bool json = false}) {
    final h = <String, String>{
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  /// Fetches the nearby feed.
  ///
  /// [silent] = true means "background tick" — the loading spinner is NOT
  /// shown, and network/HTTP errors are swallowed (the existing list stays
  /// on screen). [silent] = false (the default) is used for the first
  /// load, pull-to-refresh, and the retry button, where the user needs
  /// visual feedback.
  Future<void> _fetch({bool silent = false}) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) {
      if (!silent) {
        setState(() {
          _isLoading = false;
          _error = 'Not signed in.';
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

    try {
      final uri = Uri.parse('$kApiBaseUrl/produce-requests/nearby').replace(
        queryParameters: {
          'lat': kRiderLat.toString(),
          'lng': kRiderLng.toString(),
          'radius_km': kSearchRadiusKm.toString(),
        },
      );

      final response = await http.get(uri, headers: _headers(auth));
      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> decoded =
            jsonDecode(response.body) as List<dynamic>;
        final next = decoded
            .whereType<Map<String, dynamic>>()
            .map(AvailableRequest.fromJson)
            .toList(growable: false);

        setState(() {
          _requests
            ..clear()
            ..addAll(next);
          // Only flip the loading flag on a non-silent fetch — silent
          // ticks leave it as-is (it's already false by then).
          if (!silent) _isLoading = false;
          // A successful tick clears any stale error banner.
          _error = null;
        });
      } else {
        if (!silent) {
          setState(() {
            _error = _extractError(response) ??
                'Failed to load requests (HTTP ${response.statusCode}).';
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _error = 'Network error: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _accept(AvailableRequest request) async {
    final auth = context.read<AuthProvider>();
    if (auth.token == null) return;

    setState(() => _acceptingId = request.id);

    try {
      final uri = Uri.parse('$kApiBaseUrl/trips/accept')
          .replace(queryParameters: {'request_id': request.id});

      final response = await http.post(uri, headers: _headers(auth));

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Trip Accepted!'),
            backgroundColor: kRiderGreen,
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
        // Re-sync with the server after a failed accept — the request may
        // have been grabbed by someone else in the meantime.
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

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _fetch);
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

// ============================================================================
// Card
// ============================================================================

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
            InfoRow(
              icon: Icons.inventory_2_outlined,
              label: '${request.crateCount} crates · '
                  '${request.weightKg.toStringAsFixed(0)} kg',
            ),
            const SizedBox(height: 6),

            // ----- Pickup -------------------------------------------------
            // Prefer the farmer-entered address; fall back to the
            // locality/district snapshot, then to raw coordinates.
            InfoRow(
              icon: Icons.location_on_outlined,
              label: 'Pickup: ${request.displayPickup}',
              onNavigate: () => launchMaps(context, request.mapsQuery),
            ),

            // ----- Landmark (only when we didn't already use it above) ---
            if (request.pickupAddress != null &&
                request.pickupAddress!.isNotEmpty &&
                request.pickupLandmark != null &&
                request.pickupLandmark!.isNotEmpty) ...[
              const SizedBox(height: 6),
              InfoRow(
                icon: Icons.signpost_outlined,
                label: 'Landmark: ${request.pickupLandmark}',
              ),
            ],

            const SizedBox(height: 6),
            InfoRow(
              icon: Icons.flag_outlined,
              label: 'Dropoff: ${dropoff.isEmpty ? "—" : dropoff}',
              onNavigate: dropoff.isEmpty
                  ? null
                  : () => launchMaps(context, dropoff),
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
                  backgroundColor: kRiderGreen,
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