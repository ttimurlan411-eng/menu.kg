/// A menu item row from the `menu_items` table.
class MenuItemModel {
  const MenuItemModel({
    required this.id,
    required this.restaurantId,
    required this.categoryId,
    required this.name,
    required this.price,
    required this.isAvailable,
    required this.isPopular,
    required this.isNew,
    required this.preparationTimeMinutes,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
    this.branchId,
    this.description,
    this.oldPrice,
    this.mainImageUrl,
  });

  final String id;
  final String restaurantId;

  /// Optional branch that this menu item belongs to.
  final String? branchId;

  /// Category that this menu item belongs to.
  final String categoryId;

  final String name;
  final String? description;

  /// Price stored as `numeric(12, 2)`.
  final double price;

  /// Optional original price before a discount.
  final double? oldPrice;
  final String? mainImageUrl;
  final bool isAvailable;
  final bool isPopular;
  final bool isNew;
  final int preparationTimeMinutes;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory MenuItemModel.fromJson(Map<String, dynamic> json) {
    return MenuItemModel(
      id: json['id'] as String,
      restaurantId: json['restaurant_id'] as String,
      branchId: json['branch_id'] as String?,
      categoryId: json['category_id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      price: (json['price'] as num).toDouble(),
      oldPrice: (json['old_price'] as num?)?.toDouble(),
      mainImageUrl: json['main_image_url'] as String?,
      isAvailable: json['is_available'] as bool,
      isPopular: json['is_popular'] as bool,
      isNew: json['is_new'] as bool,
      preparationTimeMinutes: json['preparation_time_minutes'] as int,
      sortOrder: json['sort_order'] as int,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  /// Payload for create and update mutations.
  ///
  /// `restaurant_id` and the row `id` are supplied by the repository so the UI
  /// can never target another restaurant. Columns the admin does not edit
  /// (price, availability and category) use the values managed by the form, so
  /// the database keeps its defaults for the remaining ones.
  Map<String, dynamic> toMutationJson() {
    return {
      'name': name,
      'category_id': categoryId,
      'price': price,
      'is_available': isAvailable,
    };
  }
}