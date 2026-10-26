class Pool {
  final String id;
  final String creatorId;
  final String? creatorFullName;
  final String cropType;
  final DateTime pickupWindowStart;
  final DateTime pickupWindowEnd;
  final double minQty;
  final double maxQty;
  final double currentQty;
  final String status;
  final bool autoApprove;
  final String? dropoffDistrict;
  final String? dropoffMandiName;
  final int memberCount;
  final DateTime createdAt;
  final double? distanceKm;
  final String? pickupAddress;

  Pool({
    required this.id,
    required this.creatorId,
    this.creatorFullName,
    required this.cropType,
    required this.pickupWindowStart,
    required this.pickupWindowEnd,
    required this.minQty,
    required this.maxQty,
    required this.currentQty,
    required this.status,
    required this.autoApprove,
    this.dropoffDistrict,
    this.dropoffMandiName,
    required this.memberCount,
    required this.createdAt,
    this.distanceKm,
    this.pickupAddress,
  });

  factory Pool.fromJson(Map<String, dynamic> json) {
    return Pool(
      id: json['id'].toString(),
      creatorId: json['creator_id'].toString(),
      creatorFullName: json['creator_full_name']?.toString(),
      cropType: json['crop_type']?.toString() ?? 'Unknown',
      pickupWindowStart: DateTime.tryParse(json['pickup_window_start']?.toString() ?? '') ?? DateTime.now(),
      pickupWindowEnd: DateTime.tryParse(json['pickup_window_end']?.toString() ?? '') ?? DateTime.now(),
      minQty: (json['min_qty'] as num?)?.toDouble() ?? 0.0,
      maxQty: (json['max_qty'] as num?)?.toDouble() ?? 0.0,
      currentQty: (json['current_qty'] as num?)?.toDouble() ?? 0.0,
      status: json['status']?.toString() ?? 'OPEN',
      autoApprove: json['auto_approve'] as bool? ?? true,
      dropoffDistrict: json['dropoff_district']?.toString(),
      dropoffMandiName: json['dropoff_mandi_name']?.toString(),
      memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ?? DateTime.now(),
      distanceKm: (json['distance_km'] as num?)?.toDouble(),
      pickupAddress: json['pickup_address']?.toString(),
    );
  }
}

class PoolMember {
  final String id;
  final String farmerId;
  final String produceRequestId;
  final double weightKg;
  final String status;
  final DateTime requestedAt;
  final String? farmerFullName;

  PoolMember({
    required this.id,
    required this.farmerId,
    required this.produceRequestId,
    required this.weightKg,
    required this.status,
    required this.requestedAt,
    this.farmerFullName,
  });

  factory PoolMember.fromJson(Map<String, dynamic> json) {
    return PoolMember(
      id: json['id'].toString(),
      farmerId: json['farmer_id'].toString(),
      produceRequestId: json['produce_request_id'].toString(),
      weightKg: (json['weight_kg'] as num?)?.toDouble() ?? 0.0,
      status: json['status']?.toString() ?? 'REQUESTED',
      requestedAt: DateTime.tryParse(json['requested_at']?.toString() ?? '') ?? DateTime.now(),
      farmerFullName: json['farmer_full_name']?.toString(),
    );
  }
}

class PoolStop {
  final int sequence;
  final String produceRequestId;
  final String status;

  PoolStop({
    required this.sequence,
    required this.produceRequestId,
    required this.status,
  });

  factory PoolStop.fromJson(Map<String, dynamic> json) {
    return PoolStop(
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      produceRequestId: json['produce_request_id'].toString(),
      status: json['status']?.toString() ?? 'PENDING',
    );
  }
}

class PoolDetail extends Pool {
  final List<PoolMember> members;
  final List<PoolStop> stops;

  PoolDetail({
    required super.id,
    required super.creatorId,
    super.creatorFullName,
    required super.cropType,
    required super.pickupWindowStart,
    required super.pickupWindowEnd,
    required super.minQty,
    required super.maxQty,
    required super.currentQty,
    required super.status,
    required super.autoApprove,
    super.dropoffDistrict,
    super.dropoffMandiName,
    required super.memberCount,
    required super.createdAt,
    super.distanceKm,
    super.pickupAddress,
    required this.members,
    required this.stops,
  });

  factory PoolDetail.fromJson(Map<String, dynamic> json) {
    final pool = Pool.fromJson(json);
    final membersList = (json['members'] as List<dynamic>?)
            ?.map((e) => PoolMember.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    final stopsList = (json['stops'] as List<dynamic>?)
            ?.map((e) => PoolStop.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    return PoolDetail(
      id: pool.id,
      creatorId: pool.creatorId,
      creatorFullName: pool.creatorFullName,
      cropType: pool.cropType,
      pickupWindowStart: pool.pickupWindowStart,
      pickupWindowEnd: pool.pickupWindowEnd,
      minQty: pool.minQty,
      maxQty: pool.maxQty,
      currentQty: pool.currentQty,
      status: pool.status,
      autoApprove: pool.autoApprove,
      dropoffDistrict: pool.dropoffDistrict,
      dropoffMandiName: pool.dropoffMandiName,
      memberCount: pool.memberCount,
      createdAt: pool.createdAt,
      distanceKm: pool.distanceKm,
      pickupAddress: pool.pickupAddress,
      members: membersList,
      stops: stopsList,
    );
  }
}

class NearbyFarmer {
  final String produceRequestId;
  final String farmerId;
  final String farmerName;
  final String cropType;
  final double weightKg;
  final double distanceKm;
  final String? dropoffMandiName;
  final String? dropoffDistrict;

  NearbyFarmer({
    required this.produceRequestId,
    required this.farmerId,
    required this.farmerName,
    required this.cropType,
    required this.weightKg,
    required this.distanceKm,
    this.dropoffMandiName,
    this.dropoffDistrict,
  });

  factory NearbyFarmer.fromJson(Map<String, dynamic> json) {
    return NearbyFarmer(
      produceRequestId: json['produce_request_id'].toString(),
      farmerId: json['farmer_id'].toString(),
      farmerName: json['farmer_name']?.toString() ?? 'Farmer',
      cropType: json['crop_type']?.toString() ?? 'Unknown',
      weightKg: (json['weight_kg'] as num?)?.toDouble() ?? 0.0,
      distanceKm: (json['distance_km'] as num?)?.toDouble() ?? 0.0,
      dropoffMandiName: json['dropoff_mandi_name']?.toString(),
      dropoffDistrict: json['dropoff_district']?.toString(),
    );
  }
}