import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:menukg_flutter/app/router/app_router.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/pages/public_menu_page.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/order_access_store.dart';
import 'package:menukg_flutter/features/customer/orders/data/repositories/order_repository.dart';
import 'package:menukg_flutter/features/customer/orders/presentation/order_error_message.dart';
import 'package:menukg_flutter/features/customer/orders/presentation/pages/my_orders_page.dart';
import 'package:menukg_flutter/features/customer/reservations/data/reservation_access_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/order_test_data.dart';
import 'support/public_menu_test_data.dart';

/// A second table's QR context, so cross-context isolation can be exercised.
const String otherQrToken = 'f0e1d2c3-b4a5-4968-8776-655443332211';

/// Pumps the guest's own order history for one QR context.
Future<void> pumpMyOrders(
  WidgetTester tester,
  OrderRepository repository,
  OrderAccessStore accessStore, {
  String contextKey = validQrToken,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      onGenerateRoute: AppRouter.onGenerateRoute,
      home: Builder(
        builder: (context) => MyOrdersPage(
          contextKey: contextKey,
          repository: repository,
          accessStore: accessStore,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every piece of text the page actually rendered.
String renderedText(WidgetTester tester) {
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((Text text) => text.data ?? text.textSpan?.toPlainText() ?? '')
      .join('\n');
}

/// A repository whose rpc call records the body it was given and answers with
/// [payload], so the tests assert on the request that would really be sent.
({RecordingHttpClient httpClient, OrderRepository repository}) repositoryAnswering(
  Object? payload, {
  int status = 200,
}) {
  final httpClient = RecordingHttpClient(
    (request, body) async => http.Response(
      encodeOrderRpcResult(payload),
      status,
      headers: {'content-type': 'application/json'},
    ),
  );
  final client = buildSupabaseTestClient(httpClient);
  return (httpClient: httpClient, repository: OrderRepository.withClient(client));
}

void main() {
  group('tryParseOrders', () {
    test('reads back the same shape the order confirmation reads', () {
      final orders = tryParseOrders(
        encodeOrderRpcResult(buildGuestOrdersJson()),
      );

      expect(orders, hasLength(1));
      final order = orders.single;
      expect(order.id, '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136');
      expect(order.numberLabel, '#1043');
      expect(order.status, OrderStatus.pending);
      expect(order.currency, 'KGS');
      expect(order.totalMinorUnits, 90000);
      expect(order.totalLabel, '900.00 KGS');
      expect(order.itemCount, 2);
      expect(order.restaurantName, 'Ala-Too');
      expect(order.branchName, 'Center');
      expect(order.table.label, 'Table 12 · Window');
      expect(order.lines.single.label, '2 × Beshbarmak');
    });

    test('returns every order the payload holds, in the order sent', () {
      final orders = tryParseOrders(
        encodeOrderRpcResult(
          buildGuestOrdersJson(
            orders: [
              buildOrderJson(
                id: '2b0d6f0e-0000-4000-8000-000000000002',
                orderNumber: 1044,
                createdAt: '2026-10-06T09:00:00+00:00',
              ),
              buildOrderJson(
                id: '3c1e7a1f-0000-4000-8000-000000000003',
                orderNumber: 1043,
                createdAt: '2026-10-05T14:22:31.504534+00:00',
              ),
            ],
          ),
        ),
      );

      expect(orders.map((OrderModel o) => o.orderNumber), [1044, 1043]);
      expect(orders.first.id, '2b0d6f0e-0000-4000-8000-000000000002');
    });

    test('an unknown or empty token payload is an empty list, not an error', () {
      expect(tryParseOrders(encodeOrderRpcResult({'orders': []})), isEmpty);
      expect(tryParseOrders(encodeOrderRpcResult({'orders': null})), isEmpty);
    });

    test('a payload that is not a list of orders reads as empty', () {
      expect(tryParseOrders(null), isEmpty);
      expect(tryParseOrders(''), isEmpty);
      expect(tryParseOrders('not json'), isEmpty);
      expect(tryParseOrders('null'), isEmpty);
      expect(tryParseOrders('{}'), isEmpty);
      expect(tryParseOrders('[]'), isEmpty);
      expect(tryParseOrders(encodeOrderRpcResult({'orders': 'nope'})), isEmpty);
      expect(
        tryParseOrders(encodeOrderRpcResult({'orders': [1, 'two']})),
        isEmpty,
      );
    });

    test('one unreadable order does not hide the orders around it', () {
      final orders = tryParseOrders(
        encodeOrderRpcResult(
          buildGuestOrdersJson(
            orders: [
              buildOrderJson(id: 'first-order'),
              // A status this client cannot name is skipped rather than shown.
              buildOrderJson(id: 'broken-order', status: 'PAID'),
              buildOrderJson(id: 'last-order'),
            ],
          ),
        ),
      );

      expect(orders.map((OrderModel o) => o.id), ['first-order', 'last-order']);
    });

    test('a read payload carries no token and no restaurant, branch or table id',
        () {
      final raw = buildGuestOrdersJson();
      final order = (raw['orders']! as List).single as Map<String, dynamic>;
      final line = (order['items']! as List).single as Map<String, dynamic>;

      expect(raw.containsKey('access_token'), isFalse);
      expect(order.containsKey('access_token'), isFalse);
      expect(order.containsKey('restaurant_id'), isFalse);
      expect(order.containsKey('branch_id'), isFalse);
      expect(order.containsKey('table_id'), isFalse);
      expect(line.containsKey('order_id'), isFalse);
      expect(line.containsKey('restaurant_id'), isFalse);
    });

    test('keeps the snapshot of a product that has since been deleted', () {
      final orders = tryParseOrders(
        encodeOrderRpcResult(
          buildGuestOrdersJson(
            orders: [
              buildOrderJson(
                items: [
                  {
                    ...buildOrderLineJson(),
                    'menu_item_id': null,
                    'product_name': 'Retired Dish',
                    'unit_price': 350,
                    'line_total': 700,
                    'quantity': 2,
                  },
                ],
              ),
            ],
          ),
        ),
      );

      final line = orders.single.lines.single;
      expect(line.menuItemId, isNull);
      expect(line.productName, 'Retired Dish');
      expect(line.unitPriceMinorUnits, 35000);
      expect(line.lineTotalMinorUnits, 70000);
    });

    test('names the lifecycle states the database can now report', () {
      expect(OrderStatus.pending.displayLabel, 'Pending');
      expect(OrderStatus.pending.databaseValue, 'PENDING');
      expect(OrderStatus.accepted.displayLabel, 'Accepted');
      expect(OrderStatus.preparing.displayLabel, 'Preparing');
      expect(OrderStatus.ready.displayLabel, 'Ready');
      expect(OrderStatus.served.displayLabel, 'Served');
      expect(OrderStatus.cancelled.displayLabel, 'Cancelled');
    });
  });

  group('formatOrderPlacedAt', () {
    test('shows the moment in the guest\'s own timezone', () {
      final placedAt = DateTime.parse('2026-10-05T14:22:31.504534+00:00');
      final local = placedAt.toLocal();

      expect(
        formatOrderPlacedAt(placedAt),
        formatOrderPlacedAt(placedAt.toUtc()),
      );
      expect(formatOrderPlacedAt(placedAt), contains('${local.year}'));
      expect(formatOrderPlacedAt(placedAt), contains(local.hour.toString().padLeft(2, '0')));
      expect(formatOrderPlacedAt(placedAt), contains(local.minute.toString().padLeft(2, '0')));
    });

    test('reads as a day and a time, never as a raw timestamp', () {
      final label = formatOrderPlacedAt(
        DateTime.parse('2026-10-05T14:22:31.504534+00:00'),
      );

      expect(label, isNot(contains('T')));
      expect(label, isNot(contains('+')));
      expect(label, contains(' · '));
    });
  });

  group('OrderRepository.getMyOrders', () {
    test('sends the stored token and nothing else', () async {
      Map<String, dynamic>? sentBody;
      final httpClient = RecordingHttpClient((request, body) async {
        sentBody = jsonDecode(body!) as Map<String, dynamic>;
        return http.Response(
          encodeOrderRpcResult(buildGuestOrdersJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      final orders = await OrderRepository.withClient(
        client,
      ).getMyOrders('  $guestOrderAccessToken  ');

      expect(
        httpClient.requests.single.url.path,
        contains('/rpc/${OrderRepository.listFunctionName}'),
      );
      expect(sentBody, {'p_access_token': guestOrderAccessToken});
      expect(orders.single.orderNumber, 1043);
    });

    test('never sends a restaurant, branch, table or order id', () async {
      Map<String, dynamic>? sentBody;
      final httpClient = RecordingHttpClient((request, body) async {
        sentBody = jsonDecode(body!) as Map<String, dynamic>;
        return http.Response(
          encodeOrderRpcResult(buildGuestOrdersJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      await OrderRepository.withClient(client).getMyOrders(guestOrderAccessToken);

      expect(sentBody!.keys, ['p_access_token']);
      for (final forbidden in [
        'p_restaurant_id',
        'p_branch_id',
        'p_table_id',
        'p_order_id',
        'p_qr_token',
      ]) {
        expect(sentBody!.containsKey(forbidden), isFalse);
      }
    });

    test('no token never reaches the database', () async {
      final answer = repositoryAnswering(buildGuestOrdersJson());

      expect(await answer.repository.getMyOrders(null), isEmpty);
      expect(answer.httpClient.requests, isEmpty);
    });

    test('an empty token never reaches the database', () async {
      for (final blank in ['', '   ', '\n']) {
        final answer = repositoryAnswering(buildGuestOrdersJson());

        expect(await answer.repository.getMyOrders(blank), isEmpty);
        expect(answer.httpClient.requests, isEmpty);
      }
    });

    test('an unknown token reads as no orders rather than an error', () async {
      final answer = repositoryAnswering({'orders': []});

      expect(
        await answer.repository.getMyOrders('not-a-real-token'),
        isEmpty,
      );
      // The request was made; it simply matched nothing.
      expect(answer.httpClient.requests, hasLength(1));
    });

    test('returns every order of a guest who ordered more than once', () async {
      final answer = repositoryAnswering(
        buildGuestOrdersJson(
          orders: [
            buildOrderJson(
              id: '2b0d6f0e-0000-4000-8000-000000000002',
              orderNumber: 1044,
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
            buildOrderJson(),
          ],
        ),
      );

      final orders = await answer.repository.getMyOrders(guestOrderAccessToken);

      expect(orders.map((OrderModel o) => o.orderNumber), [1044, 1043]);
      expect(orders.first.totalLabel, '1500.50 KGS');
      expect(orders.first.lines.map((OrderLineModel l) => l.label), [
        '2 × Beshbarmak',
        '1 × Kebab',
      ]);
    });

    test('reads the stored totals and snapshots, in whole minor units', () async {
      final answer = repositoryAnswering(buildGuestOrdersJson());

      final order = (await answer.repository.getMyOrders(
        guestOrderAccessToken,
      )).single;

      expect(order.totalMinorUnits, 90000);
      expect(order.totalLabel, '900.00 KGS');
      expect(order.lines.single.unitPriceMinorUnits, 45000);
      expect(order.lines.single.lineTotalMinorUnits, 90000);
      expect(
        order.lines.fold<int>(
          0,
          (int sum, OrderLineModel l) => sum + l.lineTotalMinorUnits,
        ),
        order.totalMinorUnits,
      );
    });

    test('a read failure surfaces as an error for the page to map', () async {
      final answer = repositoryAnswering(
        {
          'code': '42501',
          'message': 'permission denied for function guest_orders',
          'details': null,
          'hint': null,
        },
        status: 401,
      );

      expect(
        answer.repository.getMyOrders(guestOrderAccessToken),
        throwsA(isA<Exception>()),
      );
    });

    test('works for a signed-out guest, because a guest has no session', () async {
      final answer = repositoryAnswering(buildGuestOrdersJson());

      expect(answer.httpClient, isNotNull);

      final orders = await answer.repository.getMyOrders(
        guestOrderAccessToken,
      );

      expect(orders, hasLength(1));
    });
  });

  group('MyOrdersPage', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('a device that never ordered has no orders and asks nothing',
        (tester) async {
      final repository = FakeOrderRepository();

      await pumpMyOrders(tester, repository, MemoryOrderAccessStore());

      // Asked with no token, which is the same answer the database gives.
      expect(repository.listCalls, [null]);
      expect(find.byKey(const Key('ordersEmptyState')), findsOneWidget);
      expect(
        find.textContaining('No orders on this device yet.'),
        findsOneWidget,
      );
      expect(find.textContaining('Open a table QR code to place one.'),
          findsOneWidget);
    });

    testWidgets('lists every order of the stored token, newest first',
        (tester) async {
      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [
            buildOrderModel(
              id: 'newer-order',
              orderNumber: 1044,
              createdAt: '2026-10-06T09:00:00+00:00',
            ),
            buildOrderModel(
              id: 'older-order',
              orderNumber: 1043,
              createdAt: '2026-10-05T14:22:31.504534+00:00',
            ),
          ],
        },
      );

      await pumpMyOrders(
        tester,
        repository,
        MemoryOrderAccessStore(validQrToken, guestOrderAccessToken),
      );

      expect(repository.listCalls, [guestOrderAccessToken]);
      expect(find.text('#1044'), findsOneWidget);
      expect(find.text('#1043'), findsOneWidget);
      // The order the database sent first is the one shown first.
      expect(
        tester.getTopLeft(find.byKey(const Key('orderCard_newer-order'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('orderCard_older-order'))).dy,
        ),
      );
    });

    testWidgets('shows when, what and how much of every order', (tester) async {
      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [
            buildOrderModel(
              id: 'one-order',
              total: 1500.50,
              itemCount: 3,
              lines: const [
                OrderLineModel(
                  menuItemId: '77777777-7777-7777-7777-777777777777',
                  productName: 'Beshbarmak',
                  unitPriceMinorUnits: 45000,
                  quantity: 2,
                  lineTotalMinorUnits: 90000,
                ),
                OrderLineModel(
                  menuItemId: '88888888-8888-8888-8888-888888888888',
                  productName: 'Kebab',
                  unitPriceMinorUnits: 60050,
                  quantity: 1,
                  lineTotalMinorUnits: 60050,
                ),
              ],
            ),
          ],
        },
      );

      await pumpMyOrders(
        tester,
        repository,
        MemoryOrderAccessStore(validQrToken, guestOrderAccessToken),
      );

      final placedAt = buildOrderModel().createdAt;
      expect(
        find.byKey(const Key('orderHistoryPlacedAt_one-order')),
        findsOneWidget,
      );
      expect(
        find.text(formatOrderPlacedAt(placedAt)),
        findsOneWidget,
      );
      expect(find.byKey(const Key('orderHistoryStatus_one-order')), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Ala-Too · Center'), findsOneWidget);
      expect(find.text('Table 12 · Window'), findsOneWidget);

      // Quantities, per-line totals and the order total.
      expect(find.text('2 × Beshbarmak'), findsOneWidget);
      expect(find.text('900.00 KGS'), findsOneWidget);
      expect(find.text('1 × Kebab'), findsOneWidget);
      expect(find.text('600.50 KGS'), findsOneWidget);
      expect(find.text('1500.50 KGS'), findsOneWidget);
      expect(find.text('3 items'), findsOneWidget);
    });

    testWidgets('shows the snapshot of a product that has since been deleted',
        (tester) async {
      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [
            buildOrderModel(
              id: 'retired-order',
              total: 700,
              itemCount: 2,
              lines: const [
                OrderLineModel(
                  menuItemId: null,
                  productName: 'Retired Dish',
                  unitPriceMinorUnits: 35000,
                  quantity: 2,
                  lineTotalMinorUnits: 70000,
                ),
              ],
            ),
          ],
        },
      );

      await pumpMyOrders(
        tester,
        repository,
        MemoryOrderAccessStore(validQrToken, guestOrderAccessToken),
      );

      // The snapshot survives: the line still names and prices the dish the menu
      // no longer has, and the total still adds up to what it did.
      expect(find.text('2 × Retired Dish'), findsOneWidget);
      expect(find.byKey(const Key('orderHistoryLine_retired-order_0')),
          findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('orderHistoryTotal_retired-order')))
            .data,
        '700.00 KGS',
      );
    });

    testWidgets('an invalid or expired token shows nothing of anyone else',
        (tester) async {
      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [buildOrderModel()],
        },
      );

      await pumpMyOrders(
        tester,
        repository,
        MemoryOrderAccessStore(validQrToken, 'a-token-the-database-never-minted'),
      );

      expect(find.byKey(const Key('ordersEmptyState')), findsOneWidget);
      expect(find.text('#1043'), findsNothing);
      expect(find.textContaining('Ala-Too'), findsNothing);
    });

    testWidgets('another guest\'s token opens nobody\'s orders', (tester) async {
      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [buildOrderModel(id: 'mine')],
          otherGuestOrderAccessToken: [buildForeignOrderModel()],
        },
      );

      await pumpMyOrders(
        tester,
        repository,
        MemoryOrderAccessStore(
          validQrToken,
          otherGuestOrderAccessToken,
        ),
      );

      // This guest has their own order, and only that one: the other guest's
      // restaurant is nowhere on screen.
      expect(find.text('1 × Foreign Dish'), findsOneWidget);
      expect(find.text('Beshkempir · Airport'), findsOneWidget);
      expect(find.textContaining('Ala-Too'), findsNothing);
      expect(find.byKey(const Key('orderCard_one-order')), findsNothing);
    });

    testWidgets('a token cannot reach another QR context\'s orders',
        (tester) async {
      final store = MemoryOrderAccessStore(validQrToken, guestOrderAccessToken);
      await store.writeToken(
        contextKey: otherQrToken,
        token: otherContextOrderAccessToken,
      );
      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [
            buildOrderModel(id: 'table-12-order', orderNumber: 1043),
          ],
          otherContextOrderAccessToken: [
            buildOrderModel(
              id: 'table-99-order',
              orderNumber: 55,
              tableNumber: '99',
              tableName: null,
            ),
          ],
        },
      );

      await pumpMyOrders(tester, repository, store);

      expect(repository.listCalls, [guestOrderAccessToken]);
      expect(find.byKey(const Key('orderCard_table-12-order')), findsOneWidget);
      expect(find.byKey(const Key('orderCard_table-99-order')), findsNothing);
      expect(find.text('Table 12 · Window'), findsOneWidget);
      expect(find.text('Table 99'), findsNothing);

      // The same store, opened for the other table, reads that table's orders.
      await pumpMyOrders(tester, repository, store, contextKey: otherQrToken);

      expect(repository.listCalls.last, otherContextOrderAccessToken);
      expect(find.byKey(const Key('orderCard_table-99-order')), findsOneWidget);
      expect(find.byKey(const Key('orderCard_table-12-order')), findsNothing);
    });

    testWidgets('the raw access token is never rendered anywhere',
        (tester) async {
      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [
            buildOrderModel(id: 'one-order'),
            buildOrderModel(id: 'two-order', orderNumber: 1044),
          ],
        },
      );

      await pumpMyOrders(
        tester,
        repository,
        MemoryOrderAccessStore(validQrToken, guestOrderAccessToken),
      );

      final text = renderedText(tester);
      expect(text, isNotEmpty);
      expect(text, isNot(contains(guestOrderAccessToken)));
      // Not even a recognisable fragment of it.
      expect(text, isNot(contains(guestOrderAccessToken.substring(0, 20))));
      expect(text, isNot(contains(guestOrderAccessToken.substring(40))));
      expect(find.byWidgetPredicate((Widget widget) {
        final data = widget is Text ? widget.data : null;
        return data != null && data.contains(guestOrderAccessToken);
      }), findsNothing);
    });

    testWidgets('offers a retry when the history cannot be loaded',
        (tester) async {
      final repository = FakeOrderRepository(
        listError: StateError('network down'),
      );

      await pumpMyOrders(
        tester,
        repository,
        MemoryOrderAccessStore(validQrToken, guestOrderAccessToken),
      );

      expect(
        find.text('We could not load your orders. Please try again.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('retryOrdersButton')), findsOneWidget);
      expect(find.byKey(const Key('ordersEmptyState')), findsNothing);
    });

    testWidgets('a revoked read path is reported without leaking anything',
        (tester) async {
      final repository = FakeOrderRepository(
        listError: orderPostgrestError(
          '42501',
          message: 'permission denied for function guest_orders',
        ),
      );

      await pumpMyOrders(
        tester,
        repository,
        MemoryOrderAccessStore(validQrToken, guestOrderAccessToken),
      );

      expect(find.text('Your orders are not available right now.'),
          findsOneWidget);
      expect(
        orderListErrorMessage(
          orderPostgrestError('42501', message: 'permission denied'),
        ),
        'Your orders are not available right now.',
      );
      expect(renderedText(tester), isNot(contains('guest_orders')));
      expect(renderedText(tester), isNot(contains('permission denied')));
    });

    testWidgets('retrying reloads the list with the stored token',
        (tester) async {
      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [buildOrderModel(id: 'one-order')],
        },
      );
      final store = MemoryOrderAccessStore(validQrToken, guestOrderAccessToken);

      await pumpMyOrders(tester, repository, store);
      await tester.tap(find.byKey(const Key('reloadOrdersButton')));
      await tester.pumpAndSettle();

      expect(repository.listCalls, [
        guestOrderAccessToken,
        guestOrderAccessToken,
      ]);
      expect(find.byKey(const Key('orderCard_one-order')), findsOneWidget);
    });

    testWidgets('the reservation token is never used to read orders',
        (tester) async {
      final orderStore = MemoryOrderAccessStore(
        validQrToken,
        guestOrderAccessToken,
      );
      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [buildOrderModel()],
        },
      );

      await pumpMyOrders(tester, repository, orderStore);

      expect(repository.listCalls, [guestOrderAccessToken]);
      for (final call in repository.listCalls) {
        expect(call, isNot(DeviceReservationAccessStore.tokenKey));
        expect(call, isNot(otherGuestOrderAccessToken));
      }
    });

    testWidgets('the order token is stored per context, never in the ui',
        (tester) async {
      const store = DeviceOrderAccessStore();
      await store.writeToken(
        contextKey: validQrToken,
        token: guestOrderAccessToken,
      );

      await pumpMyOrders(
        tester,
        FakeOrderRepository(),
        store,
      );

      // The list asked for this context's token and nothing else, and a device
      // store is never written to by reading.
      expect(await store.readToken(contextKey: otherQrToken), isNull);
      expect(
        await store.readToken(contextKey: validQrToken),
        guestOrderAccessToken,
      );
    });
  });

  group('PublicMenuPage order history entry', () {
    testWidgets('reaches the guest\'s orders without a new route', (
      tester,
    ) async {
      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [buildOrderModel(id: 'placed-here')],
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: Builder(
            builder: (context) => PublicMenuPage(
              qrToken: validQrToken,
              repository: FakePublicMenuRepository(buildMenuJson()),
              orderRepository: repository,
              orderAccessStore: MemoryOrderAccessStore(
                validQrToken,
                guestOrderAccessToken,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('myOrdersButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('myOrdersButton')));
      await tester.pumpAndSettle();

      expect(find.text('My orders'), findsOneWidget);
      expect(repository.listCalls, [guestOrderAccessToken]);
      expect(find.byKey(const Key('orderCard_placed-here')), findsOneWidget);
      expect(renderedText(tester), isNot(contains(guestOrderAccessToken)));

      // Back returns to the same menu.
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('cartButton')), findsOneWidget);
      expect(find.byKey(const Key('reserveTableButton')), findsOneWidget);
    });

    testWidgets('the cart and reservation entries still work next to it', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: Builder(
            builder: (context) => PublicMenuPage(
              qrToken: validQrToken,
              repository: FakePublicMenuRepository(buildMenuJson()),
              orderRepository: FakeOrderRepository(),
              orderAccessStore: MemoryOrderAccessStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('cartButton')), findsOneWidget);
      expect(find.byKey(const Key('reserveTableButton')), findsOneWidget);
      expect(find.byKey(const Key('myReservationsButton')), findsOneWidget);
      expect(find.byKey(const Key('myOrdersButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('cartButton')));
      await tester.pumpAndSettle();
      expect(find.text('Your cart'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('reserveTableButton')));
      await tester.pumpAndSettle();
      expect(find.text('Reserve a table'), findsOneWidget);
    });

    testWidgets('the public qr route is unchanged', (tester) async {
      final route = AppRouter.onGenerateRoute(
        RouteSettings(name: AppRouter.publicMenuRoute(validQrToken)),
      );

      expect(route, isNotNull);
      expect(route!.settings.name, '/t/$validQrToken');
      expect(AppRouter.parsePublicMenuQrToken('/t/$validQrToken'),
          validQrToken);
      // There is no public path that opens a past order, because a past order
      // only exists for the QR context that placed it.
      expect(AppRouter.parsePublicMenuQrToken('/orders'), isNull);
      expect(AppRouter.parsePublicMenuQrToken('/t/$validQrToken/orders'), isNull);
    });
  });
}
