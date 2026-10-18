import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
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

/// How often the rider's live GPS position is refreshed.
///
/// The nearby feed is a 50 km geofence around the rider's position, so a
/// stale position means the feed silently drifts away from where the
/// rider actually is. Five minutes is short enough that a rider who has
/// driven across the search radius sees a fresh feed on the next tick,
/// long enough that a stationary rider isn't burning battery on
/// continuous GPS acquisition. Manual pull-to-refresh always re-acquires,
/// regardless of this interval.
const Duration _kPositionRefreshInterval = Duration(minutes: 5);

/// Tab 0 of the rider shell: a feed of PENDING produce requests near the
/// rider's current location, each accepting → POST /trips/accept.
///
/// ## Ordering
///
/// The feed is rendered **newest first**. The backend query
/// (`crud.get_nearby_produce_requests`) orders by `created_at DESC`, and
/// this widget also re-sorts client-side after every fetch. The belt-and-
/// suspenders approach means a proxy reordering the JSON array, or an
/// older backend still sorting by distance, can't accidentally surface a
/// stale request above a fresh one.
///
/// ## Rider location
///
/// The nearby feed is served by the backend's PostGIS `ST_DWithin` query,
/// which is centered on the (lat, lng) this widget sends. That position
/// comes from the device's live GPS — resolved once on init, re-resolved
/// on every manual pull-to-refresh, and refreshed in the background every
/// [_kPositionRefreshInterval] so a rider who has driven away from their
/// starting point sees the correct slice of nearby requests. The last
/// successfully acquired position is cached in `_lastKnownPosition` and
/// reused if a subsequent acquisition fails, so a momentary GPS outage
/// doesn't blank the feed.
///
/// If the rider has denied location permission, the feed shows an
/// explanatory empty state with an "Open Settings" button rather than
/// falling back to a fixed coordinate (which would show requests from a
/// completely different part of Karnataka).
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

  /// The last GPS position successfully acquired. Used as the (lat, lng)
  /// origin for the nearby-search, and cached so a subsequent GPS failure
  /// doesn't blank the feed. Cleared only on `dispose`.
  Position? _lastKnownPosition;

  /// When [_lastKnownPosition] was last set. A silent polling tick reuses
  /// the cached position if it's fresher than [_kPositionRefreshInterval];
  /// older than that, we re-acquire. Manual pull-to-refresh always
  /// re-acquires, regardless of this timestamp.
  DateTime? _lastPositionFetch;

  /// True when the rider has refused (or permanently refused) location
  /// permission. Drives the "Enable Location" empty state; cleared once
  /// the user grants permission via the OS settings screen.
  bool _permissionDenied = false;

  /// Guard so two concurrent calls to `_resolveRiderPosition` (e.g. an
  /// initState fetch and a polling tick firing simultaneously) don't both
  /// invoke `requestPermission` / `getCurrentPosition`.
  bool _isResolvingPosition = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Provider/context is only safe after the first frame. The first fetch
    // is deliberately awaited after the position is resolved — feeding
    // the backend a stale fixed coordinate would show the wrong slice of
    // requests.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _fetch();
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
  // Rider location
  // -------------------------------------------------------------------------

  /// Resolve the rider's current position, honoring the caching and
  /// permission rules described on the class docstring.
  ///
  /// * `forceRefresh = false` (silent polling tick): reuse the cached
  ///   position if it's fresher than [_kPositionRefreshInterval].
  /// * `forceRefresh = true` (initial load, manual pull-to-refresh):
  ///   always try to re-acquire.
  ///
  /// Returns the last-known position on a transient acquisition failure
  /// (so a momentary GPS blip doesn't blank the feed). Returns `null`
  /// only if no position has *ever* been acquired and the current attempt
  /// also failed — including the permission-denied case, which also sets
  /// [_permissionDenied] so `build()` can render the enable-location
  /// empty state.
  Future<Position?> _resolveRiderPosition({bool forceRefresh = false}) async {
    // Non-forced path: reuse a fresh-enough cache.
    if (!forceRefresh &&
        _lastKnownPosition != null &&
        _lastPositionFetch != null) {
      final age = DateTime.now().difference(_lastPositionFetch!);
      if (age < _kPositionRefreshInterval) {
        return _lastKnownPosition;
      }
    }

    // Guard against concurrent resolution calls.
    if (_isResolvingPosition) {
      return _lastKnownPosition;
    }

    _isResolvingPosition = true;
    try {
      // 1. Permission.
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() => _permissionDenied = true);
        }
        return _lastKnownPosition;
      }

      // Permission granted — clear any stale denial flag so the UI
      // switches back to the normal feed once the OS-level grant lands.
      if (mounted && _permissionDenied) {
        setState(() => _permissionDenied = false);
      }

      // 2. Fix.
      try {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
        );
        _lastKnownPosition = pos;
        _lastPositionFetch = DateTime.now();
        return pos;
      } catch (_) {
        // Transient GPS failure (indoors, weak signal) — fall back to the
        // cached position if we have one, so the feed doesn't blank.
        return _lastKnownPosition;
      }
    } finally {
      _isResolvingPosition = false;
    }
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
  ///
  /// Also decides whether to re-acquire the rider's GPS position based on
  /// [silent] and the cache age — see [_resolveRiderPosition].
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

    // Resolve the rider's position — either from cache or fresh GPS.
    // Manual refresh always re-acquires; silent ticks reuse the cache
    // until it's older than [_kPositionRefreshInterval].
    final Position? position = await _resolveRiderPosition(
      forceRefresh: !silent,
    );
    if (position == null) {
      // No position, no cache. Two cases:
      //   - permission denied → the build() method renders an
      //     "Enable Location" empty state from `_permissionDenied`.
      //   - transient failure on first load → surface an error so the
      //     user can retry.
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _isLoading = false;
          if (!_permissionDenied) {
            _error = 'Could not determine your location. '
                'Please check that GPS is enabled and try again.';
          }
        });
      }
      return;
    }

    try {
      final uri = Uri.parse('$kApiBaseUrl/produce-requests/nearby').replace(
        queryParameters: {
          'lat': position.latitude.toString(),
          'lng': position.longitude.toString(),
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
            // Growable list — we sort in place on the next line.
            .toList();

        // Newest first. The backend already orders by created_at DESC,
        // but re-sorting here is cheap and defends against a proxy or
        // an older backend that still returns distance-ordered rows.
        next.sort((a, b) => b.createdAt.compareTo(a.createdAt));

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

    // Permission-denied takes precedence over the loading spinner and the
    // empty state — showing "no requests nearby" while the actual reason
    // is "we don't know where you are" would be misleading.
    if (_permissionDenied) {
      return _LocationPermissionDeniedState(
        onRetry: () async {
          // The OS-level permission may have been granted in Settings
          // since the last attempt — re-check it before showing the
          // dialog again.
          await _fetch();
        },
      );
    }

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

// ---------------------------------------------------------------------------
// Location-permission-denied empty state
// ---------------------------------------------------------------------------

/// Shown when the rider hasn't granted location permission. The nearby
/// feed is a 50 km geofence around the rider's actual position, so without
/// GPS there is nothing truthful to show — a hardcoded fallback would
/// surface requests from a different part of Karnataka.
///
/// The "Open Settings" button uses `Geolocator.openAppSettings()`, which
/// deep-links to the OS settings screen where the rider can grant
/// permission. Once they return, the Retry callback (passed by the parent)
/// re-runs the fetch, which re-checks the permission.
class _LocationPermissionDeniedState extends StatelessWidget {
  const _LocationPermissionDeniedState({required this.onRetry});

  final Future<void> Function() onRetry;

  Future<void> _openSettings() async {
    try {
      await Geolocator.openAppSettings();
    } catch (_) {
      // Some platforms (notably web) don't have an OS-level app settings
      // screen. If the deep-link fails, there's nothing more we can do
      // beyond surfacing the retry button — the browser's own permission
      // prompt is the only path.
    }
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
          Icon(
            Icons.location_off_outlined,
            size: 64,
            color: Colors.grey.shade500,
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Location needed to show nearby requests',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              'KisanRider shows pickup requests within '
              '${kSearchRadiusKm.toStringAsFixed(0)} km of you. '
              'Enable location access to see them.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: FilledButton.icon(
              onPressed: _openSettings,
              style: FilledButton.styleFrom(
                backgroundColor: kRiderGreen,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
              ),
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('Open Settings'),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () => onRetry(),
              child: const Text(
                'I have enabled it — retry',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
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
              label: '${request.weightKg.toStringAsFixed(0)} kg',
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