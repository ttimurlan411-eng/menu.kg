import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:menukg_flutter/features/customer/cart/data/cart_controller.dart';
import 'package:menukg_flutter/features/customer/cart/data/models/cart_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/order_access_store.dart';
import 'package:menukg_flutter/features/customer/orders/data/repositories/order_repository.dart';
import 'package:menukg_flutter/features/customer/reservations/data/reservation_access_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/order_test_data.dart';
import 'support/public_menu_test_data.dart';

/// One dish of the public menu, used to build a cart line the way the menu does.
PublicMenuItemModel testMenuItem({
  String id = '77777777-7777-7777-7777-777777777777',
  String name = 'Beshbarmak',
  double price = 450,
}) {
  return PublicMenuItemModel.fromJson({
    'id': id,
    'name': name,
    'description': null,
    'price': price,
    'old_price': null,
    'main_image_url': null,
    'preparation_time_minutes': 20,
  });
}

CartLineModel testCartLine({
  String id = '77777777-7777-7777-7777-777777777777',
  String name = 'Beshbarmak',
  double price = 450,
  int quantity = 2,
}) {
  return CartLineModel.fromMenuItem(
    testMenuItem(id: id, name: name, price: price),
    quantity: quantity,
  );
}

void main() {
  group('OrderStatus', () {
    test('knows every state the database can store', () {
      expect(OrderStatus.fromDatabase('PENDING'), OrderStatus.pending);
      expect(OrderStatus.fromDatabase('ACCEPTED'), OrderStatus.accepted);
      expect(OrderStatus.fromDatabase('PREPARING'), OrderStatus.preparing);
      expect(OrderStatus.fromDatabase('READY'), OrderStatus.ready);
      expect(OrderStatus.fromDatabase('SERVED'), OrderStatus.served);
      expect(OrderStatus.fromDatabase('CANCELLED'), OrderStatus.cancelled);
    });

    test('an unknown status is refused rather than guessed', () {
      // A state this app has no wording for, including a payment-shaped one: it is
      // not shown to a guest as something it understands.
      expect(
        () => OrderStatus.fromDatabase('PAID'),
        throwsFormatException,
      );
      expect(
        () => OrderStatus.fromDatabase('ON_ITS_WAY'),
        throwsFormatException,
      );
      expect(() => OrderStatus.fromDatabase(''), throwsFormatException);
      // Case matters, so a differently cased value cannot be read as a known one.
      expect(() => OrderStatus.fromDatabase('pending'), throwsFormatException);
      expect(() => OrderStatus.fromDatabase('Ready'), throwsFormatException);
    });
  });

  group('OrderModel', () {
    test('parses a placed order with its access token', () {
      final created = tryParseCreatedOrder(
        encodeOrderRpcResult(buildCreatedOrderJson()),
      );

      expect(created, isNotNull);
      expect(created!.accessToken, guestOrderAccessToken);
      expect(created.order.id, '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136');
      expect(created.order.orderNumber, 1043);
      expect(created.order.status, OrderStatus.pending);
      expect(created.order.currency, 'KGS');
      expect(created.order.restaurantName, 'Ala-Too');
      expect(created.order.branchName, 'Center');
      expect(created.order.table.label, 'Table 12 · Window');
      expect(created.order.itemCount, 2);
      expect(
        created.order.createdAt,
        DateTime.parse('2026-10-05T14:22:31.504534+00:00'),
      );
    });

    test('exposes the order number as the guest reads it', () {
      final order = OrderModel.fromJson(buildOrderJson(orderNumber: 1043));

      expect(order.numberLabel, '#1043');
    });

    test('holds no restaurant, branch, table or order id on a line', () {
      final order = OrderModel.fromJson(buildOrderJson());
      final raw = buildOrderJson();

      expect(raw.containsKey('restaurant_id'), isFalse);
      expect(raw.containsKey('branch_id'), isFalse);
      expect(raw.containsKey('table_id'), isFalse);
      expect(raw.containsKey('access_token'), isFalse);
      expect(buildOrderLineJson().containsKey('order_id'), isFalse);
      expect(buildOrderLineJson().containsKey('restaurant_id'), isFalse);
      expect(order.lines.single.menuItemId, isNotNull);
    });

    test('totals are read from the stored snapshot, in whole minor units', () {
      final order = OrderModel.fromJson(
        buildOrderJson(
          total: 1500.50,
          itemCount: 3,
          items: [
            buildOrderLineJson(unitPrice: 450, quantity: 2),
            buildOrderLineJson(
              menuItemId: '88888888-8888-8888-8888-888888888888',
              productName: 'Kebab',
              unitPrice: 600.50,
              quantity: 1,
            ),
          ],
        ),
      );

      expect(order.totalMinorUnits, 150050);
      expect(order.totalLabel, '1500.50 KGS');
      expect(order.lines.first.lineTotalMinorUnits, 90000);
      expect(order.lines.last.lineTotalMinorUnits, 60050);
      expect(
        order.lines.fold<int>(0, (int sum, OrderLineModel l) => sum + l.lineTotalMinorUnits),
        order.totalMinorUnits,
      );
    });

    test('keeps the snapshot of a product that has since been deleted', () {
      final order = OrderModel.fromJson(
        buildOrderJson(
          items: [
            {
              ...buildOrderLineJson(),
              'menu_item_id': null,
              'product_name': 'Retired Dish',
            },
          ],
        ),
      );

      expect(order.lines.single.menuItemId, isNull);
      expect(order.lines.single.productName, 'Retired Dish');
      expect(order.lines.single.lineTotalMinorUnits, 90000);
    });

    test('labels a line with its quantity', () {
      final order = OrderModel.fromJson(buildOrderJson());

      expect(order.lines.single.label, '2 × Beshbarmak');
    });

    test('an unreadable status is not shown as a placed order', () {
      // A state this client has no wording for is refused, whether it arrives on its
      // own or inside a create response: a guest is never shown an order in a state
      // the app cannot describe.
      expect(
        () => OrderModel.fromJson(buildOrderJson(status: 'ON_ITS_WAY')),
        throwsFormatException,
      );
      expect(
        tryParseCreatedOrder(encodeOrderRpcResult(buildOrderJson(status: 'PAID'))),
        isNull,
      );
    });
  });

  group('tryParseCreatedOrder', () {
    test('resolves nothing for an unresolved qr token', () {
      expect(tryParseCreatedOrder('null'), isNull);
      expect(tryParseCreatedOrder(null), isNull);
      expect(tryParseCreatedOrder(''), isNull);
      expect(tryParseCreatedOrder('{}'), isNull);
      expect(tryParseCreatedOrder('not json'), isNull);
    });

    test('never invents a token', () {
      expect(
        tryParseCreatedOrder(
          encodeOrderRpcResult({'order': buildOrderJson()}),
        ),
        isNull,
      );
      expect(
        tryParseCreatedOrder(
          encodeOrderRpcResult({'access_token': '', 'order': buildOrderJson()}),
        ),
        isNull,
      );
      expect(
        tryParseCreatedOrder(
          encodeOrderRpcResult({'access_token': 'abc'}),
        ),
        isNull,
      );
    });

    test('accepts a payload that arrives already decoded', () {
      expect(tryParseCreatedOrder(buildCreatedOrderJson()), isNotNull);
    });
  });

  group('buildOrderItemPayload', () {
    test('sends only the item id and the quantity', () {
      final payload = buildOrderItemPayload([testCartLine(quantity: 3)]);

      expect(payload, [
        {'item_id': '77777777-7777-7777-7777-777777777777', 'quantity': 3},
      ]);
      expect(payload.single.keys, ['item_id', 'quantity']);
    });

    test('never sends a price or a product name', () {
      final payload = buildOrderItemPayload([testCartLine()]);

      expect(payload.single.containsKey('unit_price'), isFalse);
      expect(payload.single.containsKey('product_name'), isFalse);
      expect(payload.single.containsKey('line_total'), isFalse);
      expect(payload.single.containsKey('restaurant_id'), isFalse);
    });

    test('an empty cart produces nothing to order', () {
      expect(buildOrderItemPayload(const []), isEmpty);
    });

    test('a blank item id is dropped', () {
      expect(buildOrderItemPayload([testCartLine(id: '   ')]), isEmpty);
    });

    test('the same dish on two lines becomes one line', () {
      final payload = buildOrderItemPayload([
        testCartLine(quantity: 1),
        testCartLine(quantity: 4),
      ]);

      expect(payload, [
        {'item_id': '77777777-7777-7777-7777-777777777777', 'quantity': 4},
      ]);
    });

    test('dishes from different menus stay separate lines', () {
      final payload = buildOrderItemPayload([
        testCartLine(id: 'item-1', quantity: 1),
        testCartLine(id: 'item-2', name: 'Kebab', price: 600, quantity: 2),
      ]);

      expect(payload, [
        {'item_id': 'item-1', 'quantity': 1},
        {'item_id': 'item-2', 'quantity': 2},
      ]);
    });
  });

  group('OrderRepository.createOrderFromCart', () {
    late CartController cart;

    setUp(() => cart = CartController());
    tearDown(() => cart.dispose());

    /// A repository whose rpc call records the request body it was given, so the
    /// tests can assert on the payload that would have reached the database.
    OrderRepository repositoryThatRecords(
      void Function(Map<String, dynamic> body) onBody,
    ) {
      final httpClient = RecordingHttpClient((request, body) async {
        onBody(jsonDecode(body as String) as Map<String, dynamic>);
        return http.Response(
          encodeOrderRpcResult(buildCreatedOrderJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);
      return OrderRepository.withClient(client);
    }

    test('orders the cart of the given context', () async {
      final sentBodies = <Map<String, dynamic>>[];
      cart.add(contextKey: validQrToken, item: testMenuItem(), quantity: 2);

      final created = await repositoryThatRecords(
        sentBodies.add,
      ).createOrderFromCart(
        qrToken: validQrToken,
        cart: cart,
        contextKey: validQrToken,
      );

      expect(sentBodies.single['p_qr_token'], validQrToken);
      expect(sentBodies.single['p_items'], [
        {'item_id': '77777777-7777-7777-7777-777777777777', 'quantity': 2},
      ]);
      expect(created?.order.orderNumber, 1043);
    });

    test('orders only the requested context, not another table\'s cart', () async {
      final sentBodies = <Map<String, dynamic>>[];
      cart.add(contextKey: validQrToken, item: testMenuItem());
      cart.add(contextKey: 'other-table', item: testMenuItem(), quantity: 5);

      await repositoryThatRecords(sentBodies.add).createOrderFromCart(
        qrToken: validQrToken,
        cart: cart,
        contextKey: validQrToken,
      );

      expect(sentBodies.single['p_items'], [
        {'item_id': '77777777-7777-7777-7777-777777777777', 'quantity': 1},
      ]);
    });

    test('sends quantities the cart actually holds', () async {
      final sentBodies = <Map<String, dynamic>>[];
      cart.add(contextKey: validQrToken, item: testMenuItem(), quantity: 3);
      cart.increaseQuantity(
        contextKey: validQrToken,
        itemId: '77777777-7777-7777-7777-777777777777',
      );

      await repositoryThatRecords(sentBodies.add).createOrderFromCart(
        qrToken: validQrToken,
        cart: cart,
        contextKey: validQrToken,
      );

      expect(sentBodies.single['p_items'], [
        {'item_id': '77777777-7777-7777-7777-777777777777', 'quantity': 4},
      ]);
    });

    test('sends no price, name or total taken from the cart line', () async {
      final sentBodies = <Map<String, dynamic>>[];
      cart.add(contextKey: validQrToken, item: testMenuItem(price: 999));

      await repositoryThatRecords(sentBodies.add).createOrderFromCart(
        qrToken: validQrToken,
        cart: cart,
        contextKey: validQrToken,
      );

      final line =
          (sentBodies.single['p_items']! as List).single as Map<String, dynamic>;
      expect(line.keys, ['item_id', 'quantity']);
      expect(line.containsKey('unit_price'), isFalse);
      expect(line.containsKey('line_total'), isFalse);
      expect(line.containsKey('product_name'), isFalse);
      expect(sentBodies.single.containsKey('p_total'), isFalse);
    });

    test('leaves out a dish the menu no longer offers', () async {
      final sentBodies = <Map<String, dynamic>>[];
      cart.add(contextKey: validQrToken, item: testMenuItem());
      cart.add(
        contextKey: validQrToken,
        item: testMenuItem(id: '88888888-8888-8888-8888-888888888888'),
      );

      await repositoryThatRecords(sentBodies.add).createOrderFromCart(
        qrToken: validQrToken,
        cart: cart,
        contextKey: validQrToken,
        offeredItemIds: const {'77777777-7777-7777-7777-777777777777'},
      );

      expect(sentBodies.single['p_items'], [
        {'item_id': '77777777-7777-7777-7777-777777777777', 'quantity': 1},
      ]);
    });

    test('an empty cart never reaches the database', () async {
      final httpClient = RecordingHttpClient(
        (request, body) async => http.Response('null', 200),
      );
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      expect(
        await OrderRepository.withClient(client).createOrderFromCart(
          qrToken: validQrToken,
          cart: cart,
          contextKey: validQrToken,
        ),
        isNull,
      );
      expect(httpClient.requests, isEmpty);
    });

    test('a cart of nothing still offered never reaches the database', () async {
      final httpClient = RecordingHttpClient(
        (request, body) async => http.Response('null', 200),
      );
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);
      cart.add(contextKey: validQrToken, item: testMenuItem());

      expect(
        await OrderRepository.withClient(client).createOrderFromCart(
          qrToken: validQrToken,
          cart: cart,
          contextKey: validQrToken,
          offeredItemIds: const <String>{},
        ),
        isNull,
      );
      expect(httpClient.requests, isEmpty);
    });

    test('a blank context orders nothing and never reaches the database', () async {
      final httpClient = RecordingHttpClient(
        (request, body) async => http.Response('null', 200),
      );
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);
      cart.add(contextKey: validQrToken, item: testMenuItem());

      expect(
        await OrderRepository.withClient(client).createOrderFromCart(
          qrToken: validQrToken,
          cart: cart,
          contextKey: '   ',
        ),
        isNull,
      );
      expect(httpClient.requests, isEmpty);
    });

    test('a blank qr token never reaches the database', () async {
      final httpClient = RecordingHttpClient(
        (request, body) async => http.Response('null', 200),
      );
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);
      cart.add(contextKey: validQrToken, item: testMenuItem());

      expect(
        await OrderRepository.withClient(client).createOrderFromCart(
          qrToken: '  ',
          cart: cart,
          contextKey: validQrToken,
        ),
        isNull,
      );
      expect(httpClient.requests, isEmpty);
    });

    test('a missing qr context resolves to nothing', () async {
      final httpClient = RecordingHttpClient(
        (request, body) async => http.Response('null', 200),
      );
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);
      cart.add(contextKey: validQrToken, item: testMenuItem());

      expect(
        await OrderRepository.withClient(client).createOrderFromCart(
          qrToken: validQrToken,
          cart: cart,
          contextKey: validQrToken,
        ),
        isNull,
      );
    });

    test('does not clear the cart: that is the caller\'s decision', () async {
      cart.add(contextKey: validQrToken, item: testMenuItem(), quantity: 2);

      await repositoryThatRecords((Map<String, dynamic> _) {}).createOrderFromCart(
        qrToken: validQrToken,
        cart: cart,
        contextKey: validQrToken,
      );

      expect(cart.linesFor(validQrToken), hasLength(1));
      expect(cart.linesFor(validQrToken).single.quantity, 2);
    });
  });

  group('DeviceOrderAccessStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('is empty on a device that never ordered', () async {
      const store = DeviceOrderAccessStore();

      expect(await store.readToken(contextKey: validQrToken), isNull);
    });

    test('keeps the token between reads, which is what survives a restart', () async {
      const store = DeviceOrderAccessStore();

      await store.writeToken(
        contextKey: validQrToken,
        token: guestOrderAccessToken,
      );
      expect(await store.readToken(contextKey: validQrToken), guestOrderAccessToken);

      // A fresh instance stands in for the next app launch.
      expect(
        await const DeviceOrderAccessStore().readToken(contextKey: validQrToken),
        guestOrderAccessToken,
      );
    });

    test('trims what it stores so a stray space cannot lock a guest out', () async {
      const store = DeviceOrderAccessStore();

      await store.writeToken(
        contextKey: validQrToken,
        token: '  $guestOrderAccessToken  ',
      );

      expect(await store.readToken(contextKey: validQrToken), guestOrderAccessToken);
    });

    test('a later token replaces the earlier one for the same context', () async {
      const store = DeviceOrderAccessStore();
      await store.writeToken(contextKey: validQrToken, token: 'first-token');

      await store.writeToken(contextKey: validQrToken, token: 'second-token');

      expect(await store.readToken(contextKey: validQrToken), 'second-token');
    });

    test('each context keeps its own token', () async {
      const store = DeviceOrderAccessStore();
      const otherContext = 'f0e1d2c3-b4a5-4968-8776-655443332211';

      await store.writeToken(contextKey: validQrToken, token: 'token-for-a');
      await store.writeToken(contextKey: otherContext, token: 'token-for-b');

      expect(await store.readToken(contextKey: validQrToken), 'token-for-a');
      expect(await store.readToken(contextKey: otherContext), 'token-for-b');
    });

    test('a context written later does not disturb an earlier one', () async {
      const store = DeviceOrderAccessStore();
      await store.writeToken(contextKey: validQrToken, token: 'token-for-a');

      await store.writeToken(
        contextKey: 'a-different-table',
        token: 'token-for-b',
      );

      expect(await store.readToken(contextKey: validQrToken), 'token-for-a');
    });

    test('surrounding whitespace in a context does not split it in two', () async {
      const store = DeviceOrderAccessStore();
      await store.writeToken(contextKey: validQrToken, token: 'token-for-a');

      expect(
        await store.readToken(contextKey: '  $validQrToken  '),
        'token-for-a',
      );
    });

    test('a blank context has no token at all', () async {
      const store = DeviceOrderAccessStore();
      await store.writeToken(contextKey: validQrToken, token: 'token-for-a');

      expect(await store.readToken(contextKey: ''), isNull);
      expect(await store.readToken(contextKey: '   '), isNull);
    });

    test('a blank context is never written to', () async {
      const store = DeviceOrderAccessStore();

      await store.writeToken(contextKey: '  ', token: guestOrderAccessToken);

      expect(
        SharedPreferences.getInstance().then((p) => p.getString(DeviceOrderAccessStore.tokensKey)),
        completion(isNull),
      );
    });

    test('a blank token never overwrites a real one', () async {
      const store = DeviceOrderAccessStore();
      await store.writeToken(contextKey: validQrToken, token: 'token-for-a');

      await store.writeToken(contextKey: validQrToken, token: '   ');

      expect(await store.readToken(contextKey: validQrToken), 'token-for-a');
    });

    test('clearing forgets the token for that context only', () async {
      const store = DeviceOrderAccessStore();
      const otherContext = 'f0e1d2c3-b4a5-4968-8776-655443332211';
      await store.writeToken(contextKey: validQrToken, token: 'token-for-a');
      await store.writeToken(contextKey: otherContext, token: 'token-for-b');

      await store.clearToken(contextKey: validQrToken);

      expect(await store.readToken(contextKey: validQrToken), isNull);
      expect(await store.readToken(contextKey: otherContext), 'token-for-b');
    });

    test('clearing a context that has no token is harmless', () async {
      const store = DeviceOrderAccessStore();
      await store.writeToken(contextKey: validQrToken, token: 'token-for-a');

      await store.clearToken(contextKey: 'never-ordered-from-here');

      expect(await store.readToken(contextKey: validQrToken), 'token-for-a');
    });

    test('a blank stored value reads as no token', () async {
      SharedPreferences.setMockInitialValues({
        DeviceOrderAccessStore.tokensKey: jsonEncode({
          validQrToken: '   ',
          'another-table': 'real-token',
        }),
      });

      expect(await const DeviceOrderAccessStore().readToken(contextKey: validQrToken), isNull);
      expect(
        await const DeviceOrderAccessStore().readToken(contextKey: 'another-table'),
        'real-token',
      );
    });

    test('a stored value that is not json reads as empty', () async {
      SharedPreferences.setMockInitialValues({
        DeviceOrderAccessStore.tokensKey: 'not json at all',
      });

      expect(await const DeviceOrderAccessStore().readToken(contextKey: validQrToken), isNull);
    });

    test('a stored value that is not a map of strings reads as empty', () async {
      SharedPreferences.setMockInitialValues({
        DeviceOrderAccessStore.tokensKey: jsonEncode(['a', 'b']),
      });

      expect(await const DeviceOrderAccessStore().readToken(contextKey: validQrToken), isNull);
    });

    test('a non string entry is dropped and the real ones survive', () async {
      SharedPreferences.setMockInitialValues({
        DeviceOrderAccessStore.tokensKey: jsonEncode({
          validQrToken: 'real-token',
          'another-table': 42,
          'a third table': null,
        }),
      });

      expect(await const DeviceOrderAccessStore().readToken(contextKey: validQrToken), 'real-token');
      expect(
        await const DeviceOrderAccessStore().readToken(contextKey: 'another-table'),
        isNull,
      );
      expect(
        await const DeviceOrderAccessStore().readToken(contextKey: 'a third table'),
        isNull,
      );
    });

    test('a corrupted store is repaired by the next write', () async {
      SharedPreferences.setMockInitialValues({
        DeviceOrderAccessStore.tokensKey: 'not json at all',
      });
      const store = DeviceOrderAccessStore();

      await store.writeToken(contextKey: validQrToken, token: 'real-token');

      expect(await store.readToken(contextKey: validQrToken), 'real-token');
    });

    test('an empty stored map reads as no token', () async {
      SharedPreferences.setMockInitialValues({
        DeviceOrderAccessStore.tokensKey: '{}',
      });

      expect(await const DeviceOrderAccessStore().readToken(contextKey: validQrToken), isNull);
    });

    test('the order token is kept apart from the reservation token', () async {
      SharedPreferences.setMockInitialValues({
        DeviceReservationAccessStore.tokenKey: 'reservation-token',
      });
      const store = DeviceOrderAccessStore();

      await store.writeToken(contextKey: validQrToken, token: 'order-token');

      expect(
        await const DeviceReservationAccessStore().readToken(),
        'reservation-token',
      );
      expect(await store.readToken(contextKey: validQrToken), 'order-token');
    });

    test('clearing an order token leaves the reservation token alone', () async {
      SharedPreferences.setMockInitialValues({
        DeviceReservationAccessStore.tokenKey: 'reservation-token',
      });
      const store = DeviceOrderAccessStore();
      await store.writeToken(contextKey: validQrToken, token: 'order-token');

      await store.clearToken(contextKey: validQrToken);

      expect(await store.readToken(contextKey: validQrToken), isNull);
      expect(
        await const DeviceReservationAccessStore().readToken(),
        'reservation-token',
      );
    });

    test('writing an order token leaves the reservation token alone', () async {
      SharedPreferences.setMockInitialValues({
        DeviceReservationAccessStore.tokenKey: 'reservation-token',
      });
      const store = DeviceOrderAccessStore();

      await store.writeToken(contextKey: validQrToken, token: 'order-token');

      expect(
        await const DeviceReservationAccessStore().readToken(),
        'reservation-token',
      );
    });
  });

  group('orderAccessContextKey', () {
    test('normalizes a context and refuses a blank one', () {
      expect(orderAccessContextKey(validQrToken), validQrToken);
      expect(orderAccessContextKey('  $validQrToken  '), validQrToken);
      expect(orderAccessContextKey(''), isNull);
      expect(orderAccessContextKey('   '), isNull);
    });
  });

  group('OrderRepository.createOrder', () {
    test('sends the qr token and item ids only', () async {
      Map<String, dynamic>? sentBody;
      final httpClient = RecordingHttpClient((request, body) async {
        sentBody = jsonDecode(body!) as Map<String, dynamic>;
        return http.Response(
          encodeOrderRpcResult(buildCreatedOrderJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      final repository = OrderRepository.withClient(client);
      final created = await repository.createOrder(
        qrToken: validQrToken,
        lines: [testCartLine(quantity: 2)],
      );

      expect(httpClient.requests.single.url.path, contains(
        '/rpc/${OrderRepository.createFunctionName}',
      ));
      expect(sentBody!.keys, ['p_qr_token', 'p_items']);
      expect(sentBody!['p_qr_token'], validQrToken);
      expect(sentBody!['p_items'], [
        {'item_id': '77777777-7777-7777-7777-777777777777', 'quantity': 2},
      ]);
      expect(created?.accessToken, guestOrderAccessToken);
      expect(created?.order.orderNumber, 1043);
    });

    test('never sends a restaurant, branch or table id', () async {
      Map<String, dynamic>? sentBody;
      final httpClient = RecordingHttpClient((request, body) async {
        sentBody = jsonDecode(body!) as Map<String, dynamic>;
        return http.Response(
          encodeOrderRpcResult(buildCreatedOrderJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      await OrderRepository.withClient(client).createOrder(
        qrToken: validQrToken,
        lines: [testCartLine()],
      );

      expect(sentBody!.containsKey('restaurant_id'), isFalse);
      expect(sentBody!.containsKey('branch_id'), isFalse);
      expect(sentBody!.containsKey('table_id'), isFalse);
      expect(sentBody!.containsKey('order_id'), isFalse);
      expect(sentBody!.containsKey('total'), isFalse);
    });

    test('an empty cart never reaches the database', () async {
      final httpClient = RecordingHttpClient(
        (request, body) async => http.Response('null', 200),
      );
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      final repository = OrderRepository.withClient(client);

      expect(await repository.createOrder(qrToken: validQrToken, lines: const []), isNull);
      expect(httpClient.requests, isEmpty);
    });

    test('a blank qr token never reaches the database', () async {
      final httpClient = RecordingHttpClient(
        (request, body) async => http.Response('null', 200),
      );
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      final repository = OrderRepository.withClient(client);

      expect(
        await repository.createOrder(qrToken: '  ', lines: [testCartLine()]),
        isNull,
      );
      expect(httpClient.requests, isEmpty);
    });

    test('an unknown, deleted or inactive token resolves to nothing', () async {
      final httpClient = RecordingHttpClient(
        (request, body) async => http.Response('null', 200),
      );
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      final created = await OrderRepository.withClient(
        client,
      ).createOrder(qrToken: validQrToken, lines: [testCartLine()]);

      expect(created, isNull);
    });

    test('a second order reuses the guest token the database already gave', () async {
      Map<String, dynamic>? sentBody;
      final httpClient = RecordingHttpClient((request, body) async {
        sentBody = jsonDecode(body!) as Map<String, dynamic>;
        return http.Response(
          encodeOrderRpcResult(buildCreatedOrderJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      await OrderRepository.withClient(client).createOrder(
        qrToken: validQrToken,
        lines: [testCartLine()],
        accessToken: '  $guestOrderAccessToken  ',
      );

      expect(sentBody!['p_access_token'], guestOrderAccessToken);
      expect(sentBody!.keys, ['p_qr_token', 'p_items', 'p_access_token']);
    });

    test('a guest with no token yet sends none, so the database mints one', () async {
      final httpClient = RecordingHttpClient((request, body) async {
        return http.Response(
          encodeOrderRpcResult(buildCreatedOrderJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      final repository = OrderRepository.withClient(client);

      await repository.createOrder(
        qrToken: validQrToken,
        lines: [testCartLine()],
        accessToken: '   ',
      );
      await repository.createOrder(
        qrToken: validQrToken,
        lines: [testCartLine()],
      );

      for (final body in [
        jsonDecode(httpClient.requestBodies.first!) as Map<String, dynamic>,
        jsonDecode(httpClient.requestBodies.last!) as Map<String, dynamic>,
      ]) {
        expect(body.containsKey('p_access_token'), isFalse);
      }
    });

    test('a refused order surfaces as an error for the page to map', () async {
      final httpClient = RecordingHttpClient((request, body) async {
        return http.Response(
          jsonEncode({
            'code': 'P0001',
            'message': 'unavailable_menu_item',
            'details': null,
            'hint': null,
          }),
          400,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      expect(
        OrderRepository.withClient(client).createOrder(
          qrToken: validQrToken,
          lines: [testCartLine()],
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('works for a signed-out guest, because a guest has no session', () async {
      final httpClient = RecordingHttpClient((request, body) async {
        return http.Response(
          encodeOrderRpcResult(buildCreatedOrderJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      expect(client.auth.currentUser, isNull);

      final created = await OrderRepository.withClient(
        client,
      ).createOrder(qrToken: validQrToken, lines: [testCartLine()]);

      expect(created, isNotNull);
    });
  });
}
