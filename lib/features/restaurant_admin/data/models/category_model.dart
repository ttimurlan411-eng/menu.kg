/// A category row from the `categories` table.
class CategoryModel {
  const CategoryModel({
    required this.id,
    required this.restaurantId,
    required this.name,
    required this.sortOrder,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
    this.branchId,
    this.description,
    this.imageUrl,
  });

  final String id;
  final String restaurantId;

  /// Optional branch that this category belongs to.
  final String? branchId;

  final String name;
  final String? description;
  final String? imageUrl;
  final int sortOrder;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory CategoryModel.fromJson(Map<String, dynamic> json) {
    return CategoryModel(
      id: json['id'] as String,
      restaurantId: json['restaurant_id'] as String,
      branchId: json['branch_id'] as String?,
      name: json['name'] as String,
      description: json['description'] as String?,
      imageUrl: json['image_url'] as String?,
      sortOrder: json['sort_order'] as int,
      isActive: json['is_active'] as bool,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  /// Payload for create and update mutations.
  ///
  /// `restaurant_id` and the row `id` are supplied by the repository so the UI
  /// can never target another restaurant. Nullable optional columns are omitted
  /// so the database keeps its defaults.
  Map<String, dynamic> toMutationJson() {
    return {
      'name': name,
      'sort_order': sortOrder,
      'is_active': isActive,
    };
  }
}