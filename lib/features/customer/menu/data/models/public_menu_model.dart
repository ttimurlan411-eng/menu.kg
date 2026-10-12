import 'dart:convert';

/// Display information about a restaurant, safe to show to any guest.
///
/// The public menu is resolved from an opaque QR token, so no restaurant id is
/// ever received here. Contact details and coordinates are intentionally not
/// part of the public payload.
class PublicRestaurantInfo {
  const PublicRestaurantInfo({
    required this.name,
    required this.currency,
    required this.defaultLanguage,
    this.logoUrl,
    this.coverUrl,
    this.description,
  });

  final String name;
  final String? logoUrl;
  final String? coverUrl;
  final String? description;

  /// ISO currency code used to label prices, for example `KGS`.
  final String currency;

  final String defaultLanguage;

  factory PublicRestaurantInfo.fromJson(Map<String, dynamic> json) {
    return PublicRestaurantInfo(
      name: json['name'] as String,
      logoUrl: json['logo_url'] as String?,
      coverUrl: json['cover_url'] as String?,
      description: json['description'] as String?,
      currency: json['currency'] as String,
      defaultLanguage: json['default_language'] as String,
    );
  }
}

/// Display information about the branch that served the guest's table.
class PublicBranchInfo {
  const PublicBranchInfo({required this.name});

  final String name;

  factory PublicBranchInfo.fromJson(Map<String, dynamic> json) {
    return PublicBranchInfo(name: json['name'] as String);
  }
}

/// The table a guest scanned. Only human-readable labels are included.
class PublicTableInfo {
  const PublicTableInfo({required this.number, this.name});

  final String number;
  final String? name;

  /// Label shown to the guest, for example `Table 12 · Terrace`.
  String get label {
    final tableName = name?.trim() ?? '';
    return tableName.isEmpty ? 'Table $number' : 'Table $number · $tableName';
  }

  factory PublicTableInfo.fromJson(Map<String, dynamic> json) {
    return PublicTableInfo(
      number: json['number'] as String,
      name: json['name'] as String?,
    );
  }
}

/// An available menu item inside a [PublicCategoryModel].
class PublicMenuItemModel {
  const PublicMenuItemModel({
    required this.id,
    required this.name,
    required this.price,
    this.description,
    this.oldPrice,
    this.mainImageUrl,
    this.preparationTimeMinutes = 0,
  });

  /// Id used only as a widget key; it is never shown to the guest.
  final String id;

  final String name;
  final String? description;
  final double price;
  final double? oldPrice;
  final String? mainImageUrl;
  final int preparationTimeMinutes;

  /// Whether the item is discounted, so the UI can show both prices.
  bool get hasDiscount =>
      oldPrice != null && oldPrice! > price && price > 0;

  factory PublicMenuItemModel.fromJson(Map<String, dynamic> json) {
    return PublicMenuItemModel(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      price: (json['price'] as num).toDouble(),
      oldPrice: (json['old_price'] as num?)?.toDouble(),
      mainImageUrl: json['main_image_url'] as String?,
      preparationTimeMinutes: (json['preparation_time_minutes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// An active category with its available menu items.
class PublicCategoryModel {
  const PublicCategoryModel({
    required this.id,
    required this.name,
    required this.items,
    this.description,
    this.imageUrl,
  });

  /// Id used only as a widget key; it is never shown to the guest.
  final String id;

  final String name;
  final String? description;
  final String? imageUrl;
  final List<PublicMenuItemModel> items;

  factory PublicCategoryModel.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List? ?? const [];
    return PublicCategoryModel(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      imageUrl: json['image_url'] as String?,
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(PublicMenuItemModel.fromJson)
          .toList(),
    );
  }
}

/// The complete customer menu for one table QR code.
///
/// Returned by the public `public_menu_by_qr_token` database function, which
/// already filters out inactive restaurants, branches, tables, categories and
/// unavailable items.
class PublicMenuModel {
  const PublicMenuModel({
    required this.restaurant,
    required this.branch,
    required this.table,
    required this.categories,
  });

  final PublicRestaurantInfo restaurant;
  final PublicBranchInfo branch;
  final PublicTableInfo table;

  /// Only categories that have at least one available item.
  final List<PublicCategoryModel> categories;

  bool get isEmpty => categories.isEmpty;

  /// Every item across all categories, used by the unfiltered view.
  List<PublicMenuItemModel> get allItems =>
      categories.expand((category) => category.items).toList();

  /// Total number of available items, shown in the header.
  int get itemCount =>
      categories.fold(0, (total, category) => total + category.items.length);

  /// Whether [categoryId] is one of the categories in this menu.
  ///
  /// `null` never matches, so callers can pass a nullable selection straight in:
  /// a `null` category means "All categories" and is therefore always available.
  /// A selected category that is no longer offered is recognised here, which is
  /// how the menu view falls back to the full menu instead of showing nothing.
  bool offersCategory(String? categoryId) =>
      categoryId != null &&
      categories.any((category) => category.id == categoryId);

  /// Finds an available item and the category that owns it.
  ///
  /// This is the only way a product page resolves a product, and it can only
  /// ever find items that belong to the restaurant, branch and table the QR
  /// token already resolved to. An id from any other restaurant is therefore
  /// never found, because it cannot appear in [categories].
  ({PublicCategoryModel category, PublicMenuItemModel item})? findItemById(
    String itemId,
  ) {
    for (final category in categories) {
      for (final item in category.items) {
        if (item.id == itemId) {
          return (category: category, item: item);
        }
      }
    }
    return null;
  }

  factory PublicMenuModel.fromJson(Map<String, dynamic> json) {
    final restaurant = json['restaurant'] as Map<String, dynamic>;
    final branch = json['branch'] as Map<String, dynamic>;
    final table = json['table'] as Map<String, dynamic>;
    final rawCategories = json['categories'] as List? ?? const [];

    return PublicMenuModel(
      restaurant: PublicRestaurantInfo.fromJson(restaurant),
      branch: PublicBranchInfo.fromJson(branch),
      table: PublicTableInfo.fromJson(table),
      // The database already omits categories without available items. Dropping
      // them again here keeps that promise on the client: a guest is never shown
      // an empty section, and nothing downstream has to render a category with
      // no products — least of all the "cheapest dish" price, which cannot be
      // computed from an empty list.
      categories: rawCategories
          .whereType<Map<String, dynamic>>()
          .map(PublicCategoryModel.fromJson)
          .where((category) => category.items.isNotEmpty)
          .toList(),
    );
  }

  /// Parses the raw `rpc` response, tolerating both decoded and string payloads.
  ///
  /// Returns `null` when the token resolved to nothing, which is how the
  /// database reports an unknown, deleted or inactive QR code.
  static PublicMenuModel? tryParse(Object? response) {
    Object? decoded = response;
    if (decoded is String) {
      if (decoded.trim().isEmpty) {
        return null;
      }
      try {
        decoded = jsonDecode(decoded);
      } on FormatException {
        return null;
      }
    }

    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    return PublicMenuModel.fromJson(decoded);
  }
}

/// Formats a price for guests, for example `350.00 KGS`.
String formatPublicPrice(double price, String currency) =>
    '${price.toStringAsFixed(2)} ${currency.toUpperCase()}';