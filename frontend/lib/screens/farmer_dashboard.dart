import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';

/// Base URL of the FastAPI backend.
///
/// NOTE: `127.0.0.1` only works from Flutter Desktop / Chrome on the same
/// machine. On an Android emulator the host is reachable at `10.0.2.2`, and
/// on a physical device you need your machine's LAN IP (e.g. 192.168.x.x).
/// Change this one constant when you switch targets.
const String _kApiBaseUrl = 'http://127.0.0.1:8000';

/// Rough weight estimate the backend needs but the form doesn't collect.
const double _kKgPerCrate = 25.0;

/// Mock pickup coordinates (Kolar-area) — swap for a real geolocation
/// lookup once the pickup-location UI is decided.
const double _kMockPickupLat = 13.1362;
const double _kMockPickupLng = 78.1291;

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// A single produce request as returned by
/// `GET /produce-requests/farmer/me`.
class ProduceRequestItem {
  ProduceRequestItem({
    required this.id,
    required this.cropName,
    required this.crateCount,
    required this.dropoffLocation,
    required this.status,
    this.riderName,
  });

  factory ProduceRequestItem.fromJson(Map<String, dynamic> json) {
    final trip = json['trip'] as Map<String, dynamic>?;
    final rider = trip?['rider'] as Map<String, dynamic>?;
    return ProduceRequestItem(
      id: (json['id'] ?? '').toString(),
      cropName: (json['crop_type'] ?? '') as String,
      crateCount: ((json['crate_count'] ?? 0) as num).toInt(),
      dropoffLocation: (json['dropoff_location'] ?? '') as String? ?? '',
      status: (json['status'] ?? 'PENDING') as String,
      riderName: rider?['full_name'] as String?,
    );
  }

  final String id;
  final String cropName;
  final int crateCount;
  final String dropoffLocation;
  final String status;
  final String? riderName;

  bool get hasRider => riderName != null && riderName!.isNotEmpty;
}

/// What the "+ New Request" form collects. Mapped into the API payload
/// inside [_FarmerDashboardState._submitNewRequest].
class _NewRequestFormData {
  _NewRequestFormData({
    required this.cropName,
    required this.crateCount,
    required this.dropoffLocation,
  });

  final String cropName;
  final int crateCount;
  final String dropoffLocation;
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

class FarmerDashboard extends StatefulWidget {
  const FarmerDashboard({super.key});

  @override
  State<FarmerDashboard> createState() => _FarmerDashboardState();
}

class _FarmerDashboardState extends State<FarmerDashboard> {
  static const Color _farmerGreen = Color(0xFF2E7D32);

  final List<ProduceRequestItem> _requests = [];

  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Safe to touch Provider/context only after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchRequests());
  }

  // -------------------------------------------------------------------------
  // Networking
  // -------------------------------------------------------------------------

  Map<String, String> _authHeaders(AuthProvider auth, {bool json = false}) {
    final headers = <String, String>{
      'Authorization': 'Bearer ${auth.token}',
      'Accept': 'application/json',
    };
    if (json) headers['Content-Type'] = 'application/json';
    return headers;
  }

  Future<void> _fetchRequests() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
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
        Uri.parse('$_kApiBaseUrl/produce-requests/farmer/me'),
        headers: _authHeaders(auth),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> decoded = jsonDecode(response.body) as List<dynamic>;
        setState(() {
          _requests
            ..clear()
            ..addAll(
              decoded.map(
                (e) => ProduceRequestItem.fromJson(e as Map<String, dynamic>),
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

  /// POSTs a new produce request. Returns `true` only on HTTP 201.
  /// Also refetches the list so the new row appears immediately.
  Future<bool> _submitNewRequest(_NewRequestFormData data) async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (auth.token == null) return false;

    try {
      final response = await http.post(
        Uri.parse('$_kApiBaseUrl/produce-requests/'),
        headers: _authHeaders(auth, json: true),
        body: jsonEncode({
          'crop_type': data.cropName,
          'crate_count': data.crateCount,
          'weight_kg': data.crateCount * _kKgPerCrate,
          'latitude': _kMockPickupLat,
          'longitude': _kMockPickupLng,
          'dropoff_location': data.dropoffLocation,
        }),
      );

      if (response.statusCode == 201) {
        await _fetchRequests();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// FastAPI errors come back as `{"detail": "..."}` — surface that string
  /// when present so the user sees the real reason, not just the status code.
  String? _extractError(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['detail'] != null) {
        return body['detail'].toString();
      }
    } catch (_) {
      // Body wasn't JSON; fall through.
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Sheet flow
  // -------------------------------------------------------------------------

  Future<void> _openNewRequestSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _NewRequestSheet(onSubmit: _submitNewRequest),
    );

    if (created == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Request posted.'),
          backgroundColor: _farmerGreen,
        ),
      );
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Farmer Dashboard'),
        backgroundColor: _farmerGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _fetchRequests,
          ),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () => authProvider.logout(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openNewRequestSheet,
        backgroundColor: _farmerGreen,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New Request'),
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _ErrorState(message: _error!, onRetry: _fetchRequests);
    }

    if (_requests.isEmpty) {
      return _EmptyState(onCreatePressed: _openNewRequestSheet);
    }

    return RefreshIndicator(
      onRefresh: _fetchRequests,
      color: _farmerGreen,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        itemCount: _requests.length,
        itemBuilder: (context, index) =>
            _ProduceRequestCard(request: _requests[index]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Body states
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreatePressed});

  final VoidCallback onCreatePressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: _FarmerDashboardState._farmerGreen.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.agriculture_rounded,
                size: 64,
                color: _FarmerDashboardState._farmerGreen,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No produce requests yet',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Post your first crop pickup request and a rider '
              'nearby will pick it up.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onCreatePressed,
              style: FilledButton.styleFrom(
                backgroundColor: _FarmerDashboardState._farmerGreen,
              ),
              icon: const Icon(Icons.add),
              label: const Text('Post a Request'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 56, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              'Could not load requests',
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

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

class _ProduceRequestCard extends StatelessWidget {
  const _ProduceRequestCard({required this.request});

  final ProduceRequestItem request;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    request.cropName,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                _StatusBadge(status: request.status),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(
              icon: Icons.inventory_2_outlined,
              label: '${request.crateCount} crates',
            ),
            const SizedBox(height: 6),
            _InfoRow(
              icon: Icons.flag_outlined,
              label: 'Dropoff: '
                  '${request.dropoffLocation.isEmpty ? "—" : request.dropoffLocation}',
            ),
            if (request.hasRider) ...[
              const SizedBox(height: 6),
              _InfoRow(
                icon: Icons.delivery_dining_outlined,
                label: 'Rider: ${request.riderName}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  /// Maps each backend status to its (fg, bg) pair. Unknown statuses fall
  /// back to a neutral grey chip rather than crashing the card.
  static const Map<String, (Color, Color)> _colors = {
    'PENDING': (Color(0xFFB45309), Color(0x26F59E0B)), // amber
    'ACCEPTED': (Color(0xFF1D4ED8), Color(0x261D4ED8)), // blue
    'PICKED_UP': (Color(0xFF6D28D9), Color(0x266D28D9)), // violet
    'COMPLETED': (Color(0xFF166534), Color(0x2616A34A)), // green
    'DELIVERED': (Color(0xFF166534), Color(0x2616A34A)), // green
    'CANCELLED': (Color(0xFF991B1B), Color(0x26DC2626)), // red
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
        border: Border.all(color: fg, width: 1),
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

// ---------------------------------------------------------------------------
// New-request bottom sheet
// ---------------------------------------------------------------------------

/// Bottom-sheet form. Owns its own submitting state and pops with `true`
/// on success. All networking is delegated to [onSubmit] (which lives on
/// the dashboard state so the dashboard can trigger a refetch).
class _NewRequestSheet extends StatefulWidget {
  const _NewRequestSheet({required this.onSubmit});

  final Future<bool> Function(_NewRequestFormData data) onSubmit;

  @override
  State<_NewRequestSheet> createState() => _NewRequestSheetState();
}

class _NewRequestSheetState extends State<_NewRequestSheet> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController _cropController = TextEditingController();
  final TextEditingController _crateCountController = TextEditingController();
  final TextEditingController _dropoffController = TextEditingController();

  bool _isSubmitting = false;
  String? _submitError;

  @override
  void dispose() {
    _cropController.dispose();
    _crateCountController.dispose();
    _dropoffController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _submitError = null;
    });

    final data = _NewRequestFormData(
      cropName: _cropController.text.trim(),
      crateCount: int.parse(_crateCountController.text.trim()),
      dropoffLocation: _dropoffController.text.trim(),
    );

    final ok = await widget.onSubmit(data);
    if (!mounted) return;

    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _isSubmitting = false;
        _submitError = 'Could not post request. Check the backend and retry.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Text(
                'New Produce Request',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _cropController,
                enabled: !_isSubmitting,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Crop Name',
                  hintText: 'e.g. Tomatoes',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.eco_outlined),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Crop name is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _crateCountController,
                enabled: !_isSubmitting,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Crate Count',
                  hintText: 'e.g. 25',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.inventory_2_outlined),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Crate count is required';
                  }
                  final parsed = int.tryParse(value.trim());
                  if (parsed == null || parsed <= 0) {
                    return 'Enter a valid positive number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _dropoffController,
                enabled: !_isSubmitting,
                decoration: const InputDecoration(
                  labelText: 'Destination / APMC Hub',
                  hintText: 'e.g. APMC Yard, Kolar',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.flag_outlined),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Destination is required';
                  }
                  return null;
                },
              ),
              if (_submitError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _submitError!,
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: _FarmerDashboardState._farmerGreen,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Submit Request'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}