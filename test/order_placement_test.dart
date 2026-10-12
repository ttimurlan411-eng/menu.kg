import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/app/router/app_router.dart';
import 'package:menukg_flutter/features/customer/cart/data/cart_controller.dart';
import 'package:menukg_flutter/features/customer/cart/presentation/pages/cart_page.dart';
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/order_access_store.dart';
import 'package:menukg_flutter/features/customer/orders/data/repositories/order_repository.dart';
import 'package:menukg_flutter/features/customer/orders/presentation/order_error_message.dart';
import 'package:menukg_flutter/features/customer/orders/presentation/pages/order_confirmation_page.dart';
import 'package:menukg_flutter/features/customer/reservations/data/models/reservation_model.dart';
import 'package:menukg_flutter/features/customer/reservations/presentation/pages/reservation_form_page.dart';

import 'support/order_test_data.dart';
import 'support/public_menu_test_data.dart';
import 'support/reservation_test_data.dart';

/// The dish the fixture menu offers as `item-1`.
PublicMenuItemModel itemOne() =>
    PublicMenuModel.fromJson(buildMenuJson()).findItemById('item-1')!.item;

/// The place order button, or fails the test if it is not on screen.
FilledButton placeOrderButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const Key('placeOrderButton')));

Future<void> pumpOrderCart(
  WidgetTester tester,
  CartController cart,
  OrderRepository orderRepository, {
  String qrToken = validQrToken,
  Set<String>? offeredItemIds,
  OrderAccessStore? orderAccessStore,
  int pumpId = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      // Placing an order replaces this route with the confirmation, so a test
      // that pumps the cart again needs a fresh app or it would still be looking
      // at the route that was pushed on top.
      key: ValueKey<int>(pumpId),
      onGenerateRoute: AppRouter.onGenerateRoute,
      home: CartPage(
        qrToken: qrToken,
        cart: cart,
        currency: 'KGS',
        orderRepository: orderRepository,
        orderAccessStore:
            orderAccessStore ?? MemoryOrderAccessStore(),
        offeredItemIds: offeredItemIds,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('CartController.clearFor', () {
    late CartController cart;

    setUp(() => cart = CartController());
    tearDown(() => cart.dispose());

    test('empties one context and leaves the others alone', () {
      cart.add(contextKey: validQrToken, item: itemOne());
      cart.add(contextKey: 'other-table', item: itemOne());

      cart.clearFor(validQrToken);

      expect(cart.isEmptyFor(validQrToken), isTrue);
      expect(cart.linesFor('other-table'), hasLength(1));
    });

    test('notifies only when something was removed', () {
      int notifications = 0;
      cart.addListener(() => notifications++);

      cart.clearFor(validQrToken);
      expect(notifications, 0);

      cart.add(contextKey: validQrToken, item: itemOne());
      expect(notifications, 1);

      cart.clearFor(validQrToken);
      expect(notifications, 2);

      cart.clearFor(validQrToken);
      expect(notifications, 2);
    });
  });

  group('the place order action', () {
    late CartController cart;

    setUp(() => cart = CartController());
    tearDown(() => cart.dispose());

    testWidgets('is disabled for an empty cart', (tester) async {
      final repository = FakeOrderRepository();
      await pumpOrderCart(tester, cart, repository);

      expect(placeOrderButton(tester).onPressed, isNull);
      expect(find.text('Your cart is empty.'), findsOneWidget);
    });

    testWidgets('is enabled once a dish is in the cart', (tester) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      await pumpOrderCart(tester, cart, FakeOrderRepository());

      expect(placeOrderButton(tester).onPressed, isNotNull);
    });

    testWidgets('is disabled when every line is no longer offered', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      await pumpOrderCart(
        tester,
        cart,
        FakeOrderRepository(),
        offeredItemIds: const <String>{},
      );

      expect(placeOrderButton(tester).onPressed, isNull);
    });

    testWidgets('shows the cart lines and the subtotal before submitting', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: itemOne(), quantity: 2);
      await pumpOrderCart(tester, cart, FakeOrderRepository());

      expect(find.text('Beshbarmak'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('cartSubtotal'))).data,
        '900.00 KGS',
      );
      expect(find.text('Place order'), findsOneWidget);
    });

    testWidgets('an empty cart cannot submit anything', (tester) async {
      final repository = FakeOrderRepository();
      await pumpOrderCart(tester, cart, repository);

      // The button is disabled, so there is nothing to tap and nothing is sent.
      await tester.tap(
        find.byKey(const Key('placeOrderButton')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(repository.calls, isEmpty);
    });
  });

  group('placing an order', () {
    late CartController cart;

    setUp(() => cart = CartController());
    tearDown(() => cart.dispose());

    testWidgets('sends the cart items and shows the confirmation', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: itemOne(), quantity: 2);
      final repository = FakeOrderRepository(created: buildCreatedOrderModel());
      await pumpOrderCart(tester, cart, repository);

      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(repository.calls.single['qrToken'], validQrToken);
      expect(repository.calls.single['lines'], [
        {'item_id': 'item-1', 'quantity': 2},
      ]);
      expect(find.byType(OrderConfirmationPage), findsOneWidget);
      expect(find.byType(CartPage), findsNothing);
    });

    testWidgets('never sends a price, a name, a total or an internal id', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: itemOne(), quantity: 2);
      final repository = FakeOrderRepository(created: buildCreatedOrderModel());
      await pumpOrderCart(tester, cart, repository);

      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      final line = (repository.calls.single['lines']! as List).single as Map;
      expect(line.keys, ['item_id', 'quantity']);
      expect(
        repository.calls.single.keys,
        containsAll(<String>['qrToken', 'lines']),
      );
      expect(
        repository.calls.single.containsKey('restaurant_id'),
        isFalse,
      );
      expect(repository.calls.single.containsKey('branch_id'), isFalse);
      expect(repository.calls.single.containsKey('table_id'), isFalse);
      expect(repository.calls.single.containsKey('order_id'), isFalse);
      expect(repository.calls.single.containsKey('total'), isFalse);
    });

    testWidgets('uses the QR token the menu was opened with', (tester) async {
      cart.add(contextKey: otherQrTokenForOrders, item: itemOne());
      final repository = FakeOrderRepository(created: buildCreatedOrderModel());
      await pumpOrderCart(
        tester,
        cart,
        repository,
        qrToken: otherQrTokenForOrders,
      );

      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(repository.calls.single['qrToken'], otherQrTokenForOrders);
    });

    testWidgets('leaves out a line the menu no longer offers', (tester) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      cart.add(contextKey: validQrToken, item: itemThree());
      final repository = FakeOrderRepository(created: buildCreatedOrderModel());
      await pumpOrderCart(
        tester,
        cart,
        repository,
        offeredItemIds: const {'item-1'},
      );

      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(repository.calls.single['lines'], [
        {'item_id': 'item-1', 'quantity': 1},
      ]);
    });

    testWidgets('shows a sending state and refuses a second submission', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      final repository = PendingOrderRepository(Completer<CreatedOrderModel?>());
      await pumpOrderCart(tester, cart, repository);

      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pump();

      // The action is visibly busy and cannot be pressed again while the request
      // is in flight, so a double tap cannot produce two orders.
      expect(find.text('Placing order...'), findsOneWidget);
      expect(placeOrderButton(tester).onPressed, isNull);
      expect(repository.calls, 1);

      await tester.tap(
        find.byKey(const Key('placeOrderButton')),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(repository.calls, 1);

      repository.completer.complete(buildCreatedOrderModel());
      await tester.pumpAndSettle();
      expect(repository.calls, 1);
      expect(find.byType(OrderConfirmationPage), findsOneWidget);
    });

    testWidgets('clears the cart only after the order is confirmed', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      final repository = PendingOrderRepository(Completer<CreatedOrderModel?>());
      await pumpOrderCart(tester, cart, repository);

      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pump();

      // Still in flight: the guest's choices are untouched.
      expect(cart.linesFor(validQrToken), hasLength(1));

      repository.completer.complete(buildCreatedOrderModel());
      await tester.pumpAndSettle();

      expect(cart.isEmptyFor(validQrToken), isTrue);
    });

    testWidgets('keeps the cart exactly as it was when the order fails', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: itemOne(), quantity: 2);
      final repository = FakeOrderRepository(
        error: orderPostgrestError('P0001', message: 'unavailable_menu_item'),
      );
      await pumpOrderCart(tester, cart, repository);

      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(cart.linesFor(validQrToken), hasLength(1));
      expect(cart.linesFor(validQrToken).single.quantity, 2);
      expect(find.byType(OrderConfirmationPage), findsNothing);
      expect(find.text('Beshbarmak'), findsOneWidget);
      expect(placeOrderButton(tester).onPressed, isNotNull);
      expect(find.byKey(const Key('cartOrderErrorMessage')), findsOneWidget);
    });

    testWidgets('keeps the cart when the QR token no longer resolves', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      // `null` is what the database answers for an unknown, deleted or inactive
      // table, and is deliberately the same answer as no menu at all.
      final repository = FakeOrderRepository();
      await pumpOrderCart(tester, cart, repository);

      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(cart.linesFor(validQrToken), hasLength(1));
      expect(find.byType(OrderConfirmationPage), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('cartOrderErrorMessage'))).data,
        orderQrUnavailableMessage,
      );
    });

    testWidgets('can be retried after a failure', (tester) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      final repository = FakeOrderRepository(
        error: orderPostgrestError('42501', message: 'permission denied'),
      );
      await pumpOrderCart(tester, cart, repository);

      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();
      expect(repository.calls, hasLength(1));

      repository
        ..error = null
        ..created = buildCreatedOrderModel();
      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(repository.calls, hasLength(2));
      expect(find.byType(OrderConfirmationPage), findsOneWidget);
      expect(cart.isEmptyFor(validQrToken), isTrue);
    });

    testWidgets('a failure message never leaks database internals', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      final repository = FakeOrderRepository(
        error: orderPostgrestError(
          'P0001',
          message:
              'null value in column "restaurant_id" violates not-null constraint',
        ),
      );
      await pumpOrderCart(tester, cart, repository);

      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      final message = tester
          .widget<Text>(find.byKey(const Key('cartOrderErrorMessage')))
          .data!;
      expect(message, isNot(contains('restaurant_id')));
      expect(message, isNot(contains('not-null')));
      expect(message, isNot(contains('P0001')));
      expect(message, contains('try again'));
    });
  });

  group('OrderConfirmationPage', () {
    testWidgets('shows what the database stored', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: OrderConfirmationPage(
            order: buildCreatedOrderModel(orderNumber: 1043, total: 900).order,
            onBackToMenu: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('orderConfirmationTitle'))).data,
        'Your order has been accepted',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('orderConfirmationNumber'))).data,
        '#1043',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('orderConfirmationTotal'))).data,
        '900.00 KGS',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('orderConfirmationItemCount')))
            .data,
        '2',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('orderConfirmationTableContext')))
            .data,
        'Center · Table 12 · Window',
      );
      expect(find.text('2 × Beshbarmak'), findsOneWidget);
    });

    testWidgets('labels the total in the currency it was stored with', (
      tester,
    ) async {
      final order = OrderModel.fromJson(
        buildOrderJson(total: 1500.50, currency: 'USD', items: [
          buildOrderLineJson(unitPrice: 450, quantity: 2),
          buildOrderLineJson(
            menuItemId: '88888888-8888-8888-8888-888888888888',
            productName: 'Kebab',
            unitPrice: 600.50,
            quantity: 1,
          ),
        ]),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: OrderConfirmationPage(order: order, onBackToMenu: () {}),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('orderConfirmationTotal'))).data,
        '1500.50 USD',
      );
      expect(find.text('900.00 USD'), findsOneWidget);
      expect(find.text('600.50 USD'), findsOneWidget);
    });

    testWidgets('offers a way back to the menu', (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: OrderConfirmationPage(
            order: buildCreatedOrderModel().order,
            onBackToMenu: () => taps++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('orderConfirmationBackToMenuButton')));
      await tester.pumpAndSettle();

      expect(taps, 1);
    });

    testWidgets('promises no preparation time or status the app cannot know', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: OrderConfirmationPage(
            order: buildCreatedOrderModel().order,
            onBackToMenu: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rendered = tester
          .widgetList<Text>(find.byType(Text))
          .map((Text text) => text.data ?? '')
          .join(' ')
          .toLowerCase();

      expect(rendered, isNot(contains('minute')));
      expect(rendered, isNot(contains('preparing')));
      expect(rendered, isNot(contains('on the way')));
      expect(rendered, isNot(contains('estimated')));
    });
  });

  group('the confirmation route', () {
    testWidgets('is reachable with an order and is not a public path', (
      tester,
    ) async {
      final route = AppRouter.onGenerateRoute(
        RouteSettings(
          name: AppRouter.orderConfirmationRouteName,
          arguments: buildCreatedOrderModel().order,
        ),
      );

      expect(route, isNotNull);

      // No argument, so no order to show: it must not resolve to a page that
      // invents one.
      expect(
        AppRouter.onGenerateRoute(
          RouteSettings(name: AppRouter.orderConfirmationRouteName),
        ),
        isNull,
      );
      expect(
        AppRouter.onGenerateRoute(
          RouteSettings(name: '${AppRouter.orderConfirmationRouteName}?'),
        ),
        isNull,
      );
    });

    test('leaves the public menu route working without authentication', () {
      expect(
        AppRouter.parsePublicMenuQrToken('/t/$validQrToken'),
        validQrToken,
      );
      expect(AppRouter.parsePublicMenuQrToken('/t'), isNull);
      expect(AppRouter.onGenerateRoute(const RouteSettings(name: '/t/abc')), isNotNull);
    });
  });

  group('the order access token', () {
    late CartController cart;

    setUp(() => cart = CartController());
    tearDown(() => cart.dispose());

    testWidgets('is read before the order and sent with it', (tester) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      final repository = FakeOrderRepository(created: buildCreatedOrderModel());
      final store = MemoryOrderAccessStore(validQrToken, 'a-stored-token');

      await pumpOrderCart(
        tester,
        cart,
        repository,
        orderAccessStore: store,
      );
      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(store.reads, 1);
      expect(repository.calls.single['accessToken'], 'a-stored-token');
    });

    testWidgets('sends no token when the guest has none yet', (tester) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      final repository = FakeOrderRepository(created: buildCreatedOrderModel());
      final store = MemoryOrderAccessStore();

      await pumpOrderCart(
        tester,
        cart,
        repository,
        orderAccessStore: store,
      );
      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(repository.calls.single['accessToken'], isNull);
    });

    testWidgets('the token the database returned is stored', (tester) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      final repository = FakeOrderRepository(
        created: buildCreatedOrderModel(accessToken: 'a-brand-new-token'),
      );
      final store = MemoryOrderAccessStore();

      await pumpOrderCart(
        tester,
        cart,
        repository,
        orderAccessStore: store,
      );
      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(store.writes, 1);
      expect(store.tokenFor(validQrToken), 'a-brand-new-token');
    });

    testWidgets('a second order from the same menu reuses the stored token', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      final repository = FakeOrderRepository(created: buildCreatedOrderModel());
      final store = MemoryOrderAccessStore();

      // The first order mints and stores the token.
      await pumpOrderCart(
        tester,
        cart,
        repository,
        orderAccessStore: store,
      );
      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      // The guest orders again from the same table.
      cart.add(contextKey: validQrToken, item: itemOne());
      await pumpOrderCart(
        tester,
        cart,
        repository,
        orderAccessStore: store,
        pumpId: 1,
      );
      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(repository.calls, hasLength(2));
      expect(repository.calls.first['accessToken'], isNull);
      expect(repository.calls.last['accessToken'], guestOrderAccessToken);
    });

    testWidgets('another menu never reuses this menu\'s token', (tester) async {
      const otherToken = 'f0e1d2c3-b4a5-4968-8776-655443332211';
      cart.add(contextKey: validQrToken, item: itemOne());
      final repository = FakeOrderRepository(created: buildCreatedOrderModel());
      final store = MemoryOrderAccessStore(validQrToken, 'a-stored-token');

      // A different table's menu, with a cart of its own.
      final otherCart = CartController();
      addTearDown(otherCart.dispose);
      otherCart.add(contextKey: otherToken, item: itemOne());

      await pumpOrderCart(
        tester,
        otherCart,
        repository,
        qrToken: otherToken,
        orderAccessStore: store,
      );
      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(repository.calls.single['accessToken'], isNull);
      // And this menu's token is still where it was.
      expect(store.tokenFor(validQrToken), 'a-stored-token');
      expect(store.tokenFor(otherToken), guestOrderAccessToken);
    });

    testWidgets('the token is scoped to the menu it came from', (tester) async {
      const otherToken = 'f0e1d2c3-b4a5-4968-8776-655443332211';
      cart.add(contextKey: validQrToken, item: itemOne());
      final repository = FakeOrderRepository(created: buildCreatedOrderModel());
      final store = MemoryOrderAccessStore(otherToken, 'another-tables-token');

      await pumpOrderCart(
        tester,
        cart,
        repository,
        orderAccessStore: store,
      );
      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(repository.calls.single['accessToken'], isNull);
      expect(store.contexts, contains(otherToken));
      expect(store.tokenFor(otherToken), 'another-tables-token');
    });

    testWidgets('a failed order stores no token', (tester) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      final repository = FakeOrderRepository(
        error: orderPostgrestError('P0001', message: 'unavailable_menu_item'),
      );
      final store = MemoryOrderAccessStore();

      await pumpOrderCart(
        tester,
        cart,
        repository,
        orderAccessStore: store,
      );
      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(store.writes, 0);
      expect(await store.readToken(contextKey: validQrToken), isNull);
    });

    testWidgets('an order the database could not place stores no token', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      // `null` means the QR token resolved to nothing, so no order and no token.
      final repository = FakeOrderRepository();
      final store = MemoryOrderAccessStore();

      await pumpOrderCart(
        tester,
        cart,
        repository,
        orderAccessStore: store,
      );
      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(store.writes, 0);
      expect(await store.readToken(contextKey: validQrToken), isNull);
    });

    testWidgets('the token is never shown on screen', (tester) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      final repository = FakeOrderRepository(
        created: buildCreatedOrderModel(accessToken: 'a-secret-token'),
      );
      final store = MemoryOrderAccessStore();

      await pumpOrderCart(
        tester,
        cart,
        repository,
        orderAccessStore: store,
      );
      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(find.textContaining('a-secret-token'), findsNothing);
      final rendered = tester
          .widgetList<Text>(find.byType(Text))
          .map((Text text) => text.data ?? '')
          .join(' ');
      expect(rendered, isNot(contains('a-secret-token')));
    });
  });

  group('existing customer flows', () {
    late CartController cart;

    setUp(() => cart = CartController());
    tearDown(() => cart.dispose());

    testWidgets('the guest reservation token is left alone by ordering', (
      tester,
    ) async {
      cart.add(contextKey: validQrToken, item: itemOne());
      final store = MemoryOrderAccessStore();
      await store.writeToken(
        contextKey: validQrToken,
        token: 'an-order-token',
      );
      final reservationStore = MemoryReservationAccessStore(
        'a-reservation-token',
      );

      await pumpOrderCart(
        tester,
        cart,
        FakeOrderRepository(created: buildCreatedOrderModel()),
        orderAccessStore: store,
      );
      await tester.tap(find.byKey(const Key('placeOrderButton')));
      await tester.pumpAndSettle();

      expect(await reservationStore.readToken(), 'a-reservation-token');
      expect(await store.readToken(contextKey: validQrToken), guestOrderAccessToken);
    });

    testWidgets('the reservation form still opens from its own page', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: Builder(
            builder: (BuildContext context) => ReservationFormPage(
              qrToken: validQrToken,
              tableLabel: 'Table 12 · Window',
              restaurantName: 'Ala-Too',
              branchName: 'Center',
              repository: FakeReservationRepository(),
              accessStore: MemoryReservationAccessStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ReservationFormPage), findsOneWidget);
      expect(
        tester.widget<FilledButton>(
          find.byKey(const Key('reservationSubmitButton')),
        ).onPressed,
        isNotNull,
      );
      expect(
        ReservationStatus.fromDatabase('CONFIRMED'),
        ReservationStatus.confirmed,
      );
    });
  });
}

/// A second table, to prove an order stays scoped to the token it came from.
const String otherQrTokenForOrders =
    '9ab7c6d5-1f3e-4a2b-8c9d-0e1f2a3b4c5d';

/// The dish the fixture menu offers as `item-3`.
PublicMenuItemModel itemThree() =>
    PublicMenuModel.fromJson(buildMenuJson()).findItemById('item-3')!.item;
