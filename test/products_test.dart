import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/category_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/menu_item_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/category_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/menu_item_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/menu_item_error_message.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/products_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

MenuItemModel buildMenuItem({
  String id = 'menu-item-1',
  String categoryId = 'category-1',
  String name = 'Lagman',
  double price = 250,
  bool isAvailable = true,
}) {
  return MenuItemModel(
    id: id,
    restaurantId: 'restaurant-1',
    categoryId: categoryId,
    name: name,
    price: price,
    isAvailable: isAvailable,
    isPopular: false,
    isNew: false,
    preparationTimeMinutes: 20,
    sortOrder: 0,
    createdAt: DateTime.utc(2026, 9, 18),
    updatedAt: DateTime.utc(2026, 9, 18),
  );
}

CategoryModel buildCategory({
  String id = 'category-1',
  String name = 'Appetizers',
}) {
  return CategoryModel(
    id: id,
    restaurantId: 'restaurant-1',
    name: name,
    sortOrder: 0,
    isActive: true,
    createdAt: DateTime.utc(2026, 9, 18),
    updatedAt: DateTime.utc(2026, 9, 18),
  );
}

Future<void> pumpProductsPage(
  WidgetTester tester,
  MenuItemRepository menuItemRepository, {
  CategoryRepository? categoryRepository,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProductsPage(
          restaurantId: 'restaurant-1',
          menuItemRepository: menuItemRepository,
          categoryRepository: categoryRepository ?? _StubCategoryRepository(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('MenuItemModel', () {
    test('parses a menu item row', () {
      final item = MenuItemModel.fromJson({
        'id': 'menu-item-1',
        'restaurant_id': 'restaurant-1',
        'branch_id': 'branch-1',
        'category_id': 'category-1',
        'name': 'Lagman',
        'description': 'Hand-pulled noodles',
        'price': 250,
        'old_price': 300,
        'main_image_url': 'https://example.com/lagman.png',
        'is_available': false,
        'is_popular': true,
        'is_new': false,
        'preparation_time_minutes': 30,
        'sort_order': 4,
        'created_at': '2026-09-18T00:00:00.000Z',
        'updated_at': '2026-09-18T00:00:00.000Z',
      });

      expect(item.id, 'menu-item-1');
      expect(item.restaurantId, 'restaurant-1');
      expect(item.branchId, 'branch-1');
      expect(item.categoryId, 'category-1');
      expect(item.name, 'Lagman');
      expect(item.description, 'Hand-pulled noodles');
      expect(item.price, 250);
      expect(item.oldPrice, 300);
      expect(item.mainImageUrl, 'https://example.com/lagman.png');
      expect(item.isAvailable, isFalse);
      expect(item.isPopular, isTrue);
      expect(item.isNew, isFalse);
      expect(item.preparationTimeMinutes, 30);
      expect(item.sortOrder, 4);
      expect(item.createdAt, DateTime.utc(2026, 9, 18));
      expect(item.updatedAt, DateTime.utc(2026, 9, 18));
    });

    test('mutation payload only carries editable columns', () {
      final item = buildMenuItem(name: 'Samsa', price: 120.5);

      expect(item.toMutationJson(), {
        'name': 'Samsa',
        'category_id': 'category-1',
        'price': 120.5,
        'is_available': true,
      });
    });
  });

  group('validation', () {
    test('product name is required and enforced to a maximum length', () {
      expect(validateProductName(null), 'Enter a product name.');
      expect(validateProductName('   '), 'Enter a product name.');
      expect(validateProductName('Besh Barmak'), isNull);
      expect(validateProductName('  Samsa  '), isNull);
      expect(
        validateProductName('P' * (maxProductNameLength + 1)),
        'Product name must be $maxProductNameLength characters or fewer.',
      );
    });

    test('price matches the database non-negative constraint', () {
      expect(validateProductPrice(null), 'Enter a price.');
      expect(validateProductPrice('  '), 'Enter a price.');
      expect(
        validateProductPrice('-1'),
        'Price must be a number of 0 or more.',
      );
      expect(
        validateProductPrice('abc'),
        'Price must be a number of 0 or more.',
      );
      expect(
        validateProductPrice('1.2.3'),
        'Price must be a number of 0 or more.',
      );
      expect(validateProductPrice('0'), isNull);
      expect(validateProductPrice('250.50'), isNull);
    });

    test('price formatting always shows two decimals', () {
      expect(formatProductPrice(250), '250.00');
      expect(formatProductPrice(120.5), '120.50');
      expect(formatProductPrice(0), '0.00');
    });
  });

  group('MenuItemRepository', () {
    late SupabaseClient client;

    setUp(() {
      client = SupabaseClient('http://localhost:54321', 'test-anon-key');
    });

    tearDown(() => client.dispose());

    test('avoids database calls when unauthenticated', () async {
      final repository = MenuItemRepository.withClient(client);

      expect(await repository.getMenuItems('restaurant-1'), isEmpty);
      expect(
        await repository.createMenuItem(
          restaurantId: 'restaurant-1',
          categoryId: 'category-1',
          name: 'Samsa',
          price: 100,
        ),
        isNull,
      );
      expect(
        await repository.updateMenuItem(
          restaurantId: 'restaurant-1',
          menuItemId: 'menu-item-1',
          categoryId: 'category-1',
          name: 'Samsa',
          price: 100,
          isAvailable: true,
        ),
        isNull,
      );
      await repository.deleteMenuItem(
        restaurantId: 'restaurant-1',
        menuItemId: 'menu-item-1',
      );
    });
  });

  group('ProductsPage', () {
    testWidgets('shows an empty state when there are no products', (
      tester,
    ) async {
      await pumpProductsPage(tester, _FakeMenuItemRepository());

      expect(find.text('No products yet'), findsOneWidget);
      expect(find.text('Add product'), findsWidgets);
      expect(find.byKey(const Key('emptyAddProductButton')), findsOneWidget);
    });

    testWidgets('renders products with category, price, and status', (
      tester,
    ) async {
      final repository = _FakeMenuItemRepository(
        initial: [
          buildMenuItem(name: 'Lagman', price: 250, isAvailable: true),
          buildMenuItem(
            id: 'menu-item-2',
            categoryId: 'category-2',
            name: 'Samsa',
            price: 120.5,
            isAvailable: false,
          ),
        ],
      );
      await pumpProductsPage(tester, repository);

      expect(find.text('Lagman'), findsOneWidget);
      expect(find.text('Samsa'), findsOneWidget);
      expect(
        find.text('Appetizers · Price: 250.00\nAvailable'),
        findsOneWidget,
      );
      expect(
        find.text('Desserts · Price: 120.50\nUnavailable'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('editProductButton_menu-item-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('deleteProductButton_menu-item-1')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('addProductButton')), findsOneWidget);
    });

    testWidgets('shows a loading state while products are fetched', (
      tester,
    ) async {
      final completer = Completer<List<MenuItemModel>>();
      final repository = _PendingMenuItemRepository(completer);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProductsPage(
              restaurantId: 'restaurant-1',
              menuItemRepository: repository,
              categoryRepository: const _EmptyCategoryRepository(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Loading products...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      completer.complete([]);
      await tester.pumpAndSettle();

      expect(find.text('No products yet'), findsOneWidget);
    });

    testWidgets('shows an error state and retries', (tester) async {
      final repository = _FailingMenuItemRepository();
      await pumpProductsPage(tester, repository);

      expect(
        find.text('We could not load your products. Please try again.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('productsRetryButton')), findsOneWidget);

      repository.failuresRemaining = 0;
      await tester.tap(find.byKey(const Key('productsRetryButton')));
      await tester.pumpAndSettle();

      expect(find.text('No products yet'), findsOneWidget);
    });

    testWidgets('add product dialog renders all required fields', (
      tester,
    ) async {
      await pumpProductsPage(tester, _FakeMenuItemRepository());

      await tester.tap(find.byKey(const Key('addProductButton')));
      await tester.pumpAndSettle();

      expect(find.text('Add product'), findsWidgets);
      expect(find.byKey(const Key('productNameField')), findsOneWidget);
      expect(find.byKey(const Key('productCategoryField')), findsOneWidget);
      expect(find.byKey(const Key('productPriceField')), findsOneWidget);
      expect(
        find.byKey(const Key('productAvailableSwitch')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('productFormSubmitButton')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('productFormCancelButton')),
        findsOneWidget,
      );
    });

    testWidgets('add product dialog validates required fields', (
      tester,
    ) async {
      await pumpProductsPage(tester, _FakeMenuItemRepository());

      await tester.tap(find.byKey(const Key('addProductButton')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('productFormSubmitButton')));
      await tester.pump();

      expect(find.text('Enter a product name.'), findsOneWidget);
      expect(find.text('Enter a price.'), findsOneWidget);
      expect(find.text('Choose a category.'), findsOneWidget);
    });

    testWidgets('category field lists existing categories for selection', (
      tester,
    ) async {
      await pumpProductsPage(tester, _FakeMenuItemRepository());

      await tester.tap(find.byKey(const Key('addProductButton')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('productCategoryField')));
      await tester.pumpAndSettle();

      expect(find.text('Appetizers'), findsOneWidget);
      expect(find.text('Desserts'), findsOneWidget);
    });

    testWidgets('a created product is persisted with the chosen category', (
      tester,
    ) async {
      final repository = _FakeMenuItemRepository();
      await pumpProductsPage(tester, repository);

      await tester.tap(find.byKey(const Key('addProductButton')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('productNameField')),
        'Besh Barmak',
      );
      await tester.enterText(
        find.byKey(const Key('productPriceField')),
        '300.5',
      );
      await tester.tap(find.byKey(const Key('productCategoryField')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desserts').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('productFormSubmitButton')));
      await tester.pumpAndSettle();

      expect(repository.createdNames, contains('Besh Barmak'));
      expect(repository.createdCategoryIds, contains('category-2'));
      expect(find.text('Desserts · Price: 300.50\nAvailable'), findsOneWidget);
    });

    testWidgets('edit product dialog is prefilled and saves', (tester) async {
      final repository = _FakeMenuItemRepository(
        initial: [buildMenuItem(name: 'Lagman', price: 250)],
      );
      await pumpProductsPage(tester, repository);

      await tester.tap(
        find.byKey(const Key('editProductButton_menu-item-1')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit product'), findsOneWidget);
      final nameField = tester.widget<TextFormField>(
        find.byKey(const Key('productNameField')),
      );
      final priceField = tester.widget<TextFormField>(
        find.byKey(const Key('productPriceField')),
      );
      expect(nameField.controller?.text, 'Lagman');
      expect(priceField.controller?.text, '250.00');
      expect(find.text('Appetizers'), findsOneWidget);
      expect(find.byKey(const Key('productAvailableSwitch')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('productNameField')),
        'Beef Lagman',
      );
      await tester.enterText(
        find.byKey(const Key('productPriceField')),
        '280',
      );
      await tester.tap(find.byKey(const Key('productFormSubmitButton')));
      await tester.pumpAndSettle();

      expect(find.text('Beef Lagman'), findsOneWidget);
      expect(find.text('Lagman'), findsNothing);
      expect(
        find.text('Appetizers · Price: 280.00\nAvailable'),
        findsOneWidget,
      );
      expect(repository.updatedNames, contains('Beef Lagman'));
    });

    testWidgets('an existing product can be moved to another category', (
      tester,
    ) async {
      final repository = _FakeMenuItemRepository(
        initial: [
          buildMenuItem(name: 'Lagman', price: 250, categoryId: 'category-1'),
        ],
      );
      await pumpProductsPage(tester, repository);

      await tester.tap(
        find.byKey(const Key('editProductButton_menu-item-1')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('productCategoryField')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Desserts').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('productFormSubmitButton')));
      await tester.pumpAndSettle();

      expect(repository.updatedCategoryIds, contains('category-2'));
      expect(
        find.text('Desserts · Price: 250.00\nAvailable'),
        findsOneWidget,
      );
    });

    testWidgets('categories are loaded only for the current restaurant', (
      tester,
    ) async {
      final categoryRepository = _StubCategoryRepository();
      await pumpProductsPage(
        tester,
        _FakeMenuItemRepository(),
        categoryRepository: categoryRepository,
      );

      expect(categoryRepository.requestedRestaurantIds, isNotEmpty);
      expect(
        categoryRepository.requestedRestaurantIds.every(
          (restaurantId) => restaurantId == 'restaurant-1',
        ),
        isTrue,
        reason: 'Only categories of the current restaurant may be offered.',
      );
    });

    testWidgets('a product cannot be saved without a category', (
      tester,
    ) async {
      final repository = _FakeMenuItemRepository();
      await pumpProductsPage(
        tester,
        repository,
        categoryRepository: const _EmptyCategoryRepository(),
      );

      await tester.tap(find.byKey(const Key('addProductButton')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('productNameField')),
        'Uncategorised',
      );
      await tester.enterText(find.byKey(const Key('productPriceField')), '100');
      await tester.tap(find.byKey(const Key('productFormSubmitButton')));
      await tester.pump();

      expect(find.text('Create a category first.'), findsOneWidget);
      expect(repository.createdNames, isEmpty);
    });

    testWidgets('delete shows a confirmation dialog and removes the product', (
      tester,
    ) async {
      final repository = _FakeMenuItemRepository(
        initial: [buildMenuItem(name: 'Lagman')],
      );
      await pumpProductsPage(tester, repository);

      await tester.tap(
        find.byKey(const Key('deleteProductButton_menu-item-1')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Delete product?'), findsOneWidget);
      expect(find.text('Delete "Lagman"? This cannot be undone.'), findsOneWidget);
      expect(
        find.byKey(const Key('deleteProductCancelButton')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('deleteProductConfirmButton')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('deleteProductConfirmButton')));
      await tester.pumpAndSettle();

      expect(repository.deleteCalls, 1);
      expect(find.text('Lagman'), findsNothing);
      expect(find.text('No products yet'), findsOneWidget);
    });

    testWidgets('cancelling the delete dialog does not delete', (tester) async {
      final repository = _FakeMenuItemRepository(
        initial: [buildMenuItem(name: 'Lagman')],
      );
      await pumpProductsPage(tester, repository);

      await tester.tap(
        find.byKey(const Key('deleteProductButton_menu-item-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('deleteProductCancelButton')));
      await tester.pumpAndSettle();

      expect(repository.deleteCalls, 0);
      expect(find.text('Lagman'), findsOneWidget);
    });

    testWidgets('covers a constrained mobile width without errors', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = _FakeMenuItemRepository(
        initial: [
          buildMenuItem(name: 'Lagman', price: 250),
          buildMenuItem(
            id: 'menu-item-2',
            categoryId: 'category-2',
            name: 'A very long product name that should wrap without breaking',
            price: 999,
          ),
        ],
      );
      await pumpProductsPage(tester, repository);

      expect(tester.takeException(), isNull);
      expect(find.byType(Card), findsNWidgets(2));

      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('error messages', () {
    test('mutation errors are converted into safe messages', () {
      expect(
        menuItemMutationErrorMessage(ArgumentError('bad')),
        'Check the product details and try again.',
      );
      expect(
        menuItemMutationErrorMessage(
          const PostgrestException(
            message: 'new row violates check constraint',
            code: '23514',
          ),
        ),
        'Enter a price of 0 or more.',
      );
      expect(
        menuItemMutationErrorMessage(
          const PostgrestException(
            message: 'violates foreign key constraint "menu_items_category_id"',
            code: '23503',
          ),
        ),
        'Choose a category that still exists.',
      );
      expect(
        menuItemMutationErrorMessage(StateError('boom')),
        'We could not save this product. Please try again.',
      );
    });

    test('deletion errors are converted into safe messages', () {
      expect(
        menuItemDeleteErrorMessage(
          const PostgrestException(
            message: 'Invalid API key',
            code: '28000',
          ),
        ),
        'Your session has ended. Please sign in again.',
      );
      expect(
        menuItemDeleteErrorMessage(StateError('boom')),
        'We could not delete this product. Please try again.',
      );
    });
  });
}

class _FakeMenuItemRepository extends MenuItemRepository {
  _FakeMenuItemRepository({List<MenuItemModel>? initial})
    : menuItems = initial ?? [];

  List<MenuItemModel> menuItems;
  int deleteCalls = 0;
  final List<String> createdNames = [];
  final List<String> createdCategoryIds = [];
  final List<String> updatedNames = [];
  final List<String> updatedCategoryIds = [];

  @override
  Future<List<MenuItemModel>> getMenuItems(String restaurantId) async =>
      menuItems;

  @override
  Future<MenuItemModel?> createMenuItem({
    required String restaurantId,
    required String categoryId,
    required String name,
    required double price,
    bool isAvailable = true,
  }) async {
    createdNames.add(name);
    createdCategoryIds.add(categoryId);
    final item = MenuItemModel(
      id: 'menu-item-new-${menuItems.length}',
      restaurantId: restaurantId,
      categoryId: categoryId,
      name: name,
      price: price,
      isAvailable: isAvailable,
      isPopular: false,
      isNew: false,
      preparationTimeMinutes: 0,
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 9, 18),
      updatedAt: DateTime.utc(2026, 9, 18),
    );
    menuItems = [...menuItems, item];
    return item;
  }

  @override
  Future<MenuItemModel?> updateMenuItem({
    required String restaurantId,
    required String menuItemId,
    required String categoryId,
    required String name,
    required double price,
    required     bool isAvailable,
  }) async {
    updatedNames.add(name);
    updatedCategoryIds.add(categoryId);
    final updated = MenuItemModel(
      id: menuItemId,
      restaurantId: restaurantId,
      categoryId: categoryId,
      name: name,
      price: price,
      isAvailable: isAvailable,
      isPopular: false,
      isNew: false,
      preparationTimeMinutes: 0,
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 9, 18),
      updatedAt: DateTime.utc(2026, 9, 18),
    );
    menuItems = [
      for (final item in menuItems)
        if (item.id == menuItemId) updated else item,
    ];
    return updated;
  }

  @override
  Future<void> deleteMenuItem({
    required String restaurantId,
    required String menuItemId,
  }) async {
    deleteCalls++;
    menuItems = [
      for (final item in menuItems)
        if (item.id != menuItemId) item,
    ];
  }
}

class _EmptyCategoryRepository extends CategoryRepository {
  const _EmptyCategoryRepository();

  @override
  Future<List<CategoryModel>> getCategories(String restaurantId) async => [];
}

class _StubCategoryRepository extends CategoryRepository {
  _StubCategoryRepository({List<CategoryModel>? categories})
    : categories =
          categories ?? [buildCategory(), buildCategory(id: 'category-2', name: 'Desserts')];

  final List<CategoryModel> categories;

  /// Records the restaurant id of every load so scoping can be verified.
  final List<String> requestedRestaurantIds = [];

  @override
  Future<List<CategoryModel>> getCategories(String restaurantId) async {
    requestedRestaurantIds.add(restaurantId);
    return categories;
  }
}

class _PendingMenuItemRepository extends MenuItemRepository {
  _PendingMenuItemRepository(this.completer);

  final Completer<List<MenuItemModel>> completer;

  @override
  Future<List<MenuItemModel>> getMenuItems(String restaurantId) =>
      completer.future;
}

class _FailingMenuItemRepository extends MenuItemRepository {
  int failuresRemaining = 1;

  @override
  Future<List<MenuItemModel>> getMenuItems(String restaurantId) async {
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('network down');
    }
    return [];
  }
}