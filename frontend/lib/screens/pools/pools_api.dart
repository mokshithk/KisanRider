import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'pool_models.dart';

String get _kApiBaseUrl {
  if (kIsWeb) return 'http://localhost:8000';
  return 'http://10.28.1.142:8000';
}

class PoolsApi {
  static Map<String, String> _headers(String token) => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  static Future<List<Pool>> fetchNearbyPools({
    required String token,
    required double lat,
    required double lng,
    double radiusKm = 10.0,
    String? mandiId,
  }) async {
    final queryParams = <String, String>{
      'lat': lat.toString(),
      'lng': lng.toString(),
      'radius_km': radiusKm.toString(),
    };
    if (mandiId != null) {
      queryParams['mandi_id'] = mandiId;
    }

    final uri = Uri.parse('$_kApiBaseUrl/pools/nearby').replace(
      queryParameters: queryParams,
    );

    final resp = await http.get(uri, headers: _headers(token));
    if (resp.statusCode == 200) {
      final list = jsonDecode(resp.body) as List<dynamic>;
      return list.map((e) => Pool.fromJson(e)).toList();
    }
    throw Exception(_extractError(resp) ?? 'Failed to load pools');
  }

  static Future<List<Pool>> fetchMyPools({required String token}) async {
    final uri = Uri.parse('$_kApiBaseUrl/pools/my');
    final resp = await http.get(uri, headers: _headers(token));
    if (resp.statusCode == 200) {
      final list = jsonDecode(resp.body) as List<dynamic>;
      return list.map((e) => Pool.fromJson(e)).toList();
    }
    throw Exception(_extractError(resp) ?? 'Failed to load my pools');
  }

  static Future<List<NearbyFarmer>> fetchNearbyFarmers({
    required String token,
    required double lat,
    required double lng,
    double radiusKm = 10.0,
  }) async {
    final uri = Uri.parse('$_kApiBaseUrl/pools/nearby-farmers').replace(
      queryParameters: {
        'lat': lat.toString(),
        'lng': lng.toString(),
        'radius_km': radiusKm.toString(),
      },
    );

    final resp = await http.get(uri, headers: _headers(token));
    if (resp.statusCode == 200) {
      final list = jsonDecode(resp.body) as List<dynamic>;
      return list.map((e) => NearbyFarmer.fromJson(e)).toList();
    }
    throw Exception(_extractError(resp) ?? 'Failed to load nearby farmers');
  }

  static Future<PoolDetail> fetchPoolDetail({
    required String token,
    required String poolId,
  }) async {
    final uri = Uri.parse('$_kApiBaseUrl/pools/$poolId');
    final resp = await http.get(uri, headers: _headers(token));
    if (resp.statusCode == 200) {
      return PoolDetail.fromJson(jsonDecode(resp.body));
    }
    throw Exception(_extractError(resp) ?? 'Failed to load pool details');
  }

  static Future<PoolDetail> createPool({
    required String token,
    required Map<String, dynamic> payload,
  }) async {
    final uri = Uri.parse('$_kApiBaseUrl/pools/');
    final resp = await http.post(
      uri,
      headers: _headers(token),
      body: jsonEncode(payload),
    );
    if (resp.statusCode == 201) {
      return PoolDetail.fromJson(jsonDecode(resp.body));
    }
    throw Exception(_extractError(resp) ?? 'Failed to create pool');
  }

  static Future<PoolDetail> groupPool({
    required String token,
    required String creatorProduceRequestId,
    required List<String> otherProduceRequestIds,
    required DateTime pickupWindowStart,
    required DateTime pickupWindowEnd,
  }) async {
    final uri = Uri.parse('$_kApiBaseUrl/pools/group');
    final resp = await http.post(
      uri,
      headers: _headers(token),
      body: jsonEncode({
        'creator_produce_request_id': creatorProduceRequestId,
        'other_produce_request_ids': otherProduceRequestIds,
        'pickup_window_start': pickupWindowStart.toUtc().toIso8601String(),
        'pickup_window_end': pickupWindowEnd.toUtc().toIso8601String(),
      }),
    );
    if (resp.statusCode == 201) {
      return PoolDetail.fromJson(jsonDecode(resp.body));
    }
    throw Exception(_extractError(resp) ?? 'Failed to group pool');
  }

  static Future<PoolDetail> joinPool({
    required String token,
    required String poolId,
    required String produceRequestId,
    required double weightKg,
  }) async {
    final uri = Uri.parse('$_kApiBaseUrl/pools/$poolId/join');
    final resp = await http.post(
      uri,
      headers: _headers(token),
      body: jsonEncode({
        'produce_request_id': produceRequestId,
        'weight_kg': weightKg,
      }),
    );
    if (resp.statusCode == 200) {
      return PoolDetail.fromJson(jsonDecode(resp.body));
    }
    throw Exception(_extractError(resp) ?? 'Failed to join pool');
  }

  static Future<void> leavePool({
    required String token,
    required String poolId,
  }) async {
    final uri = Uri.parse('$_kApiBaseUrl/pools/$poolId/leave');
    final resp = await http.delete(uri, headers: _headers(token));
    if (resp.statusCode != 200) {
      throw Exception(_extractError(resp) ?? 'Failed to leave pool');
    }
  }

  static Future<void> cancelPool({
    required String token,
    required String poolId,
  }) async {
    final uri = Uri.parse('$_kApiBaseUrl/pools/$poolId');
    final resp = await http.delete(uri, headers: _headers(token));
    if (resp.statusCode != 200) {
      throw Exception(_extractError(resp) ?? 'Failed to cancel pool');
    }
  }

  static String? _extractError(http.Response resp) {
    try {
      final body = jsonDecode(resp.body);
      if (body is Map && body['detail'] != null) {
        return body['detail'].toString();
      }
    } catch (_) {}
    return null;
  }
}