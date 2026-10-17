import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';

/// Base URL of the FastAPI backend.
///
/// - Web/Chrome uses `localhost`.
/// - Physical Android/iOS devices use your laptop's Wi-Fi IP.
String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

// ---------------------------------------------------------------------------
// Design tokens (kept local so this file has no cross-file coupling)
// ---------------------------------------------------------------------------

const Color _kFarmerGreen = Color(0xFF2E7D32);
const Color _kBackground = Color(0xFFF8F9FA);
const Color _kTextPrimary = Color(0xFF1C1B1F);
const Color _kTextSecondary = Color(0xFF6B7280);

// ---------------------------------------------------------------------------
// District catalogue
// ---------------------------------------------------------------------------

/// Sentinel value used for the "All Karnataka" dropdown entry. Matches
/// what the backend's `/mandi-rates/` endpoint recognises as an all-mode
/// sentinel (see `_normalize_district_filter` in main.py).
const String _kAllDistrictsOption = 'All Karnataka';

/// All 31 Karnataka districts. This list drives the dropdown and must
/// stay in sync with the backend's `_MANDI_RATE_DISTRICTS` in main.py —
/// which it does, because the backend echoes that same list back as
/// `available_districts` on every `/mandi-rates/` response. The local
/// copy exists only so the dropdown is populated on the very first frame,
/// before the network call resolves.
const List<String> _kKarnatakaDistricts = [
  'Bagalkot',
  'Ballari',
  'Belagavi',
  'Bengaluru Rural',
  'Bengaluru Urban',
  'Bidar',
  'Chamarajanagar',
  'Chikkaballapura',
  'Chikkamagaluru',
  'Chitradurga',
  'Dakshina Kannada',
  'Davanagere',
  'Dharwad',
  'Gadag',
  'Hassan',
  'Haveri',
  'Kalaburagi',
  'Kodagu',
  'Kolar',
  'Koppal',
  'Mandya',
  'Mysuru',
  'Raichur',
  'Ramanagara',
  'Shivamogga',
  'Tumakuru',
  'Udupi',
  'Uttara Kannada',
  'Vijayapura',
  'Yadgir',
  'Vijayanagara',
];

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// One row from `GET /mandi-rates/`, normalised into plain Dart fields.
///
/// `priceValue` is the numeric component extracted from `priceLabel` (e.g.
/// "₹30,000 / Qtl" → 30000.0). It exists only to drive the "highest price
/// first" sort — the label is what the card actually renders.
class _MandiRate {
  _MandiRate({
    required this.crop,
    required this.mandi,
    required this.priceLabel,
    required this.priceValue,
  });

  final String crop;
  final String mandi;
  final String priceLabel;
  final double priceValue;
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// Full-screen APMC price comparison, reached from the "Mandi Prices"
/// tile in the Farmer Dashboard's 2×2 quick-action grid.
///
/// Structure:
///   1. District dropdown (all 31 districts + "All Karnataka"; defaults to
///      the farmer's registered district).
///   2. Search bar with an inline clear button.
///   3. Price list, filtered by the search query and sorted highest-price
///      first.
///   4. Empty state when the filter yields nothing.
///
/// ## Backend contract
///
/// A single request to `/mandi-rates/` covers both modes:
///   - Specific district → `GET /mandi-rates/?district=Kolar`
///   - All Karnataka      → `GET /mandi-rates/` (no district param)
///
/// In all-mode the backend fans out across its full district coverage and
/// returns a merged rate list, tagged per-district. No more client-side
/// Future.wait() fan-out — one call, one response.
class MandiPricesScreen extends StatefulWidget {
  const MandiPricesScreen({super.key});

  @override
  State<MandiPricesScreen> createState() => _MandiPricesScreenState();
}

class _MandiPricesScreenState extends State<MandiPricesScreen> {
  String _selectedDistrict = _kAllDistrictsOption;
  final TextEditingController _searchController = TextEditingController();

  List<_MandiRate> _allRates = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Provider/context is only safe after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      final farmerDistrict = (auth.district ?? '').trim();
      if (farmerDistrict.isNotEmpty &&
          _kKarnatakaDistricts.contains(farmerDistrict)) {
        setState(() => _selectedDistrict = farmerDistrict);
      }
      _fetchRates();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Networking
  // -------------------------------------------------------------------------

  /// Fetches rates for the current selection.
  ///
  /// One HTTP call regardless of mode:
  ///   - "All Karnataka" → omit the `district` query param. The backend
  ///     interprets absence as all-mode and returns every district's
  ///     rates in one merged list.
  ///   - Specific district → send `?district=<name>`.
  Future<void> _fetchRates() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final Map<String, String> queryParams = {};
      if (_selectedDistrict != _kAllDistrictsOption) {
        queryParams['district'] = _selectedDistrict;
      }

      final uri = Uri.parse('$_kApiBaseUrl/mandi-rates/').replace(
        queryParameters: queryParams.isEmpty ? null : queryParams,
      );

      final resp = await http.get(
        uri,
        headers: const {'Accept': 'application/json'},
      );
      if (!mounted) return;

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final raw = (data['rates'] as List<dynamic>?) ?? const [];

        final parsed = raw
            .whereType<Map<String, dynamic>>()
            .map((r) {
              final priceLabel = (r['modal_price'] ?? '').toString();
              return _MandiRate(
                crop: (r['crop'] ?? '').toString(),
                mandi: (r['mandi'] ?? '').toString(),
                priceLabel: priceLabel,
                priceValue: _parsePrice(priceLabel),
              );
            })
            .toList(growable: false);

        setState(() {
          _allRates = parsed;
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Could not load prices (HTTP ${resp.statusCode}).';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Network error: $e';
        _loading = false;
      });
    }
  }

  /// Pulls the numeric component out of a formatted price string.
  /// Handles "₹2200 / Qtl", "₹30,000 / Qtl", "₹30,000.50 / Qtl", etc.
  /// Anything unparseable sorts to the bottom (0).
  double _parsePrice(String priceStr) {
    final cleaned = priceStr.replaceAll(RegExp(r'[^\d.]'), '');
    return double.tryParse(cleaned) ?? 0;
  }

  // -------------------------------------------------------------------------
  // Derived state
  // -------------------------------------------------------------------------

  /// Applies the search filter, then sorts by price descending.
  List<_MandiRate> get _filteredRates {
    final query = _searchController.text.trim().toLowerCase();

    Iterable<_MandiRate> list = _allRates;
    if (query.isNotEmpty) {
      list = list.where(
        (r) => r.crop.toLowerCase().contains(query),
      );
    }

    final sorted = list.toList()
      ..sort((a, b) => b.priceValue.compareTo(a.priceValue));
    return sorted;
  }

  String get _emptyMessage {
    final query = _searchController.text.trim();
    final district = _selectedDistrict;

    if (query.isEmpty) {
      if (district == _kAllDistrictsOption) {
        return 'No APMC rates available right now.';
      }
      return 'No APMC rates found in $district.';
    }

    if (district == _kAllDistrictsOption) {
      return 'No APMC rates found for "$query".';
    }
    return 'No APMC rates found for "$query" in $district.';
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBackground,
      appBar: AppBar(
        title: const Text('Mandi Prices'),
        backgroundColor: _kFarmerGreen,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildFilters(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            value: _selectedDistrict,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'District',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.map_outlined),
              isDense: true,
            ),
            items: <String>[
              _kAllDistrictsOption,
              ..._kKarnatakaDistricts,
            ]
                .map(
                  (d) => DropdownMenuItem<String>(
                    value: d,
                    child: Text(d, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v == null || v == _selectedDistrict) return;
              setState(() => _selectedDistrict = v);
              _fetchRates();
            },
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText:
                  'Search crop (e.g., Arecanut, Pepper, Tomato...)',
              hintStyle: const TextStyle(fontSize: 13),
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: 'Clear',
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                    )
                  : null,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _ErrorState(message: _error!, onRetry: _fetchRates);
    }

    final rates = _filteredRates;
    if (rates.isEmpty) {
      return _EmptyState(message: _emptyMessage);
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: rates.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _RateTile(rate: rates[i]),
    );
  }
}

// ---------------------------------------------------------------------------
// Rate tile
// ---------------------------------------------------------------------------

class _RateTile extends StatelessWidget {
  const _RateTile({required this.rate});

  final _MandiRate rate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rate.crop,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _kTextPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  rate.mandi,
                  style: const TextStyle(
                    fontSize: 12,
                    color: _kTextSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            rate.priceLabel,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: _kFarmerGreen,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty / error states
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: 56,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13.5,
                color: _kTextSecondary,
              ),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 56,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _kTextSecondary),
            ),
            const SizedBox(height: 16),
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