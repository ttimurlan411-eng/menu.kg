/// The restaurant and first branch created by the bootstrap RPC.
class RestaurantBootstrapResultModel {
  const RestaurantBootstrapResultModel({
    required this.restaurantId,
    required this.name,
    required this.slug,
    required this.description,
    required this.phone,
    required this.address,
    required this.currency,
    required this.defaultLanguage,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
    required this.branchId,
    required this.branchName,
  });

  final String restaurantId;
  final String name;
  final String slug;
  final String? description;
  final String? phone;
  final String? address;
  final String currency;
  final String defaultLanguage;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String branchId;
  final String branchName;

  factory RestaurantBootstrapResultModel.fromJson(Map<String, dynamic> json) {
    return RestaurantBootstrapResultModel(
      restaurantId: json['id'] as String,
      name: json['name'] as String,
      slug: json['slug'] as String,
      description: json['description'] as String?,
      phone: json['phone'] as String?,
      address: json['address'] as String?,
      currency: json['currency'] as String,
      defaultLanguage: json['default_language'] as String,
      isActive: json['is_active'] as bool,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      branchId: json['branch_id'] as String,
      branchName: json['branch_name'] as String,
    );
  }
}
