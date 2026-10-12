import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/repositories/public_menu_repository.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/pages/public_menu_page.dart';
import 'package:menukg_flutter/features/customer/product/presentation/pages/product_details_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/public_menu_test_data.dart';

Future<void> pumpMenu(
  WidgetTester tester,
  PublicMenuRepository repository, {
  String qrToken = validQrToken,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PublicMenuPage(qrToken: qrToken, repository: repository),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The two categories of [buildMenuJson], as raw json.
List<Map<String, dynamic>> get _categories =>
    buildMenuJson()['categories'] as List<Map<String, dynamic>>;

/// A payload that also carries a category the database would never return,
/// because it has no available dishes.
Map<String, dynamic> buildMenuJsonWithEmptyCategory() {
  return buildMenuJson(
    categories: [
      ..._categories,
      {
        'id': 'category-empty',
        'name': 'Sold out',
        'description': null,
        'image_url': null,
        'items': <Map<String, dynamic>>[],
      },
    ],
  );
}

/// Whether the chip for [categoryId] is the selected one.
bool isChipSelected(WidgetTester tester, Key key) {
  return tester.widget<FilterChip>(find.byKey(key)).selected;
}

void main() {
  group('category availability', () {
    test('a category with no dishes is dropped from the menu', () {
      final menu = PublicMenuModel.fromJson(buildMenuJsonWithEmptyCategory());

      expect(menu.categories, hasLength(2));
      expect(
        menu.categories.map((category) => category.name),
        isNot(contains('Sold out')),
      );
      expect(menu.itemCount, 3);
    });

    test('a menu whose only categories are empty reads as empty', () {
      final menu = PublicMenuModel.fromJson(
        buildMenuJson(
          categories: [
            {
              'id': 'category-empty',
              'name': 'Sold out',
              'description': null,
              'image_url': null,
              'items': <Map<String, dynamic>>[],
            },
          ],
        ),
      );

      expect(menu.categories, isEmpty);
      expect(menu.isEmpty, isTrue);
      expect(menu.itemCount, 0);
      expect(menu.allItems, isEmpty);
      expect(menu.offersCategory('category-empty'), isFalse);
    });

    test('offersCategory matches only categories in the menu', () {
      final menu = PublicMenuModel.fromJson(buildMenuJson());

      expect(menu.offersCategory('category-1'), isTrue);
      expect(menu.offersCategory('category-2'), isTrue);
      // A category that was emptied or deleted is not offered any more.
      expect(menu.offersCategory('category-empty'), isFalse);
      expect(menu.offersCategory('other-restaurant-category'), isFalse);
      // null means "All categories", which is always available.
      expect(menu.offersCategory(null), isFalse);
    });
  });

  group('category navigation', () {
    testWidgets('renders a chip for every category plus All', (tester) async {
      await pumpMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      expect(find.byKey(const Key('categoryChip_all')), findsOneWidget);
      expect(find.byKey(const Key('categoryChip_category-1')), findsOneWidget);
      expect(find.byKey(const Key('categoryChip_category-2')), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Starters'), findsOneWidget);
      expect(find.text('Mains'), findsOneWidget);
    });

    testWidgets('All is selected first and shows every product', (
      tester,
    ) async {
      await pumpMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      expect(isChipSelected(tester, const Key('categoryChip_all')), isTrue);
      expect(find.text('Beshbarmak'), findsOneWidget);
      expect(find.text('Fresh Salad'), findsOneWidget);
      expect(find.text('Kebab'), findsOneWidget);
    });

    testWidgets('selecting a category shows only its products', (
      tester,
    ) async {
      await pumpMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      await tester.tap(find.byKey(const Key('categoryChip_category-2')));
      await tester.pumpAndSettle();

      expect(isChipSelected(tester, const Key('categoryChip_category-2')), isTrue);
      expect(isChipSelected(tester, const Key('categoryChip_all')), isFalse);
      expect(find.text('Kebab'), findsOneWidget);
      // The section header describes the filtered category only.
      expect(find.text('Mains · 1 item · 600.00 KGS'), findsOneWidget);
    });

    testWidgets('products of another category are not shown', (tester) async {
      await pumpMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      await tester.tap(find.byKey(const Key('categoryChip_category-2')));
      await tester.pumpAndSettle();

      expect(find.text('Beshbarmak'), findsNothing);
      expect(find.text('Fresh Salad'), findsNothing);
      expect(find.text('Starters · 2 items · 250.00 KGS'), findsNothing);
    });

    testWidgets('selecting All restores every product', (tester) async {
      await pumpMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      await tester.tap(find.byKey(const Key('categoryChip_category-2')));
      await tester.pumpAndSettle();
      expect(find.text('Beshbarmak'), findsNothing);

      await tester.tap(find.byKey(const Key('categoryChip_all')));
      await tester.pumpAndSettle();

      expect(isChipSelected(tester, const Key('categoryChip_all')), isTrue);
      expect(find.text('Beshbarmak'), findsOneWidget);
      expect(find.text('Fresh Salad'), findsOneWidget);
      expect(find.text('Kebab'), findsOneWidget);
      expect(find.text('Starters · 2 items · 250.00 KGS'), findsOneWidget);
      expect(find.text('Mains · 1 item · 600.00 KGS'), findsOneWidget);
    });

    testWidgets('tapping the selected chip again returns to All', (
      tester,
    ) async {
      await pumpMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      await tester.tap(find.byKey(const Key('categoryChip_category-1')));
      await tester.pumpAndSettle();
      expect(find.text('Fresh Salad'), findsOneWidget);
      expect(find.text('Kebab'), findsNothing);

      await tester.tap(find.byKey(const Key('categoryChip_category-1')));
      await tester.pumpAndSettle();

      expect(isChipSelected(tester, const Key('categoryChip_all')), isTrue);
      expect(find.text('Kebab'), findsOneWidget);
    });

    testWidgets('categories keep a comfortable touch target', (tester) async {
      await pumpMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      // The Material minimum tap target, so filtering works with a thumb.
      expect(
        tester.getSize(find.byKey(const Key('categoryChip_category-1'))).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('a category with no available products is not shown', (
      tester,
    ) async {
      await pumpMenu(
        tester,
        FakePublicMenuRepository(buildMenuJsonWithEmptyCategory()),
      );

      // No chip and no section for the emptied category.
      expect(find.byKey(const Key('categoryChip_category-empty')), findsNothing);
      expect(find.text('Sold out'), findsNothing);
      // The rest of the menu is unaffected.
      expect(find.text('Beshbarmak'), findsOneWidget);
      expect(find.text('Kebab'), findsOneWidget);
    });

    testWidgets('a menu of only empty categories shows the empty state', (
      tester,
    ) async {
      await pumpMenu(
        tester,
        FakePublicMenuRepository(
          buildMenuJson(
            categories: [
              {
                'id': 'category-empty',
                'name': 'Sold out',
                'description': null,
                'image_url': null,
                'items': <Map<String, dynamic>>[],
              },
            ],
          ),
        ),
      );

      // No category survived, so the guest is told the menu is being updated
      // rather than being shown an empty category section.
      expect(
        find.byKey(const Key('publicMenuEmptyMessage')),
        findsOneWidget,
      );
      expect(find.text('Sold out'), findsNothing);
      expect(find.byType(FilterChip), findsNothing);
    });

    testWidgets('an invalid qr shows no categories and a safe message', (
      tester,
    ) async {
      await pumpMenu(
        tester,
        FakePublicMenuRepository(buildMenuJson(), resolvesToNothing: true),
      );

      expect(find.byType(FilterChip), findsNothing);
      expect(
        find.text('This menu is not available right now.'),
        findsOneWidget,
      );
      expect(find.textContaining('uuid'), findsNothing);
    });
  });

  group('filtering stays local', () {
    // A real SupabaseClient must be built in the real zone: it spawns a JSON
    // isolate whose handshake only the real event loop can finish, and
    // `testWidgets` runs the body in a fake-async zone.
    late RecordingHttpClient rpcHttpClient;
    late SupabaseClient rpcSupabaseClient;

    setUpAll(() {
      rpcHttpClient = RecordingHttpClient((request, body) async {
        return http.Response(
          jsonEncode(buildMenuJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      rpcSupabaseClient = buildSupabaseTestClient(rpcHttpClient);
    });

    tearDownAll(() => rpcSupabaseClient.dispose());

    testWidgets('changing categories never re-reads the menu', (tester) async {
      final repository = FakePublicMenuRepository(buildMenuJson());
      await pumpMenu(tester, repository);

      await tester.tap(find.byKey(const Key('categoryChip_category-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('categoryChip_category-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('categoryChip_all')));
      await tester.pumpAndSettle();

      // One load for the whole session, and only the scanned token was used.
      expect(repository.requestedTokens, [validQrToken]);
    });

    testWidgets('filtering makes no rpc request at all', (tester) async {
      await pumpMenu(
        tester,
        PublicMenuRepository.withClient(rpcSupabaseClient),
      );

      await tester.tap(find.byKey(const Key('categoryChip_category-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('categoryChip_category-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('categoryChip_all')));
      await tester.pumpAndSettle();

      // The only request is the initial public menu rpc: category taps are
      // answered from the already loaded model.
      expect(rpcHttpClient.requests, hasLength(1));
      expect(
        rpcHttpClient.requests.single.url.path,
        contains('/rpc/${PublicMenuRepository.functionName}'),
      );
      expect(find.text('Beshbarmak'), findsOneWidget);
    });
  });

  group('navigation from a filtered menu', () {
    testWidgets('a filtered product opens details with the qr token', (
      tester,
    ) async {
      final repository = FakePublicMenuRepository(buildMenuJson());
      await pumpMenu(tester, repository);

      await tester.tap(find.byKey(const Key('categoryChip_category-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menuItem_item-3')));
      await tester.pumpAndSettle();

      expect(find.byType(ProductDetailsPage), findsOneWidget);
      expect(find.text('Kebab'), findsOneWidget);
      // The menu loaded once and the product page re-resolved the same token.
      expect(repository.requestedTokens, [validQrToken, validQrToken]);
    });

    testWidgets('back returns to the same filtered menu', (tester) async {
      await pumpMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      await tester.tap(find.byKey(const Key('categoryChip_category-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menuItem_item-3')));
      await tester.pumpAndSettle();
      expect(find.byType(ProductDetailsPage), findsOneWidget);

      final NavigatorState navigator = tester.state(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();

      expect(find.byType(PublicMenuPage), findsOneWidget);
      expect(isChipSelected(tester, const Key('categoryChip_category-2')), isTrue);
      expect(find.text('Kebab'), findsOneWidget);
      expect(find.text('Beshbarmak'), findsNothing);
    });

    testWidgets('the filter never leaks internal ids', (tester) async {
      await pumpMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      await tester.tap(find.byKey(const Key('categoryChip_category-2')));
      await tester.pumpAndSettle();

      expect(find.textContaining('category-2'), findsNothing);
      expect(find.textContaining(validQrToken), findsNothing);
    });
  });
}
