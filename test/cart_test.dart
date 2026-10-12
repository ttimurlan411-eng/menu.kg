import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:menukg_flutter/app/router/app_router.dart';
import 'package:menukg_flutter/features/customer/cart/data/cart_controller.dart';
import 'package:menukg_flutter/features/customer/cart/data/models/cart_model.dart';
import 'package:menukg_flutter/features/customer/cart/presentation/pages/cart_page.dart';
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/repositories/public_menu_repository.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/pages/public_menu_page.dart';
import 'package:menukg_flutter/features/customer/product/presentation/pages/product_details_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/public_menu_test_data.dart';

/// A second table, to prove a cart never mixes tables.
const String otherQrToken = '9ab7c6d5-1f3e-4a2b-8c9d-0e1f2a3b4c5d';

PublicMenuModel buildMenu([Map<String, dynamic>? json]) =>
    PublicMenuModel.fromJson(json ?? buildMenuJson());

PublicMenuItemModel menuItem(String id) => buildMenu().findItemById(id)!.item;

Future<void> pumpCart(
  WidgetTester tester,
  CartController cart, {
  String qrToken = validQrToken,
  Set<String>? offeredItemIds,
  PublicMenuRepository? repository,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CartPage(
        qrToken: qrToken,
        cart: cart,
        currency: 'KGS',
        repository: repository,
        offeredItemIds: offeredItemIds,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The text of the single line total currently on screen.
String lineTotalText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('cartLineTotal_item-1'))).data!;

void main() {
  group('cart money', () {
    test('a public menu price becomes whole minor units', () {
      expect(toMinorUnits(450), 45000);
      expect(toMinorUnits(0), 0);
      // A price that cannot be represented exactly still rounds to one unit.
      expect(toMinorUnits(19.99), 1999);
      expect(toMinorUnits(0.29), 29);
    });

    test('whole minor units format without float drift', () {
      expect(formatCartAmount(0, 'KGS'), '0.00 KGS');
      expect(formatCartAmount(5, 'KGS'), '0.05 KGS');
      expect(formatCartAmount(5997, 'KGS'), '59.97 KGS');
      expect(formatCartAmount(45000, 'kgs'), '450.00 KGS');
    });

    test('a line total is an exact product, not a rounded sum of doubles', () {
      // Three times 19.99 is 59.97: 0.1 + 0.2 style drift cannot appear.
      const tea = CartLineModel(
        itemId: 'tea',
        name: 'Tea',
        unitPriceMinorUnits: 1999,
        quantity: 3,
      );

      expect(tea.lineTotalMinorUnits, 5997);
      expect(formatCartAmount(tea.lineTotalMinorUnits, 'KGS'), '59.97 KGS');
    });

    test('a line snapshots the dish it was built from', () {
      final line = CartLineModel.fromMenuItem(menuItem('item-3'));

      expect(line.itemId, 'item-3');
      expect(line.name, 'Kebab');
      expect(line.unitPriceMinorUnits, 60000);
      expect(line.quantity, 1);
      expect(line.imageUrl, 'https://cdn.example/kebab.jpg');
    });

    test('a line quantity is never below one', () {
      expect(clampCartQuantity(0), minimumCartQuantity);
      expect(clampCartQuantity(-3), minimumCartQuantity);
      expect(clampCartQuantity(4), 4);

      final line = CartLineModel.fromMenuItem(menuItem('item-1'), quantity: 0);
      expect(line.quantity, 1);
      expect(line.withQuantity(0).quantity, 1);
    });
  });

  group('CartController', () {
    late CartController cart;

    setUp(() => cart = CartController());
    tearDown(() => cart.dispose());

    test('starts empty', () {
      expect(cart.isEmptyFor(validQrToken), isTrue);
      expect(cart.linesFor(validQrToken), isEmpty);
      expect(cart.itemCountFor(validQrToken), 0);
      expect(cart.subtotalMinorUnitsFor(validQrToken), 0);
    });

    test('adding a dish creates one line and counts its items', () {
      final quantity = cart.add(contextKey: validQrToken, item: menuItem('item-1'));

      expect(quantity, 1);
      expect(cart.linesFor(validQrToken), hasLength(1));
      expect(cart.itemCountFor(validQrToken), 1);
      expect(cart.isEmptyFor(validQrToken), isFalse);
    });

    test('adding the same dish again raises its quantity', () {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));

      expect(cart.linesFor(validQrToken), hasLength(1));
      expect(cart.linesFor(validQrToken).single.quantity, 2);
      expect(cart.itemCountFor(validQrToken), 2);
    });

    test('a dish can be added with a quantity', () {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'), quantity: 3);

      expect(cart.linesFor(validQrToken).single.quantity, 3);
      expect(cart.itemCountFor(validQrToken), 3);
    });

    test('an impossible quantity is clamped to one', () {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'), quantity: 0);
      expect(cart.linesFor(validQrToken).single.quantity, 1);

      cart.removeItem(contextKey: validQrToken, itemId: 'item-1');
      cart.add(contextKey: validQrToken, item: menuItem('item-1'), quantity: -5);
      expect(cart.linesFor(validQrToken).single.quantity, 1);
    });

    test('quantity can be raised and lowered', () {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));

      cart.increaseQuantity(contextKey: validQrToken, itemId: 'item-1');
      cart.increaseQuantity(contextKey: validQrToken, itemId: 'item-1');
      expect(cart.linesFor(validQrToken).single.quantity, 3);

      cart.decreaseQuantity(contextKey: validQrToken, itemId: 'item-1');
      expect(cart.linesFor(validQrToken).single.quantity, 2);
    });

    test('lowering stops at one instead of removing the dish', () {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));

      cart.decreaseQuantity(contextKey: validQrToken, itemId: 'item-1');
      cart.decreaseQuantity(contextKey: validQrToken, itemId: 'item-1');

      expect(cart.linesFor(validQrToken), hasLength(1));
      expect(cart.linesFor(validQrToken).single.quantity, 1);
    });

    test('a line can be removed', () {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));
      cart.add(contextKey: validQrToken, item: menuItem('item-2'));

      cart.removeItem(contextKey: validQrToken, itemId: 'item-1');

      expect(cart.linesFor(validQrToken), hasLength(1));
      expect(cart.linesFor(validQrToken).single.itemId, 'item-2');
      expect(cart.isEmptyFor(validQrToken), isFalse);
    });

    test('removing the last line empties the cart', () {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));
      cart.removeItem(contextKey: validQrToken, itemId: 'item-1');

      expect(cart.isEmptyFor(validQrToken), isTrue);
      expect(cart.subtotalMinorUnitsFor(validQrToken), 0);
    });

    test('edits to an unknown dish are ignored', () {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));

      cart.increaseQuantity(contextKey: validQrToken, itemId: 'item-404');
      cart.decreaseQuantity(contextKey: validQrToken, itemId: 'item-404');
      cart.removeItem(contextKey: validQrToken, itemId: 'item-404');

      expect(cart.linesFor(validQrToken).single.quantity, 1);
      expect(
        () => cart.increaseQuantity(contextKey: otherQrToken, itemId: 'item-1'),
        returnsNormally,
      );
    });

    test('the subtotal sums every line exactly', () {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'), quantity: 2);
      cart.add(contextKey: validQrToken, item: menuItem('item-2'));

      // 450.00 x 2 + 250.00, in whole minor units.
      expect(cart.subtotalMinorUnitsFor(validQrToken), 115000);
      expect(
        formatCartAmount(cart.subtotalMinorUnitsFor(validQrToken), 'KGS'),
        '1150.00 KGS',
      );
    });

    test('carts of different tables never see each other', () {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'), quantity: 2);

      expect(cart.isEmptyFor(otherQrToken), isTrue);
      expect(cart.linesFor(otherQrToken), isEmpty);
      expect(cart.itemCountFor(otherQrToken), 0);
      expect(cart.subtotalMinorUnitsFor(otherQrToken), 0);

      cart.add(contextKey: otherQrToken, item: menuItem('item-3'));

      expect(cart.linesFor(validQrToken), hasLength(1));
      expect(cart.linesFor(otherQrToken), hasLength(1));
      expect(cart.linesFor(otherQrToken).single.itemId, 'item-3');
    });

    test('a missing context is refused rather than silently pooled', () {
      expect(cart.add(contextKey: '', item: menuItem('item-1')), 0);
      expect(cart.add(contextKey: '   ', item: menuItem('item-1')), 0);
      expect(cart.isEmptyFor(''), isTrue);
      expect(cart.subtotalMinorUnitsFor('  '), 0);
    });

    test('the exposed lines cannot be modified from outside', () {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));

      expect(
        () => cart.linesFor(validQrToken).clear(),
        throwsUnsupportedError,
      );
      expect(cart.linesFor(validQrToken), hasLength(1));
    });

    test('every change notifies so the menu badge can follow along', () {
      var notifications = 0;
      cart.addListener(() => notifications++);

      cart.add(contextKey: validQrToken, item: menuItem('item-1'));
      cart.increaseQuantity(contextKey: validQrToken, itemId: 'item-1');
      cart.decreaseQuantity(contextKey: validQrToken, itemId: 'item-1');
      cart.removeItem(contextKey: validQrToken, itemId: 'item-1');

      expect(notifications, 4);
    });
  });

  group('CartPage', () {
    late CartController cart;

    setUp(() => cart = CartController());
    tearDown(() => cart.dispose());

    testWidgets('shows an empty state with no lines', (tester) async {
      await pumpCart(tester, cart);

      expect(find.text('Your cart is empty.'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      // The checkout stays on screen so the place order action is visible and
      // plainly unavailable rather than absent: a guest can see there is nothing
      // to send, and cannot send anything.
      expect(
        tester.widget<Text>(find.byKey(const Key('cartSubtotal'))).data,
        '0.00 KGS',
      );
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('placeOrderButton'))).onPressed,
        isNull,
      );
    });

    testWidgets('lists a dish with its quantity and line total', (tester) async {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'), quantity: 2);
      await pumpCart(tester, cart);

      expect(find.text('Beshbarmak'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(lineTotalText(tester), '900.00 KGS');
      expect(find.byKey(const Key('cartEmptyMessage')), findsNothing);
    });

    testWidgets('shows the exact subtotal of every line', (tester) async {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'), quantity: 2);
      cart.add(contextKey: validQrToken, item: menuItem('item-2'));
      await pumpCart(tester, cart);

      expect(find.text('900.00 KGS'), findsOneWidget);
      expect(find.text('250.00 KGS'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('cartSubtotal'))).data,
        '1150.00 KGS',
      );
    });

    testWidgets('the quantity controls edit the line', (tester) async {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));
      await pumpCart(tester, cart);

      await tester.tap(find.byKey(const Key('cartLineIncrease')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('cartLineQuantity'))).data,
        '2',
      );
      expect(lineTotalText(tester), '900.00 KGS');

      await tester.tap(find.byKey(const Key('cartLineDecrease')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('cartLineQuantity'))).data,
        '1',
      );
      expect(lineTotalText(tester), '450.00 KGS');
    });

    testWidgets('the decrease control is disabled at one', (tester) async {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));
      await pumpCart(tester, cart);

      final decrease = tester.widget<IconButton>(
        find.byKey(const Key('cartLineDecrease')),
      );
      expect(decrease.onPressed, isNull);

      await tester.tap(find.byKey(const Key('cartLineDecrease')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(cart.linesFor(validQrToken).single.quantity, 1);
    });

    testWidgets('removing a dish returns to the empty state', (tester) async {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));
      cart.add(contextKey: validQrToken, item: menuItem('item-2'));
      await pumpCart(tester, cart);

      await tester.tap(find.byKey(const Key('cartLineRemove_item-1')));
      await tester.pumpAndSettle();

      expect(find.text('Beshbarmak'), findsNothing);
      expect(find.text('Fresh Salad'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('cartSubtotal'))).data,
        '250.00 KGS',
      );

      await tester.tap(find.byKey(const Key('cartLineRemove_item-2')));
      await tester.pumpAndSettle();
      expect(find.text('Your cart is empty.'), findsOneWidget);
    });

    testWidgets('a dish the menu no longer offers is marked and left out of the total', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));
      cart.add(contextKey: validQrToken, item: menuItem('item-2'));
      // The reloaded menu still offers only the salad.
      await pumpCart(tester, cart, offeredItemIds: {'item-2'});

      expect(find.text('No longer available'), findsOneWidget);
      // The unavailable dish is shown but not added to a total the guest cannot
      // get, and it can still be taken out of the cart.
      expect(
        tester.widget<Text>(find.byKey(const Key('cartSubtotal'))).data,
        '250.00 KGS',
      );
      expect(
        find.byKey(const Key('cartLineRemove_item-1')),
        findsOneWidget,
      );
    });

    testWidgets('shows only the cart of its own table', (tester) async {
      cart.add(contextKey: otherQrToken, item: menuItem('item-1'));
      await pumpCart(tester, cart);

      expect(find.text('Your cart is empty.'), findsOneWidget);
      expect(find.text('Beshbarmak'), findsNothing);
    });

    testWidgets('a line opens the product details of the same table', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));
      await pumpCart(
        tester,
        cart,
        repository: FakePublicMenuRepository(buildMenuJson()),
      );

      expect(find.byType(ProductDetailsPage), findsNothing);

      await tester.tap(find.byKey(const Key('cartLine_item-1')));
      await tester.pumpAndSettle();

      expect(find.byType(ProductDetailsPage), findsOneWidget);
      expect(find.text('Boiled lamb with noodles'), findsOneWidget);
      // The same cart travelled with the page, so its count is still shown.
      expect(find.text('Add to cart · 1'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(CartPage), findsOneWidget);
      expect(find.text('Beshbarmak'), findsOneWidget);
    });

    testWidgets('an unavailable line cannot be opened', (tester) async {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));
      await pumpCart(
        tester,
        cart,
        offeredItemIds: const <String>{},
        repository: FakePublicMenuRepository(buildMenuJson()),
      );

      await tester.tap(find.byKey(const Key('cartLine_item-1')));
      await tester.pumpAndSettle();

      expect(find.byType(ProductDetailsPage), findsNothing);
    });
  });

  group('carting from the public menu', () {
    late CartController cart;

    setUp(() => cart = CartController());
    tearDown(() => cart.dispose());

    Future<void> pumpMenu(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: PublicMenuPage(
            qrToken: validQrToken,
            repository: FakePublicMenuRepository(buildMenuJson()),
            cart: cart,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the menu shows no cart count until something is added', (
      tester,
    ) async {
      await pumpMenu(tester);

      expect(find.byKey(const Key('cartButton')), findsOneWidget);
      expect(
        tester.widget<Badge>(find.byType(Badge)).isLabelVisible,
        isFalse,
      );
    });

    testWidgets('a dish added from its details is counted on the menu', (
      tester,
    ) async {
      await pumpMenu(tester);

      await tester.tap(find.byKey(const Key('menuItem_item-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('addToCartButton')));
      await tester.pumpAndSettle();

      // The details page stays open, so the guest can keep browsing from here.
      expect(find.byType(ProductDetailsPage), findsOneWidget);
      expect(find.text('Add to cart · 1'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('1'), findsOneWidget);
      expect(
        tester.widget<Badge>(find.byType(Badge)).isLabelVisible,
        isTrue,
      );
      expect(cart.itemCountFor(validQrToken), 1);
    });

    testWidgets('the cart opens from the menu and can be reached back into', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: menuItem('item-1'));
      await pumpMenu(tester);

      await tester.tap(find.byKey(const Key('cartButton')));
      await tester.pumpAndSettle();

      expect(find.byType(CartPage), findsOneWidget);
      expect(find.text('Beshbarmak'), findsOneWidget);
      // The menu is still underneath, offstage but alive, so the guest keeps
      // their table context.
      expect(find.byType(PublicMenuPage, skipOffstage: false), findsOneWidget);
    });

    testWidgets('the cart of another table is not reachable from this menu', (
      tester,
    ) async {
      cart.add(contextKey: otherQrToken, item: menuItem('item-1'));
      await pumpMenu(tester);

      expect(
        tester.widget<Badge>(find.byType(Badge)).isLabelVisible,
        isFalse,
      );

      await tester.tap(find.byKey(const Key('cartButton')));
      await tester.pumpAndSettle();

      expect(find.text('Your cart is empty.'), findsOneWidget);
    });

    testWidgets('no cart is offered for an empty or unavailable menu', (
      tester,
    ) async {
      for (final repository in [
        FakePublicMenuRepository(buildMenuJson(categories: const [])),
        FakePublicMenuRepository(buildMenuJson(), resolvesToNothing: true),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: PublicMenuPage(
              qrToken: validQrToken,
              repository: repository,
              cart: cart,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('cartButton')), findsNothing);
      }
    });
  });

  group('the cart never writes to the database', () {
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

    testWidgets('adding, editing and removing only ever read the public menu', (
      tester,
    ) async {
      final cart = CartController();
      addTearDown(cart.dispose);

      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: PublicMenuPage(
            qrToken: validQrToken,
            repository: PublicMenuRepository.withClient(rpcSupabaseClient),
            cart: cart,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('menuItem_item-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('addToCartButton')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('cartButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cartLineIncrease')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cartLineRemove_item-1')));
      await tester.pumpAndSettle();

      expect(find.text('Your cart is empty.'), findsOneWidget);

      // Every request was the existing read-only public menu rpc, sent with the
      // scanned token and nothing else. No table, no anon SELECT on menu_items,
      // no order or cart endpoint.
      expect(rpcHttpClient.requests, isNotEmpty);
      expect(
        rpcHttpClient.requests.map((request) => request.url.path),
        everyElement(contains('/rpc/${PublicMenuRepository.functionName}')),
      );
      expect(
        rpcHttpClient.requests.map((request) => request.method),
        everyElement('POST'),
      );
      expect(
        rpcHttpClient.requestBodies.map((body) => jsonDecode(body!)),
        everyElement({'p_qr_token': validQrToken}),
      );
    });
  });
}
