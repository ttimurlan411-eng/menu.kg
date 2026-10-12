import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:menukg_flutter/app/router/app_router.dart';
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/repositories/public_menu_repository.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/pages/public_menu_page.dart';
import 'package:menukg_flutter/features/customer/product/presentation/pages/product_details_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/public_menu_test_data.dart';

Future<void> pumpProduct(
  WidgetTester tester,
  PublicMenuRepository repository, {
  required String itemId,
  String qrToken = validQrToken,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProductDetailsPage(
          qrToken: qrToken,
          itemId: itemId,
          repository: repository,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('PublicMenuModel.findItemById', () {
    test('finds an item together with its category', () {
      final menu = PublicMenuModel.fromJson(buildMenuJson());

      final found = menu.findItemById('item-3');

      expect(found, isNotNull);
      expect(found!.item.name, 'Kebab');
      expect(found.category.name, 'Mains');
    });

    test('does not find unknown, foreign or unavailable ids', () {
      final menu = PublicMenuModel.fromJson(buildMenuJson());

      expect(menu.findItemById('does-not-exist'), isNull);
      // An id from another restaurant is not in this menu.
      expect(menu.findItemById('other-restaurant-item'), isNull);
      // Unavailable dishes never enter the payload.
      expect(menu.findItemById('sold-out-item'), isNull);
      expect(menu.findItemById(''), isNull);
    });

    test('an empty menu finds nothing', () {
      final menu = PublicMenuModel.fromJson(
        buildMenuJson(categories: const []),
      );
      expect(menu.findItemById('item-1'), isNull);
    });
  });

  group('ProductDetailsPage', () {
    testWidgets('shows name, category, price, description and status', (
      tester,
    ) async {
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
        itemId: 'item-1',
      );

      expect(find.text('Beshbarmak'), findsOneWidget);
      expect(find.text('STARTERS'), findsOneWidget);
      expect(find.byKey(const Key('productPrice')), findsOneWidget);
      expect(find.text('450.00 KGS'), findsOneWidget);
      expect(find.text('Boiled lamb with noodles'), findsOneWidget);
      expect(find.byKey(const Key('productAvailabilityBadge')), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
      expect(
        find.byKey(const Key('productPreparationTime')),
        findsOneWidget,
      );
      expect(find.text('About 20 min'), findsOneWidget);
    });

    testWidgets('shows the struck-through old price for a discounted dish', (
      tester,
    ) async {
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
        itemId: 'item-1',
      );

      expect(find.byKey(const Key('productPrice')), findsOneWidget);
      expect(find.text('450.00 KGS'), findsOneWidget);
      expect(find.byKey(const Key('productOldPrice')), findsOneWidget);
      expect(find.text('500.00 KGS'), findsOneWidget);
    });

    testWidgets('shows no old price for a dish that is not discounted', (
      tester,
    ) async {
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
        itemId: 'item-2',
      );

      expect(find.text('Fresh Salad'), findsOneWidget);
      expect(find.byKey(const Key('productPrice')), findsOneWidget);
      expect(find.text('250.00 KGS'), findsOneWidget);
      expect(find.byKey(const Key('productOldPrice')), findsNothing);
    });

    testWidgets('keeps the restaurant and table context', (tester) async {
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
        itemId: 'item-1',
      );

      expect(find.text('Ala-Too · Table 12 · Window'), findsOneWidget);
    });

    testWidgets('a dish without a photo shows a placeholder', (tester) async {
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
        itemId: 'item-1',
      );

      // item-1 has no main_image_url, so no network image is attempted.
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.restaurant_outlined), findsWidgets);
    });

    testWidgets('shows the dish photo when the menu provides one', (
      tester,
    ) async {
      // item-3 carries a main_image_url, so the page renders the real photo
      // rather than the placeholder.
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
        itemId: 'item-3',
      );

      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as NetworkImage).url, 'https://cdn.example/kebab.jpg');
    });

    testWidgets('a photo that fails to load falls back to a placeholder', (
      tester,
    ) async {
      // item-3 has a main_image_url that cannot resolve in a test.
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
        itemId: 'item-3',
      );

      expect(find.byIcon(Icons.restaurant_outlined), findsWidgets);
      expect(find.text('Kebab'), findsOneWidget);
    });

    testWidgets('an unknown product shows a safe message', (tester) async {
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
        itemId: 'not-a-real-item',
      );

      expect(
        find.text('This dish is no longer available.'),
        findsOneWidget,
      );
      expect(find.byType(ProductDetailsPage), findsOneWidget);
    });

    testWidgets('a product that is no longer available is not shown', (
      tester,
    ) async {
      // The menu reloaded from the database no longer contains the dish, which
      // is how a sold-out or deactivated product reaches this state.
      await pumpProduct(
        tester,
        FakePublicMenuRepository(
          buildMenuJson(categories: const []),
        ),
        itemId: 'item-1',
      );

      expect(
        find.text('This dish is no longer available.'),
        findsOneWidget,
      );
      expect(find.text('Beshbarmak'), findsNothing);
      expect(find.text('450.00 KGS'), findsNothing);
    });

    testWidgets('missing or invalid context is handled safely', (
      tester,
    ) async {
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson(), resolvesToNothing: true),
        itemId: 'item-1',
      );

      expect(
        find.text('This dish is no longer available.'),
        findsOneWidget,
      );
      expect(find.text('Beshbarmak'), findsNothing);
    });

    testWidgets('shows a loading state while resolving the product', (
      tester,
    ) async {
      final completer = Completer<PublicMenuModel?>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProductDetailsPage(
              qrToken: validQrToken,
              itemId: 'item-1',
              repository: PendingPublicMenuRepository(completer),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Loading product...'), findsOneWidget);

      completer.complete(PublicMenuModel.fromJson(buildMenuJson()));
      await tester.pumpAndSettle();
      expect(find.text('Beshbarmak'), findsOneWidget);
    });

    testWidgets('database errors are safe and can be retried', (tester) async {
      final repository = FakePublicMenuRepository(
        buildMenuJson(),
        failuresRemaining: 1,
      );
      await pumpProduct(tester, repository, itemId: 'item-1');

      expect(
        find.text('We could not load this menu. Please try again.'),
        findsOneWidget,
      );
      expect(find.text('Beshbarmak'), findsNothing);

      repository.failuresRemaining = 0;
      await tester.tap(find.byKey(const Key('productRetryButton')));
      await tester.pumpAndSettle();

      expect(find.text('Beshbarmak'), findsOneWidget);
    });

    testWidgets('a database error never leaks internals', (tester) async {
      await pumpProduct(
        tester,
        FakePublicMenuRepository(
          buildMenuJson(),
          error: const PostgrestException(
            message:
                'permission denied for function '
                'public_menu_by_qr_token at public.public_menu_by_qr_token',
            code: '42501',
          ),
        ),
        itemId: 'item-1',
      );

      expect(
        find.text('This menu is not available right now.'),
        findsOneWidget,
      );
      expect(find.textContaining('permission denied'), findsNothing);
      expect(find.textContaining('public_menu_by_qr_token'), findsNothing);
      expect(find.textContaining('PostgrestException'), findsNothing);
    });

    testWidgets('never shows internal ids or the qr token', (tester) async {
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
        itemId: 'item-1',
      );

      expect(find.textContaining(validQrToken), findsNothing);
      expect(find.textContaining('category-1'), findsNothing);
      expect(find.textContaining('item-1'), findsNothing);
      // The table number is a display label, not the table row id.
      expect(find.textContaining('Table 12'), findsOneWidget);
    });

    testWidgets('offers a cart action but no ordering or account action', (
      tester,
    ) async {
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
        itemId: 'item-1',
      );

      // The dish can go into the local cart of this table...
      expect(find.byKey(const Key('addToCartButton')), findsOneWidget);
      expect(find.text('Add to cart'), findsOneWidget);
      // ...but nothing is ordered, paid for or signed in to.
      expect(find.textContaining('Checkout'), findsNothing);
      expect(find.textContaining('Place order'), findsNothing);
      expect(find.textContaining('Pay'), findsNothing);
      expect(find.textContaining('Sign in'), findsNothing);
    });

    testWidgets('an unavailable dish cannot be added to a cart', (
      tester,
    ) async {
      // A sold-out dish, and an id belonging to another restaurant, both fail to
      // resolve in the reloaded menu, so no cart action is offered at all.
      for (final itemId in ['sold-out-item', 'other-restaurant-item']) {
        await pumpProduct(
          tester,
          FakePublicMenuRepository(buildMenuJson()),
          itemId: itemId,
        );

        expect(
          find.text('This dish is no longer available.'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('addToCartButton')), findsNothing);
      }
    });

    testWidgets('needs no authentication and no Supabase session', (
      tester,
    ) async {
      // Nothing is initialised here, so any attempt to reach Supabase or an
      // auth gate would fail. A plain fake repository is enough.
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
        itemId: 'item-1',
      );

      expect(find.text('Beshbarmak'), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);
      expect(find.text('Log in'), findsNothing);
    });
  });

  group('product scoping', () {
    // A real SupabaseClient must be built in the real zone, never inside a
    // widget test: it spawns a JSON isolate whose handshake only the real event
    // loop can finish, and `testWidgets` runs the body in a fake-async zone, so
    // the test would never complete.
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

    testWidgets('a product id from another restaurant is not resolved', (
      tester,
    ) async {
      await pumpProduct(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
        // A real uuid belonging to a different restaurant's dish.
        itemId: 'e0000000-0000-0000-0000-0000000000ff',
      );

      expect(
        find.text('This dish is no longer available.'),
        findsOneWidget,
      );
      expect(find.text('Beshbarmak'), findsNothing);
      expect(find.text('Kebab'), findsNothing);
    });

    testWidgets('resolves using only the qr token, with no new access path', (
      tester,
    ) async {
      await pumpProduct(
        tester,
        PublicMenuRepository.withClient(rpcSupabaseClient),
        itemId: 'item-1',
      );

      // The only request is the existing public menu rpc. No anon SELECT on
      // menu_items and no product endpoint were introduced.
      expect(rpcHttpClient.requests, hasLength(1));
      expect(
        rpcHttpClient.requests.single.url.path,
        contains('/rpc/${PublicMenuRepository.functionName}'),
      );
      expect(rpcHttpClient.requests.single.method, 'POST');
      expect(
        jsonDecode(rpcHttpClient.requestBodies.single!),
        {'p_qr_token': validQrToken},
      );
      expect(find.text('Beshbarmak'), findsOneWidget);
    });

    test('no route can open a product by id alone', () {
      // The only public route is the table menu, so a url carrying a bare
      // product id resolves to nothing and cannot be turned into a page.
      const productId = 'e0000000-0000-0000-0000-0000000000ff';
      expect(AppRouter.parsePublicMenuQrToken('/product/$productId'), isNull);
      expect(
        AppRouter.onGenerateRoute(
          const RouteSettings(name: '/product/$productId'),
        ),
        isNull,
      );
      expect(AppRouter.parsePublicMenuQrToken('/p/$productId'), isNull);
    });
  });

  group('navigation from the public menu', () {
    testWidgets('tapping a product opens its details', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PublicMenuPage(
              qrToken: validQrToken,
              repository: FakePublicMenuRepository(buildMenuJson()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Beshbarmak'), findsOneWidget);
      expect(find.byType(ProductDetailsPage), findsNothing);

      await tester.tap(find.byKey(const Key('menuItem_item-1')));
      await tester.pumpAndSettle();

      expect(find.byType(ProductDetailsPage), findsOneWidget);
      expect(find.byType(PublicMenuPage), findsNothing);
      expect(find.text('Boiled lamb with noodles'), findsOneWidget);
    });

    testWidgets('passes the scanned qr token to the product page', (
      tester,
    ) async {
      final repository = FakePublicMenuRepository(buildMenuJson());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PublicMenuPage(
              qrToken: validQrToken,
              repository: repository,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('menuItem_item-3')));
      await tester.pumpAndSettle();

      // The menu page loaded once, the product page re-resolved the same token.
      expect(
        repository.requestedTokens,
        everyElement(validQrToken),
      );
      expect(repository.requestedTokens, hasLength(2));
      expect(find.text('Kebab'), findsOneWidget);
      expect(find.text('MAINS'), findsOneWidget);
    });

    testWidgets('back navigation returns to the public menu', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PublicMenuPage(
              qrToken: validQrToken,
              repository: FakePublicMenuRepository(buildMenuJson()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('menuItem_item-1')));
      await tester.pumpAndSettle();
      expect(find.byType(ProductDetailsPage), findsOneWidget);

      // System back, the same gesture an Android guest uses.
      final NavigatorState navigator = tester.state(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();

      expect(find.byType(ProductDetailsPage), findsNothing);
      expect(find.byType(PublicMenuPage), findsOneWidget);
      expect(find.text('Beshbarmak'), findsOneWidget);
    });

    testWidgets('back navigation restores the active category filter', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PublicMenuPage(
              qrToken: validQrToken,
              repository: FakePublicMenuRepository(buildMenuJson()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('categoryChip_category-2')));
      await tester.pumpAndSettle();
      expect(find.text('Kebab'), findsOneWidget);
      expect(find.text('Beshbarmak'), findsNothing);

      await tester.tap(find.byKey(const Key('menuItem_item-3')));
      await tester.pumpAndSettle();
      expect(find.byType(ProductDetailsPage), findsOneWidget);

      final NavigatorState navigator = tester.state(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();

      // The guest lands back on the same filtered menu, not a reset menu.
      expect(find.byType(PublicMenuPage), findsOneWidget);
      expect(find.text('Kebab'), findsOneWidget);
      expect(find.text('Beshbarmak'), findsNothing);
    });

    testWidgets('the product page has a back affordance', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PublicMenuPage(
              qrToken: validQrToken,
              repository: FakePublicMenuRepository(buildMenuJson()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('menuItem_item-1')));
      await tester.pumpAndSettle();

      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(PublicMenuPage), findsOneWidget);
    });
  });
}
