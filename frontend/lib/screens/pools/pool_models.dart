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
  
  // New Fields
  final double? estimatedFreight;
  final String? driverName;
  final String? driverPhone;
  final String? driverVehicle;

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
    this.estimatedFreight,
    this.driverName,
    this.driverPhone,
    this.driverVehicle,
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
      estimatedFreight: (json['estimated_freight'] as num?)?.toDouble(),
      driverName: json['driver_name']?.toString(),
      driverPhone: json['driver_phone']?.toString(),
      driverVehicle: json['driver_vehicle']?.toString(),
    );
  }
  
  bool get isFull => currentQty >= maxQty;
}

class PoolMember {
  final String id;
  final String farmerId;
  final String produceRequestId;
  final double weightKg;
  final String status;
  final DateTime requestedAt;
  final String? farmerFullName;
  final String? pickupOtp;

  PoolMember({
    required this.id,
    required this.farmerId,
    required this.produceRequestId,
    required this.weightKg,
    required this.status,
    required this.requestedAt,
    this.farmerFullName,
    this.pickupOtp,
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
      pickupOtp: json['pickup_otp']?.toString(),
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

class PoolMemberSettlement {
  final String id;
  final String status;
  final String? cropName;
  final double? quantityKg;
  final double? ratePerKg;
  final String? rateSource;
  final double? grossAmount;
  final double? riderFare;
  final double? platformFee;
  final double? netPayout;
  final String? paymentReference;
  final DateTime? paidAt;

  PoolMemberSettlement({
    required this.id,
    required this.status,
    this.cropName,
    this.quantityKg,
    this.ratePerKg,
    this.rateSource,
    this.grossAmount,
    this.riderFare,
    this.platformFee,
    this.netPayout,
    this.paymentReference,
    this.paidAt,
  });

  factory PoolMemberSettlement.fromJson(Map<String, dynamic> json) {
    return PoolMemberSettlement(
      id: (json['id'] ?? '').toString(),
      status: (json['status'] ?? 'PENDING').toString(),
      cropName: json['crop_name']?.toString(),
      quantityKg: (json['quantity_kg'] as num?)?.toDouble(),
      ratePerKg: (json['rate_per_kg'] as num?)?.toDouble(),
      rateSource: json['rate_source']?.toString(),
      grossAmount: (json['gross_amount'] as num?)?.toDouble(),
      riderFare: (json['rider_fare'] as num?)?.toDouble(),
      platformFee: (json['platform_fee'] as num?)?.toDouble(),
      netPayout: (json['net_payout'] as num?)?.toDouble(),
      paymentReference: json['payment_reference']?.toString(),
      paidAt: json['paid_at'] is String
          ? DateTime.tryParse(json['paid_at'] as String)
          : null,
    );
  }

  bool get isPaid => status.toUpperCase() == 'PAID';
}

class PoolDetail extends Pool {
  final List<PoolMember> members;
  final List<PoolStop> stops;
  final PoolMemberSettlement? mySettlement;
  final String? poolPaymentStatus;
  final double? poolTotalCropValue;
  final String? poolPaymentReference;

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
    super.estimatedFreight,
    super.driverName,
    super.driverPhone,
    super.driverVehicle,
    required this.members,
    required this.stops,
    this.mySettlement,
    this.poolPaymentStatus,
    this.poolTotalCropValue,
    this.poolPaymentReference,
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
    final rawSettle = json['my_settlement'];

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
      estimatedFreight: pool.estimatedFreight,
      driverName: pool.driverName,
      driverPhone: pool.driverPhone,
      driverVehicle: pool.driverVehicle,
      members: membersList,
      stops: stopsList,
      mySettlement: rawSettle is Map<String, dynamic>
          ? PoolMemberSettlement.fromJson(rawSettle)
          : null,
      poolPaymentStatus: json['pool_payment_status']?.toString(),
      poolTotalCropValue: (json['pool_total_crop_value'] as num?)?.toDouble(),
      poolPaymentReference: json['pool_payment_reference']?.toString(),
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