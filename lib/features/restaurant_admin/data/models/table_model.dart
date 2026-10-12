/// A table row from the `tables` table.
class TableModel {
  const TableModel({
    required this.id,
    required this.restaurantId,
    required this.branchId,
    required this.tableNumber,
    required this.capacity,
    required this.status,
    required this.qrToken,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
    this.name,
    this.zone,
  });

  final String id;
  final String restaurantId;

  /// Branch that this table belongs to. The database requires it.
  final String branchId;

  final String tableNumber;
  final String? name;
  final int capacity;
  final String? zone;
  final String status;

  /// Public, database-generated token that identifies this table's menu link.
  ///
  /// The database creates it with `gen_random_uuid()` and keeps it unique, so
  /// the admin UI never supplies or changes it.
  final String qrToken;

  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The label shown in the admin UI, combining number and optional name.
  String get displayName {
    final tableName = name?.trim() ?? '';
    return tableName.isEmpty ? tableNumber : '$tableNumber · $tableName';
  }

  factory TableModel.fromJson(Map<String, dynamic> json) {
    return TableModel(
      id: json['id'] as String,
      restaurantId: json['restaurant_id'] as String,
      branchId: json['branch_id'] as String,
      tableNumber: json['table_number'] as String,
      name: json['name'] as String?,
      capacity: json['capacity'] as int,
      zone: json['zone'] as String?,
      status: json['status'] as String,
      qrToken: json['qr_token'] as String,
      isActive: json['is_active'] as bool,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  /// Payload for create and update mutations.
  ///
  /// `id`, `restaurant_id` and `qr_token` are deliberately absent: the
  /// repository scopes rows by restaurant and the database owns the token, so
  /// a table keeps its QR code across renames and edits.
  Map<String, dynamic> toMutationJson() {
    return {
      'table_number': tableNumber,
      'name': name,
      'capacity': capacity,
      'zone': zone,
      'status': status,
      'is_active': isActive,
    };
  }
}
