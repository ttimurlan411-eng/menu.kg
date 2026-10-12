/// A restaurant membership row from the `restaurant_members` table.
class RestaurantMembershipModel {
  const RestaurantMembershipModel({
    required this.id,
    required this.restaurantId,
    required this.userId,
    required this.role,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String restaurantId;
  final String userId;
  final String role;

  /// Maps to the `restaurant_members.is_active` status column.
  final bool isActive;

  final DateTime createdAt;
  final DateTime updatedAt;

  factory RestaurantMembershipModel.fromJson(Map<String, dynamic> json) {
    return RestaurantMembershipModel(
      id: json['id'] as String,
      restaurantId: json['restaurant_id'] as String,
      userId: json['user_id'] as String,
      role: json['role'] as String,
      isActive: json['is_active'] as bool,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }
}
