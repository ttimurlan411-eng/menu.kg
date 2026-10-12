import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:menukg_flutter/app/router/app_router.dart';
import 'package:menukg_flutter/features/customer/cart/data/models/cart_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/customer/orders/data/order_access_store.dart';
import 'package:menukg_flutter/features/customer/orders/data/repositories/order_repository.dart';
import 'package:menukg_flutter/features/customer/orders/presentation/pages/my_orders_page.dart';

import 'support/order_test_data.dart';
import 'support/public_menu_test_data.dart';

/// The moves the restaurant workflow allows, written out here rather than read from
/// the enum, so the Dart lifecycle is checked against the rule and not against
/// itself. `guard_order_status_transition` in the database holds the same rule, and
/// `supabase/tests/order_status_lifecycle.sql` checks all 36 pairs there.
const Map<String, Set<String>> allowedMoves = {
  'PENDING': {'ACCEPTED', 'CANCELLED'},
  'ACCEPTED': {'PREPARING', 'CANCELLED'},
  'PREPARING': {'READY', 'CANCELLED'},
  'READY': {'SERVED'},
  'SERVED': <String>{},
  'CANCELLED': <String>{},
};

/// The lifecycle states, in the order the restaurant walks through them.
const List<String> lifecycleStates = [
  'PENDING',
  'ACCEPTED',
  'PREPARING',
  'READY',
  'SERVED',
  'CANCELLED',
];

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

/// A repository that answers an rpc call with [payload] and records the body, so a
/// test can assert on the request that would really be sent.
({RecordingHttpClient httpClient, OrderRepository repository}) repositoryAnswering(
  Object? payload,
) {
  final httpClient = RecordingHttpClient(
    (request, body) async => http.Response(
      encodeOrderRpcResult(payload),
      200,
      headers: {'content-type': 'application/json'},
    ),
  );
  return (
    httpClient: httpClient,
    repository: OrderRepository.withClient(buildSupabaseTestClient(httpClient)),
  );
}

/// One cart line, so an order can actually be placed.
CartLineModel testCartLine() => CartLineModel.fromMenuItem(
  const PublicMenuItemModel(
    id: '77777777-7777-7777-7777-777777777777',
    name: 'Beshbarmak',
    description: null,
    price: 450,
    oldPrice: null,
    mainImageUrl: null,
    preparationTimeMinutes: 20,
  ),
  quantity: 2,
);

void main() {
  group('OrderStatus', () {
    test('holds exactly the states the database can store', () {
      expect(
        OrderStatus.values.map((status) => status.databaseValue),
        lifecycleStates,
      );
    });

    test('names every state for the guest, once each', () {
      final labels = OrderStatus.values
          .map((status) => status.displayLabel)
          .toList();

      expect(labels, [
        'Pending',
        'Accepted',
        'Preparing',
        'Ready',
        'Served',
        'Cancelled',
      ]);
      // Two states sharing a label would leave a guest unable to tell them apart.
      expect(labels.toSet().length, labels.length);
    });

    test('every state round trips through its database value', () {
      for (final status in OrderStatus.values) {
        expect(OrderStatus.fromDatabase(status.databaseValue), status);
      }
    });

    test('a new order starts pending', () {
      // The only state the guest flow can produce: create_table_order inserts
      // PENDING and nothing else, and the check constraint accepts it.
      expect(OrderStatus.pending.databaseValue, 'PENDING');
      expect(
        tryParseCreatedOrder(encodeOrderRpcResult(buildCreatedOrderJson()))!
            .order
            .status,
        OrderStatus.pending,
      );
    });

    test('an order placed before the lifecycle existed still reads as pending', () {
      final order = tryParseOrders(
        encodeOrderRpcResult(
          buildGuestOrdersJson(orders: [buildOrderJson()]),
        ),
      ).single;

      expect(order.status, OrderStatus.pending);
      expect(order.status.displayLabel, 'Pending');
    });
  });

  group('the lifecycle', () {
    test('the normal path is the single forward chain', () {
      const normalPath = [
        OrderStatus.pending,
        OrderStatus.accepted,
        OrderStatus.preparing,
        OrderStatus.ready,
        OrderStatus.served,
      ];

      for (var index = 0; index < normalPath.length - 1; index++) {
        expect(
          normalPath[index].canTransitionTo(normalPath[index + 1]),
          isTrue,
          reason: '${normalPath[index].databaseValue} -> '
              '${normalPath[index + 1].databaseValue} must be possible',
        );
      }

      // And nothing skips ahead along the way.
      expect(normalPath[0].canTransitionTo(normalPath[2]), isFalse);
      expect(normalPath[1].canTransitionTo(normalPath[4]), isFalse);
      expect(normalPath[2].canTransitionTo(normalPath[4]), isFalse);
    });

    test('every one of the 36 state pairs matches the restaurant rule', () {
      var checked = 0;

      for (final from in OrderStatus.values) {
        for (final to in OrderStatus.values) {
          checked++;
          expect(
            from.canTransitionTo(to),
            allowedMoves[from.databaseValue]!.contains(to.databaseValue),
            reason: '${from.databaseValue} -> ${to.databaseValue}',
          );
        }
      }

      expect(checked, 36);
    });

    test('cancellation is possible from pending, accepted and preparing only', () {
      const cancellable = [
        OrderStatus.pending,
        OrderStatus.accepted,
        OrderStatus.preparing,
      ];

      for (final status in OrderStatus.values) {
        expect(
          status.canTransitionTo(OrderStatus.cancelled),
          cancellable.contains(status),
          reason: 'cancelling from ${status.databaseValue}',
        );
      }

      // Ready is the state where the decision stops being free: the food exists.
      expect(OrderStatus.ready.canTransitionTo(OrderStatus.cancelled), isFalse);
      expect(OrderStatus.served.canTransitionTo(OrderStatus.cancelled), isFalse);
      expect(OrderStatus.cancelled.canTransitionTo(OrderStatus.cancelled), isFalse);
    });

    test('served is terminal', () {
      expect(OrderStatus.served.isTerminal, isTrue);
      expect(OrderStatus.served.allowedNextStatuses, isEmpty);

      for (final next in OrderStatus.values) {
        expect(
          OrderStatus.served.canTransitionTo(next),
          isFalse,
          reason: 'a served order cannot become $next',
        );
      }
    });

    test('cancelled is terminal', () {
      expect(OrderStatus.cancelled.isTerminal, isTrue);
      expect(OrderStatus.cancelled.allowedNextStatuses, isEmpty);

      for (final next in OrderStatus.values) {
        expect(
          OrderStatus.cancelled.canTransitionTo(next),
          isFalse,
          reason: 'a cancelled order cannot become $next',
        );
      }
    });

    test('nothing else is terminal, and no state is its own next', () {
      expect(
        OrderStatus.values
            .where((status) => status.isTerminal)
            .map((status) => status.databaseValue),
        ['SERVED', 'CANCELLED'],
      );

      for (final status in OrderStatus.values) {
        expect(status.canTransitionTo(status), isFalse, reason: status.databaseValue);
      }
    });

    test('an order cannot go backwards through the chain', () {
      expect(OrderStatus.accepted.canTransitionTo(OrderStatus.pending), isFalse);
      expect(OrderStatus.preparing.canTransitionTo(OrderStatus.pending), isFalse);
      expect(
        OrderStatus.preparing.canTransitionTo(OrderStatus.accepted),
        isFalse,
      );
      expect(OrderStatus.ready.canTransitionTo(OrderStatus.pending), isFalse);
      expect(OrderStatus.ready.canTransitionTo(OrderStatus.preparing), isFalse);
      expect(OrderStatus.ready.canTransitionTo(OrderStatus.accepted), isFalse);
    });
  });

  group('an unknown database status', () {
    test('is refused rather than guessed, including a payment state', () {
      for (final value in [
        'ON_ITS_WAY',
        'PAID',
        'REFUNDED',
        'PARTIALLY_SERVED',
        'PENDING ',
        '',
      ]) {
        expect(
          () => OrderStatus.fromDatabase(value),
          throwsFormatException,
          reason: value,
        );
      }
    });

    test('does not hide the orders around it in a history', () {
      final orders = tryParseOrders(
        encodeOrderRpcResult(
          buildGuestOrdersJson(
            orders: [
              buildOrderJson(id: 'known-order', status: 'PREPARING'),
              buildOrderJson(id: 'future-order', status: 'ON_ITS_WAY'),
              buildOrderJson(id: 'known-order-2', status: 'CANCELLED'),
            ],
          ),
        ),
      );

      // The order this client cannot read is skipped; the guest still sees the
      // orders it can, rather than an empty list or a crash.
      expect(
        orders.map((order) => order.id),
        ['known-order', 'known-order-2'],
      );
      expect(orders.map((order) => order.status), [
        OrderStatus.preparing,
        OrderStatus.cancelled,
      ]);
    });

    test('leaves a history of only unreadable orders empty rather than failing', () {
      final orders = tryParseOrders(
        encodeOrderRpcResult(
          buildGuestOrdersJson(
            orders: [
              buildOrderJson(id: 'future-order', status: 'ON_ITS_WAY'),
            ],
          ),
        ),
      );

      expect(orders, isEmpty);
    });
  });

  group('guest order history', () {
    test('reads every lifecycle state back', () {
      final orders = tryParseOrders(
        encodeOrderRpcResult(
          buildGuestOrdersJson(
            orders: [
              for (var index = 0; index < lifecycleStates.length; index++)
                buildOrderJson(
                  id: 'order-$index',
                  status: lifecycleStates[index],
                ),
            ],
          ),
        ),
      );

      expect(
        orders.map((order) => order.status.databaseValue),
        lifecycleStates,
      );
    });

    test('reads an order in each lifecycle state through the repository', () async {
      final answer = repositoryAnswering(
        buildGuestOrdersJson(
          orders: [
            for (var index = 0; index < lifecycleStates.length; index++)
              buildOrderJson(
                id: 'order-$index',
                orderNumber: 1043 + index,
                status: lifecycleStates[index],
              ),
          ],
        ),
      );

      final orders = await answer.repository.getMyOrders(guestOrderAccessToken);

      expect(
        orders.map((order) => order.status),
        OrderStatus.values,
      );
      // The read is still the guest's own token and nothing else.
      expect(answer.httpClient.requestBodies.single, contains(guestOrderAccessToken));
      expect(answer.httpClient.requestBodies.single, isNot(contains('status')));
    });

    testWidgets('shows every lifecycle state on the page', (tester) async {
      // One page tall enough for every card: a ListView builds only what fits, so a
      // shorter viewport would prove the first two states and nothing else.
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [
            for (var index = 0; index < lifecycleStates.length; index++)
              buildOrderModel(
                id: 'order-$index',
                orderNumber: 1043 + index,
                status: lifecycleStates[index],
              ),
          ],
        },
      );

      await pumpMyOrders(
        tester,
        repository,
        MemoryOrderAccessStore(validQrToken, guestOrderAccessToken),
      );

      for (final status in OrderStatus.values) {
        expect(
          find.text(status.displayLabel),
          findsOneWidget,
          reason: '${status.databaseValue} must be shown, and only once',
        );
      }
    });

    testWidgets('shows a cancelled order rather than hiding it', (tester) async {
      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [
            buildOrderModel(
              id: 'cancelled-order',
              status: 'CANCELLED',
              // A different total from the line total, so the two are told apart.
              total: 1200,
            ),
          ],
        },
      );

      await pumpMyOrders(
        tester,
        repository,
        MemoryOrderAccessStore(validQrToken, guestOrderAccessToken),
      );

      expect(
        find.byKey(const Key('orderCard_cancelled-order')),
        findsOneWidget,
      );
      // What was ordered and what it came to are still there.
      expect(find.text('2 × Beshbarmak'), findsOneWidget);
      expect(find.text('900.00 KGS'), findsOneWidget);
      expect(find.text('1200.00 KGS'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
    });

    testWidgets('offers the guest no way to change a status', (tester) async {
      final repository = FakeOrderRepository(
        ordersByToken: {
          guestOrderAccessToken: [buildOrderModel(id: 'one-order')],
        },
      );

      await pumpMyOrders(
        tester,
        repository,
        MemoryOrderAccessStore(validQrToken, guestOrderAccessToken),
      );

      // The only control on the page is the refresh button: there is no staff path
      // and no guest one either, so nothing here can offer a move.
      expect(find.byKey(const Key('reloadOrdersButton')), findsOneWidget);
      expect(find.byType(IconButton), findsOneWidget);
      for (final label in ['Accept', 'Prepare', 'Serve', 'Cancel', 'Advance']) {
        expect(find.text(label), findsNothing, reason: label);
      }
    });
  });

  group('a guest cannot move an order', () {
    test('the place order request carries no status at all', () async {
      final answer = repositoryAnswering(buildCreatedOrderJson());

      await answer.repository.createOrder(
        qrToken: validQrToken,
        lines: [testCartLine()],
      );

      final body =
          jsonDecode(answer.httpClient.requestBodies.single!) as Map;
      // A QR token and a list of items: the request has no field a status could be
      // smuggled into, which is why the guest cannot ask for one.
      expect(body.keys, ['p_qr_token', 'p_items']);
      for (final entry in body['p_items'] as List) {
        expect((entry as Map).keys, ['item_id', 'quantity']);
      }
      expect(answer.httpClient.requestBodies.single, isNot(contains('status')));
    });

    test('a rejected transition is never something the guest can ask for', () {
      // The two functions a guest may execute are the create and read paths, and
      // neither takes a status: the database has no function a guest could use to
      // move an order, which supabase/tests/order_status_lifecycle.sql asserts
      // against the catalog.
      expect(OrderRepository.createFunctionName, 'create_table_order');
      expect(OrderRepository.listFunctionName, 'guest_orders');
    });

    test('a placed order arrives pending, so there is nothing to have changed', () {
      // The confirmation screen has no status control and the create response can
      // only ever report PENDING, so a guest's order starts where it will stay
      // until a staff path exists.
      final created = buildCreatedOrderModel();

      expect(created.order.status, OrderStatus.pending);
      expect(created.order.status.displayLabel, 'Pending');
    });
  });
}