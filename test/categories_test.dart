import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/category_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/category_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/category_error_message.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/categories_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

CategoryModel buildCategory({
  String id = 'category-1',
  String name = 'Appetizers',
  int sortOrder = 0,
  bool isActive = true,
}) {
  return CategoryModel(
    id: id,
    restaurantId: 'restaurant-1',
    name: name,
    sortOrder: sortOrder,
    isActive: isActive,
    createdAt: DateTime.utc(2026, 9, 18),
    updatedAt: DateTime.utc(2026, 9, 18),
  );
}

Future<void> pumpCategoriesPage(
  WidgetTester tester,
  CategoryRepository repository,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CategoriesPage(
          restaurantId: 'restaurant-1',
          repository: repository,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('CategoryModel', () {
    test('parses a category row', () {
      final category = CategoryModel.fromJson({
        'id': 'category-1',
        'restaurant_id': 'restaurant-1',
        'branch_id': 'branch-1',
        'name': 'Appetizers',
        'description': 'Starter dishes',
        'image_url': 'https://example.com/appetizers.png',
        'sort_order': 3,
        'is_active': false,
        'created_at': '2026-09-18T00:00:00.000Z',
        'updated_at': '2026-09-18T00:00:00.000Z',
      });

      expect(category.id, 'category-1');
      expect(category.restaurantId, 'restaurant-1');
      expect(category.branchId, 'branch-1');
      expect(category.name, 'Appetizers');
      expect(category.description, 'Starter dishes');
      expect(category.imageUrl, 'https://example.com/appetizers.png');
      expect(category.sortOrder, 3);
      expect(category.isActive, isFalse);
      expect(category.createdAt, DateTime.utc(2026, 9, 18));
      expect(category.updatedAt, DateTime.utc(2026, 9, 18));
    });

    test('mutation payload only carries editable columns', () {
      final category = buildCategory(name: 'Soups', sortOrder: 2);

      expect(category.toMutationJson(), {
        'name': 'Soups',
        'sort_order': 2,
        'is_active': true,
      });
    });
  });

  group('validation', () {
    test('category name is required and enforced to a maximum length', () {
      expect(validateCategoryName(null), 'Enter a category name.');
      expect(validateCategoryName('   '), 'Enter a category name.');
      expect(validateCategoryName('Appetizers'), isNull);
      expect(validateCategoryName('  Soups  '), isNull);
      expect(
        validateCategoryName('A' * (maxCategoryNameLength + 1)),
        'Category name must be $maxCategoryNameLength characters or fewer.',
      );
    });

    test('sort order matches the database non-negative constraint', () {
      expect(validateCategorySortOrder(null), 'Enter a sort order.');
      expect(validateCategorySortOrder('  '), 'Enter a sort order.');
      expect(
        validateCategorySortOrder('-1'),
        'Sort order must be a whole number of 0 or more.',
      );
      expect(
        validateCategorySortOrder('abc'),
        'Sort order must be a whole number of 0 or more.',
      );
      expect(validateCategorySortOrder('0'), isNull);
      expect(validateCategorySortOrder('7'), isNull);
    });
  });

  group('CategoryRepository', () {
    late SupabaseClient client;

    setUp(() {
      client = SupabaseClient('http://localhost:54321', 'test-anon-key');
    });

    tearDown(() => client.dispose());

    test('avoids database calls when unauthenticated', () async {
      final repository = CategoryRepository.withClient(client);

      expect(await repository.getCategories('restaurant-1'), isEmpty);
      expect(
        await repository.createCategory(
          restaurantId: 'restaurant-1',
          name: 'Soups',
        ),
        isNull,
      );
      expect(
        await repository.updateCategory(
          restaurantId: 'restaurant-1',
          categoryId: 'category-1',
          name: 'Soups',
          sortOrder: 1,
          isActive: true,
        ),
        isNull,
      );
      await repository.deleteCategory(
        restaurantId: 'restaurant-1',
        categoryId: 'category-1',
      );
    });
  });

  group('CategoriesPage', () {
    testWidgets('shows an empty state when there are no categories', (
      tester,
    ) async {
      await pumpCategoriesPage(tester, FakeCategoryRepository());

      expect(find.text('No categories yet'), findsOneWidget);
      expect(find.text('Add category'), findsWidgets);
      expect(find.byKey(const Key('emptyAddCategoryButton')), findsOneWidget);
    });

    testWidgets('renders categories with status, sort order, and actions', (
      tester,
    ) async {
      final repository = FakeCategoryRepository(
        initial: [
          buildCategory(name: 'Appetizers', sortOrder: 0, isActive: true),
          buildCategory(
            id: 'category-2',
            name: 'Desserts',
            sortOrder: 1,
            isActive: false,
          ),
        ],
      );
      await pumpCategoriesPage(tester, repository);

      expect(find.text('Appetizers'), findsOneWidget);
      expect(find.text('Desserts'), findsOneWidget);
      expect(find.text('Active · Sort order: 0'), findsOneWidget);
      expect(find.text('Inactive · Sort order: 1'), findsOneWidget);
      expect(
        find.byKey(const Key('editCategoryButton_category-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('deleteCategoryButton_category-1')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('addCategoryButton')), findsOneWidget);
    });

    testWidgets('shows an error state and retries', (tester) async {
      final repository = _FailingCategoryRepository();
      await pumpCategoriesPage(tester, repository);

      expect(
        find.text('We could not load your categories. Please try again.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('categoriesRetryButton')), findsOneWidget);

      repository.failuresRemaining = 0;
      await tester.tap(find.byKey(const Key('categoriesRetryButton')));
      await tester.pumpAndSettle();

      expect(find.text('No categories yet'), findsOneWidget);
    });

    testWidgets('add category dialog renders all required fields', (
      tester,
    ) async {
      await pumpCategoriesPage(tester, FakeCategoryRepository());

      await tester.tap(find.byKey(const Key('addCategoryButton')));
      await tester.pumpAndSettle();

      expect(find.text('Add category'), findsWidgets);
      expect(find.byKey(const Key('categoryNameField')), findsOneWidget);
      expect(
        find.byKey(const Key('categorySortOrderField')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('categoryActiveSwitch')), findsOneWidget);
      expect(
        find.byKey(const Key('categoryFormSubmitButton')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('categoryFormCancelButton')),
        findsOneWidget,
      );
    });

    testWidgets('add category dialog validates required fields', (
      tester,
    ) async {
      await pumpCategoriesPage(tester, FakeCategoryRepository());

      await tester.tap(find.byKey(const Key('addCategoryButton')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('categoryFormSubmitButton')));
      await tester.pump();

      expect(find.text('Enter a category name.'), findsOneWidget);
    });

    testWidgets('edit category dialog is prefilled and saves', (tester) async {
      final repository = FakeCategoryRepository(
        initial: [buildCategory(name: 'Soups', sortOrder: 2)],
      );
      await pumpCategoriesPage(tester, repository);

      await tester.tap(
        find.byKey(const Key('editCategoryButton_category-1')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit category'), findsOneWidget);
      final nameField = tester.widget<TextFormField>(
        find.byKey(const Key('categoryNameField')),
      );
      final sortOrderField = tester.widget<TextFormField>(
        find.byKey(const Key('categorySortOrderField')),
      );
      expect(nameField.controller?.text, 'Soups');
      expect(sortOrderField.controller?.text, '2');

      await tester.enterText(
        find.byKey(const Key('categoryNameField')),
        'Hot Soups',
      );
      await tester.tap(find.byKey(const Key('categoryFormSubmitButton')));
      await tester.pumpAndSettle();

      expect(find.text('Hot Soups'), findsOneWidget);
      expect(repository.updatedNames, contains('Hot Soups'));
    });

    testWidgets('a created category appears in the list and is persisted', (
      tester,
    ) async {
      final repository = FakeCategoryRepository();
      await pumpCategoriesPage(tester, repository);

      await tester.tap(find.byKey(const Key('addCategoryButton')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('categoryNameField')),
        'Drinks',
      );
      await tester.tap(find.byKey(const Key('categoryFormSubmitButton')));
      await tester.pumpAndSettle();

      expect(find.text('Drinks'), findsOneWidget);
      expect(repository.createdNames, contains('Drinks'));
    });

    testWidgets('delete shows a confirmation dialog and removes the category', (
      tester,
    ) async {
      final repository = FakeCategoryRepository(
        initial: [buildCategory(name: 'Soups')],
      );
      await pumpCategoriesPage(tester, repository);

      await tester.tap(
        find.byKey(const Key('deleteCategoryButton_category-1')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Delete category?'), findsOneWidget);
      expect(find.text('Delete "Soups"? This cannot be undone.'), findsOneWidget);
      expect(
        find.byKey(const Key('deleteCategoryCancelButton')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('deleteCategoryConfirmButton')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('deleteCategoryConfirmButton')));
      await tester.pumpAndSettle();

      expect(repository.deleteCalls, 1);
      expect(find.text('Soups'), findsNothing);
      expect(find.text('No categories yet'), findsOneWidget);
    });

    testWidgets('scopes every operation to the page restaurant', (
      tester,
    ) async {
      final repository = FakeCategoryRepository(
        initial: [buildCategory(name: 'Soups')],
      );
      await pumpCategoriesPage(tester, repository);

      await tester.tap(find.byKey(const Key('addCategoryButton')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('categoryNameField')),
        'Drinks',
      );
      await tester.tap(find.byKey(const Key('categoryFormSubmitButton')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('editCategoryButton_category-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('categoryFormSubmitButton')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('deleteCategoryButton_category-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('deleteCategoryConfirmButton')));
      await tester.pumpAndSettle();

      expect(repository.deleteCalls, 1);
      expect(repository.requestedRestaurantIds, isNotEmpty);
      expect(
        repository.requestedRestaurantIds.every(
          (restaurantId) => restaurantId == 'restaurant-1',
        ),
        isTrue,
        reason: 'Categories must never be read or mutated for another '
            'restaurant.',
      );
    });

    testWidgets('cancelling the delete dialog does not delete', (tester) async {
      final repository = FakeCategoryRepository(
        initial: [buildCategory(name: 'Soups')],
      );
      await pumpCategoriesPage(tester, repository);

      await tester.tap(
        find.byKey(const Key('deleteCategoryButton_category-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('deleteCategoryCancelButton')));
      await tester.pumpAndSettle();

      expect(repository.deleteCalls, 0);
      expect(find.text('Soups'), findsOneWidget);
    });
  });

  group('error messages', () {
    test('mutation errors are converted into safe messages', () {
      expect(categoryMutationErrorMessage(ArgumentError('bad')),
          'Check the category details and try again.');
      expect(
        categoryMutationErrorMessage(
          const PostgrestException(
            message: 'new row violates check constraint',
            code: '23514',
          ),
        ),
        'Enter a sort order of 0 or more.',
      );
      expect(
        categoryMutationErrorMessage(StateError('boom')),
        'We could not save this category. Please try again.',
      );
    });

    test('deletion errors explain related records', () {
      expect(
        categoryDeleteErrorMessage(
          const PostgrestException(
            message: 'on table "categories" violates foreign key constraint',
            code: '23503',
          ),
        ),
        'This category is used by menu items and cannot be deleted yet.',
      );
      expect(
        categoryDeleteErrorMessage(StateError('boom')),
        'We could not delete this category. Please try again.',
      );
    });
  });
}

class FakeCategoryRepository extends CategoryRepository {
  FakeCategoryRepository({List<CategoryModel>? initial})
    : categories = initial ?? [];

  List<CategoryModel> categories;
  int deleteCalls = 0;
  final List<String> createdNames = [];
  final List<String> updatedNames = [];

  /// Records the restaurant id of every call so scoping can be verified.
  final List<String> requestedRestaurantIds = [];

  @override
  Future<List<CategoryModel>> getCategories(String restaurantId) async {
    requestedRestaurantIds.add(restaurantId);
    return categories;
  }

  @override
  Future<CategoryModel?> createCategory({
    required String restaurantId,
    required String name,
    int sortOrder = 0,
    bool isActive = true,
  }) async {
    requestedRestaurantIds.add(restaurantId);
    createdNames.add(name);
    final category = CategoryModel(
      id: 'category-new-${categories.length}',
      restaurantId: restaurantId,
      name: name,
      sortOrder: sortOrder,
      isActive: isActive,
      createdAt: DateTime.utc(2026, 9, 18),
      updatedAt: DateTime.utc(2026, 9, 18),
    );
    categories = [...categories, category];
    return category;
  }

  @override
  Future<CategoryModel?> updateCategory({
    required String restaurantId,
    required String categoryId,
    required String name,
    required int sortOrder,
    required bool isActive,
  }) async {
    requestedRestaurantIds.add(restaurantId);
    updatedNames.add(name);
    final updated = CategoryModel(
      id: categoryId,
      restaurantId: restaurantId,
      name: name,
      sortOrder: sortOrder,
      isActive: isActive,
      createdAt: DateTime.utc(2026, 9, 18),
      updatedAt: DateTime.utc(2026, 9, 18),
    );
    categories = [
      for (final category in categories)
        if (category.id == categoryId) updated else category,
    ];
    return updated;
  }

  @override
  Future<void> deleteCategory({
    required String restaurantId,
    required String categoryId,
  }) async {
    requestedRestaurantIds.add(restaurantId);
    deleteCalls++;
    categories = [
      for (final category in categories)
        if (category.id != categoryId) category,
    ];
  }
}

class _FailingCategoryRepository extends CategoryRepository {
  int failuresRemaining = 1;

  @override
  Future<List<CategoryModel>> getCategories(String restaurantId) async {
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('network down');
    }
    return [];
  }
}