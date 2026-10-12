import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_order_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_order_error_message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/order_test_data.dart';
import 'support/public_menu_test_data.dart';
import 'support/staff_order_test_data.dart';

void main() {
  group('StaffOrderModel', () {
    test('parses an order with its branch, table and stored amounts', () {
      final order = StaffOrderModel.fromJson(buildStaffOrderJson());

      expect(order.id, '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136');
      expect(order.orderNumber, 1043);
      expect(order.status, OrderStatus.pending);
      expect(order.currency, 'KGS');
      expect(order.totalMinorUnits, 90000);
      expect(order.itemCount, 2);
      expect(order.branchId, centerBranch);
      expect(order.tableId, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
      expect(order.tableNumber, '12');
      expect(order.tableName, 'Window');
      expect(order.createdAt, DateTime.parse(orderCreatedAt));
      expect(order.updatedAt, DateTime.parse(orderUpdatedAt));
    });

    test('reads the lines as the snapshots they are', () {
      final order = StaffOrderModel.fromJson(buildStaffOrderJson());

      expect(order.lines, hasLength(1));
      expect(order.lines.single.productName, 'Beshbarmak');
      expect(order.lines.single.unitPriceMinorUnits, 45000);
      expect(order.lines.single.quantity, 2);
      expect(order.lines.single.lineTotalMinorUnits, 90000);
    });

    test('an order with no table is still readable', () {
      final order = StaffOrderModel.fromJson(
        buildStaffOrderJson(tableId: null, tableNumber: null, tableName: null),
      );

      expect(order.tableId, isNull);
      expect(order.tableLabel, 'No table');
    });

    test('the table label falls back to the number when it has no name', () {
      final order = StaffOrderModel.fromJson(
        buildStaffOrderJson(tableName: null),
      );

      expect(order.tableLabel, '12');
    });

    test('formats the number and the total as staff read them', () {
      final order = StaffOrderModel.fromJson(buildStaffOrderJson(total: 1500.5));

      expect(order.numberLabel, '#1043');
      expect(order.totalLabel, '1500.50 KGS');
    });

    test('changing the status keeps every amount and the table', () {
      final order = StaffOrderModel.fromJson(buildStaffOrderJson());
      final moved = order.withStatus(
        OrderStatus.accepted,
        updatedAt: DateTime.parse(orderUpdatedAt),
      );

      expect(moved.status, OrderStatus.accepted);
      expect(moved.updatedAt, DateTime.parse(orderUpdatedAt));
      expect(moved.id, order.id);
      expect(moved.totalMinorUnits, order.totalMinorUnits);
      expect(moved.lines, same(order.lines));
      expect(moved.tableId, order.tableId);
      expect(moved.createdAt, order.createdAt);
      // The order itself is untouched, so a screen cannot lose the state it had.
      expect(order.status, OrderStatus.pending);
    });

    test('an unknown status is refused rather than guessed at', () {
      expect(
        () => StaffOrderModel.fromJson(buildStaffOrderJson(status: 'REFUNDED')),
        throwsFormatException,
      );
    });
  });

  group('tryParseStaffOrders', () {
    test('parses the payload the database sends', () {
      final orders = tryParseStaffOrders(
        encodeOrderRpcResult(buildStaffOrdersJson()),
        restaurantId: restaurantA,
      );

      expect(orders, hasLength(1));
      expect(orders.single.status, OrderStatus.pending);
      expect(orders.single.tableLabel, '12 · Window');
    });

    test('accepts a payload delivered as a string', () {
      final orders = tryParseStaffOrders(
        jsonEncode(buildStaffOrdersJson()),
        restaurantId: restaurantA,
      );

      expect(orders, hasLength(1));
    });

    test('skips an order it cannot read and keeps the ones around it', () {
      final orders = tryParseStaffOrders(
        encodeOrderRpcResult(
          buildStaffOrdersJson(
            orders: [
              buildStaffOrderJson(orderNumber: 1),
              buildStaffOrderJson(orderNumber: 2, status: 'REFUNDED'),
              buildStaffOrderJson(orderNumber: 3),
            ],
          ),
        ),
        restaurantId: restaurantA,
      );

      expect(orders.map((order) => order.orderNumber), [1, 3]);
    });

    test('skips entries that are not orders at all', () {
      final orders = tryParseStaffOrders(
        encodeOrderRpcResult(
          buildStaffOrdersJson(
            orders: ['not an order', 42, buildStaffOrderJson()],
          ),
        ),
        restaurantId: restaurantA,
      );

      expect(orders, hasLength(1));
    });

    test('refuses a payload that names another restaurant', () {
      final orders = tryParseStaffOrders(
        encodeOrderRpcResult(buildStaffOrdersJson(restaurantId: restaurantB)),
        restaurantId: restaurantA,
      );

      expect(orders, isEmpty);
    });

    test('reads nothing from an answer it cannot understand', () {
      for (final response in <Object?>[
        null,
        '',
        '   ',
        'not json',
        jsonEncode('a string, not an object'),
        jsonEncode({'orders': 'not a list'}),
        jsonEncode({'restaurant_id': restaurantA}),
        42,
      ]) {
        expect(
          tryParseStaffOrders(response, restaurantId: restaurantA),
          isEmpty,
          reason: 'nothing is read from $response',
        );
      }
    });
  });

  group('StaffOrderRepository.getOrders', () {
    test('makes no request when nobody is signed in', () async {
      final httpClient = staffHttpClient(payload: buildStaffOrdersJson());
      final repository = StaffOrderRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      expect(await repository.getOrders(restaurantId: restaurantA), isEmpty);
      expect(httpClient.requestBodies, isEmpty);
    });

    test('makes no request for a blank restaurant', () async {
      final httpClient = staffHttpClient(payload: buildStaffOrdersJson());
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      expect(await repository.getOrders(restaurantId: '  '), isEmpty);
      expect(httpClient.requestBodies.where((body) => body!.contains('p_')), isEmpty);
    });

    test('sends the restaurant and a limit, and nothing else', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrdersJson(branchId: null),
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      final orders = await repository.getOrders(restaurantId: restaurantA);

      expect(orders, hasLength(1));
      expect(
        lastRpcBody(httpClient).keys.toSet(),
        {'p_restaurant_id', 'p_limit'},
        reason: 'a whole-restaurant read names no branch, and nothing else',
      );
      expect(lastRpcBody(httpClient)['p_restaurant_id'], restaurantA);
      expect(lastRpcBody(httpClient)['p_limit'], StaffOrderRepository.defaultLimit);
    });

    test('sends a branch when one is given, and omits a blank one', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrdersJson(branchId: centerBranch),
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getOrders(
        restaurantId: restaurantA,
        branchId: centerBranch,
      );

      expect(lastRpcBody(httpClient)['p_branch_id'], centerBranch);

      await repository.getOrders(restaurantId: restaurantA, branchId: '   ');

      expect(
        lastRpcBody(httpClient).containsKey('p_branch_id'),
        isFalse,
        reason: 'a blank branch is no branch, not a branch that matches nothing',
      );
    });

    test('never sends a token, a user id or a status', () async {
      final httpClient = staffHttpClient(payload: buildStaffOrdersJson());
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getOrders(restaurantId: restaurantA);

      final body = httpClient.requestBodies
          .firstWhere((body) => body!.contains('p_restaurant_id'));
      expect(body, isNot(contains('access_token')));
      expect(body, isNot(contains(staffUserId)));
      expect(body, isNot(contains('status')));
    });

    test('clamps the limit to the range the database accepts', () async {
      final httpClient = staffHttpClient(payload: buildStaffOrdersJson());
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getOrders(restaurantId: restaurantA, limit: 0);
      expect(lastRpcBody(httpClient)['p_limit'], 1);

      await repository.getOrders(restaurantId: restaurantA, limit: -3);
      expect(lastRpcBody(httpClient)['p_limit'], 1);

      await repository.getOrders(restaurantId: restaurantA, limit: 100000);
      expect(lastRpcBody(httpClient)['p_limit'], StaffOrderRepository.maxLimit);
    });

    test('refuses an answer that belongs to another restaurant', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrdersJson(restaurantId: restaurantB),
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      expect(await repository.getOrders(restaurantId: restaurantA), isEmpty);
    });
  });

  group('StaffOrderRepository.getActiveOrders', () {
    test('makes no request when nobody is signed in', () async {
      final httpClient = staffHttpClient(payload: buildStaffOrdersJson());
      final repository = StaffOrderRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      expect(
        await repository.getActiveOrders(restaurantId: restaurantA),
        isEmpty,
      );
      expect(httpClient.requestBodies, isEmpty);
    });

    test('makes no request for a blank restaurant', () async {
      final httpClient = staffHttpClient(payload: buildStaffOrdersJson());
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      expect(await repository.getActiveOrders(restaurantId: '  '), isEmpty);
      expect(
        httpClient.requestBodies.where((body) => body!.contains('p_')),
        isEmpty,
      );
    });

    test('calls the active read, with the restaurant and a limit and nothing else',
        () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrdersJson(branchId: null),
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      final orders = await repository.getActiveOrders(restaurantId: restaurantA);

      expect(orders, hasLength(1));
      final rpc = httpClient.requests
          .firstWhere((request) => request.url.path.contains('/rpc/'));
      expect(
        rpc.url.path,
        contains('/rpc/${StaffOrderRepository.activeListFunctionName}'),
        reason: 'the live list reads the active orders, not the history window',
      );
      expect(
        lastRpcBody(httpClient).keys.toSet(),
        {'p_restaurant_id', 'p_limit'},
      );
      expect(lastRpcBody(httpClient)['p_restaurant_id'], restaurantA);
      expect(
        lastRpcBody(httpClient)['p_limit'],
        StaffOrderRepository.defaultActiveLimit,
      );
    });

    test('sends a branch when one is given, and omits a blank one', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrdersJson(branchId: centerBranch),
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getActiveOrders(
        restaurantId: restaurantA,
        branchId: centerBranch,
      );

      expect(lastRpcBody(httpClient)['p_branch_id'], centerBranch);

      await repository.getActiveOrders(
        restaurantId: restaurantA,
        branchId: '   ',
      );

      expect(
        lastRpcBody(httpClient).containsKey('p_branch_id'),
        isFalse,
        reason: 'a blank branch is no branch, not a branch that matches nothing',
      );
    });

    test('clamps the limit to the active read\'s own, larger range', () async {
      final httpClient = staffHttpClient(payload: buildStaffOrdersJson());
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getActiveOrders(restaurantId: restaurantA, limit: 0);
      expect(lastRpcBody(httpClient)['p_limit'], 1);

      await repository.getActiveOrders(restaurantId: restaurantA, limit: -3);
      expect(lastRpcBody(httpClient)['p_limit'], 1);

      await repository.getActiveOrders(restaurantId: restaurantA, limit: 100000);
      expect(
        lastRpcBody(httpClient)['p_limit'],
        StaffOrderRepository.maxActiveLimit,
      );
      expect(
        StaffOrderRepository.maxActiveLimit,
        greaterThan(StaffOrderRepository.maxLimit),
        reason: 'the active window is deliberately larger than the history window',
      );
    });

    test('refuses an answer that belongs to another restaurant', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrdersJson(restaurantId: restaurantB),
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      expect(
        await repository.getActiveOrders(restaurantId: restaurantA),
        isEmpty,
      );
    });
  });

  group('tryParseStaffOrderHistory', () {
    test('reads the orders, the more flag and the cursor the database sent', () {
      final page = tryParseStaffOrderHistory(
        encodeOrderRpcResult(
          buildStaffOrderHistoryJson(
            orders: [
              buildStaffOrderJson(orderNumber: 1045, status: 'SERVED'),
              buildStaffOrderJson(orderNumber: 1044, status: 'CANCELLED'),
            ],
            hasMore: true,
            nextCursor: buildStaffOrderHistoryCursor(orderNumber: 1044),
          ),
        ),
        restaurantId: restaurantA,
      );

      expect(page.orders.map((order) => order.orderNumber), [1045, 1044]);
      expect(page.orders.first.status, OrderStatus.served);
      expect(page.orders.last.status, OrderStatus.cancelled);
      expect(page.hasMore, isTrue);
      expect(page.nextCursor?.orderNumber, 1044);
      expect(page.nextCursor?.createdAt, DateTime.parse(orderCreatedAt));
    });

    test('accepts a payload delivered as a string', () {
      final page = tryParseStaffOrderHistory(
        jsonEncode(buildStaffOrderHistoryJson()),
        restaurantId: restaurantA,
      );

      expect(page.orders, hasLength(1));
    });

    test('claims no more when the server sent no cursor to read it with', () {
      final page = tryParseStaffOrderHistory(
        encodeOrderRpcResult(
          buildStaffOrderHistoryJson(hasMore: true, nextCursor: null),
        ),
        restaurantId: restaurantA,
      );

      expect(
        page.hasMore,
        isFalse,
        reason: 'a page that says more without a position would page forever',
      );
      expect(page.nextCursor, isNull);
    });

    test('treats an unreadable cursor as the end of the history', () {
      final page = tryParseStaffOrderHistory(
        encodeOrderRpcResult(
          buildStaffOrderHistoryJson(
            hasMore: true,
            nextCursor: {'created_at': 'not a time', 'order_number': 1},
          ),
        ),
        restaurantId: restaurantA,
      );

      expect(page.hasMore, isFalse);
      expect(page.nextCursor, isNull);
    });

    test('skips an order it cannot read and keeps the ones around it', () {
      final page = tryParseStaffOrderHistory(
        encodeOrderRpcResult(
          buildStaffOrderHistoryJson(
            orders: [
              buildStaffOrderJson(orderNumber: 1),
              buildStaffOrderJson(orderNumber: 2, status: 'REFUNDED'),
              buildStaffOrderJson(orderNumber: 3),
            ],
          ),
        ),
        restaurantId: restaurantA,
      );

      expect(page.orders.map((order) => order.orderNumber), [1, 3]);
    });

    test('refuses a payload that names another restaurant', () {
      final page = tryParseStaffOrderHistory(
        encodeOrderRpcResult(buildStaffOrderHistoryJson(restaurantId: restaurantB)),
        restaurantId: restaurantA,
      );

      expect(page.orders, isEmpty);
      expect(page.hasMore, isFalse);
      expect(page.nextCursor, isNull);
    });

    test('reads nothing from an answer it cannot understand', () {
      for (final response in <Object?>[
        null,
        '',
        '   ',
        'not json',
        jsonEncode('a string, not an object'),
        jsonEncode({'restaurant_id': restaurantA}),
        42,
      ]) {
        final page = tryParseStaffOrderHistory(
          response,
          restaurantId: restaurantA,
        );

        expect(page.orders, isEmpty, reason: 'nothing is read from $response');
        expect(page.hasMore, isFalse);
        expect(page.nextCursor, isNull);
      }
    });
  });

  group('StaffOrderRepository.getOrderHistory', () {
    test('makes no request when nobody is signed in', () async {
      final httpClient = staffHttpClient(payload: buildStaffOrderHistoryJson());
      final repository = StaffOrderRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      final page = await repository.getOrderHistory(restaurantId: restaurantA);

      expect(page.orders, isEmpty);
      expect(httpClient.requestBodies, isEmpty);
    });

    test('makes no request for a blank restaurant', () async {
      final httpClient = staffHttpClient(payload: buildStaffOrderHistoryJson());
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      final page = await repository.getOrderHistory(restaurantId: '  ');

      expect(page.orders, isEmpty);
      expect(
        httpClient.requestBodies.where((body) => body!.contains('p_')),
        isEmpty,
      );
    });

    test('calls the history read, with the restaurant and a limit and no cursor',
        () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrderHistoryJson(branchId: null),
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      final page = await repository.getOrderHistory(restaurantId: restaurantA);

      expect(page.orders, hasLength(1));
      final rpc = httpClient.requests
          .firstWhere((request) => request.url.path.contains('/rpc/'));
      expect(
        rpc.url.path,
        contains('/rpc/${StaffOrderRepository.historyListFunctionName}'),
        reason: 'the history reads the paginated whole-list read, not the live one',
      );
      expect(
        lastRpcBody(httpClient).keys.toSet(),
        {'p_restaurant_id', 'p_limit'},
        reason: 'a first page names no position',
      );
      expect(
        lastRpcBody(httpClient)['p_limit'],
        StaffOrderRepository.defaultHistoryLimit,
      );
    });

    test('sends a branch when one is given, and omits a blank one', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrderHistoryJson(branchId: centerBranch),
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getOrderHistory(
        restaurantId: restaurantA,
        branchId: centerBranch,
      );
      expect(lastRpcBody(httpClient)['p_branch_id'], centerBranch);

      await repository.getOrderHistory(restaurantId: restaurantA, branchId: '  ');
      expect(
        lastRpcBody(httpClient).containsKey('p_branch_id'),
        isFalse,
        reason: 'a blank branch is no branch, not a branch that matches nothing',
      );
    });

    test('sends the cursor as one key, and only when it has both halves',
        () async {
      final httpClient = staffHttpClient(payload: buildStaffOrderHistoryJson());
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getOrderHistory(
        restaurantId: restaurantA,
        cursor: StaffOrderHistoryCursor(
          createdAt: DateTime.parse(orderCreatedAt),
          orderNumber: 1043,
        ),
      );

      final body = lastRpcBody(httpClient);
      expect(body['p_before_created_at'], isNotNull);
      expect(body['p_before_order_number'], 1043);
    });

    test('clamps the limit to the history read\'s own range', () async {
      final httpClient = staffHttpClient(payload: buildStaffOrderHistoryJson());
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getOrderHistory(restaurantId: restaurantA, limit: 0);
      expect(lastRpcBody(httpClient)['p_limit'], 1);

      await repository.getOrderHistory(restaurantId: restaurantA, limit: -3);
      expect(lastRpcBody(httpClient)['p_limit'], 1);

      await repository.getOrderHistory(restaurantId: restaurantA, limit: 100000);
      expect(
        lastRpcBody(httpClient)['p_limit'],
        StaffOrderRepository.maxHistoryLimit,
      );
      expect(
        StaffOrderRepository.maxHistoryLimit,
        lessThan(StaffOrderRepository.maxActiveLimit),
        reason: 'a page of history is bounded more tightly than the live window',
      );
    });

    test('refuses an answer that belongs to another restaurant', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrderHistoryJson(restaurantId: restaurantB),
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      final page = await repository.getOrderHistory(restaurantId: restaurantA);

      expect(page.orders, isEmpty);
      expect(page.hasMore, isFalse);
    });
  });

  group('StaffOrderRepository.setOrderStatus', () {
    test('makes no request when nobody is signed in', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrderStatusUpdateJson(),
      );
      final repository = StaffOrderRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      final update = await repository.setOrderStatus(
        orderId: 'order-1',
        status: OrderStatus.accepted,
      );

      expect(update, isNull);
      expect(httpClient.requestBodies, isEmpty);
    });

    test('makes no request for a blank order id', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrderStatusUpdateJson(),
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      final update = await repository.setOrderStatus(
        orderId: '   ',
        status: OrderStatus.accepted,
      );

      expect(update, isNull);
      expect(httpClient.requestBodies.where((body) => body!.contains('p_')), isEmpty);
    });

    test('sends the order id and the stored status, and nothing else', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrderStatusUpdateJson(),
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.setOrderStatus(
        orderId: 'order-1',
        status: OrderStatus.preparing,
      );

      // No restaurant id: the database reads it from the order, so a screen has no
      // argument with which to name another restaurant's orders.
      expect(
        lastRpcBody(httpClient).keys.toSet(),
        {'p_order_id', 'p_new_status'},
      );
      expect(lastRpcBody(httpClient)['p_order_id'], 'order-1');
      expect(lastRpcBody(httpClient)['p_new_status'], 'PREPARING');
      expect(httpClient.requestBodies.last, isNot(contains(restaurantA)));
      expect(httpClient.requestBodies.last, isNot(contains(staffUserId)));
    });

    test('reports what the database stored', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffOrderStatusUpdateJson(status: 'SERVED'),
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      final update = await repository.setOrderStatus(
        orderId: 'order-1',
        status: OrderStatus.served,
      );

      expect(update, isNotNull);
      expect(update!.orderId, '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136');
      expect(update.status, OrderStatus.served);
      expect(update.updatedAt, DateTime.parse(orderUpdatedAt));
    });

    test('claims nothing when the answer is not a status change', () async {
      for (final payload in <Object?>[
        null,
        'not json',
        jsonEncode({'id': 'order-1'}),
        jsonEncode({'status': 'ACCEPTED'}),
        jsonEncode(buildStaffOrderStatusUpdateJson(status: 'REFUNDED')),
      ]) {
        final httpClient = staffHttpClient(payload: payload);
        final repository = StaffOrderRepository.withClient(
          await signedInStaffClient(httpClient),
        );

        expect(
          await repository.setOrderStatus(
            orderId: 'order-1',
            status: OrderStatus.accepted,
          ),
          isNull,
          reason: 'nothing is claimed from $payload',
        );
      }
    });

    test('lets a refusal through instead of hiding it', () async {
      final httpClient = staffHttpClient(
        payload: {
          'code': '42501',
          'message': 'staff_order_status_not_permitted',
          'details': null,
          'hint': null,
        },
        statusCode: 400,
      );
      final repository = StaffOrderRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await expectLater(
        repository.setOrderStatus(
          orderId: 'order-1',
          status: OrderStatus.ready,
        ),
        throwsA(
          isA<PostgrestException>().having(
            (error) => error.message,
            'message',
            'staff_order_status_not_permitted',
          ),
        ),
      );
    });
  });

  group('staff order error messages', () {
    test('an ended session is reported as a sign-in problem', () {
      for (final message in [
        staffOrderListErrorMessage(
          orderPostgrestError('28000', message: 'Authentication is required'),
        ),
        staffOrderStatusErrorMessage(
          orderPostgrestError('28000', message: 'Authentication is required'),
        ),
      ]) {
        expect(message, 'Your session has ended. Please sign in again.');
      }
    });

    test('a refused read is reported as a permission problem', () {
      final message = staffOrderListErrorMessage(
        orderPostgrestError('42501', message: 'staff_order_access_denied'),
      );

      expect(message, 'You do not have permission to view these orders.');
      expect(message, isNot(contains('staff_order')));
      expect(message, isNot(contains('denied')));
    });

    test('the two write refusals that share a code are told apart', () {
      expect(
        staffOrderStatusErrorMessage(
          orderPostgrestError('42501', message: 'staff_order_access_denied'),
        ),
        'You do not have permission to change this order.',
      );
      expect(
        staffOrderStatusErrorMessage(
          orderPostgrestError(
            '42501',
            message: 'staff_order_status_not_permitted',
          ),
        ),
        'Your role cannot make that status change.',
      );
    });

    test('a refused move is reported as the rule, not as a permission problem', () {
      expect(
        staffOrderStatusErrorMessage(
          orderPostgrestError(
            'P0001',
            message: 'invalid_order_status_transition',
          ),
        ),
        'This order cannot move to that status.',
      );
    });

    test('a status that does not exist is reported as its own problem', () {
      // The transition message begins with these words, so the shorter one has to be
      // checked second or an impossible move is reported as a status that is unknown.
      expect(
        staffOrderStatusErrorMessage(
          orderPostgrestError('P0001', message: 'invalid_order_status'),
        ),
        'That is not a status this order can be in.',
      );
      expect(
        staffOrderStatusErrorMessage(
          orderPostgrestError('P0001', message: 'invalid_order_status_transition'),
        ),
        isNot('That is not a status this order can be in.'),
      );
    });

    test('a malformed request is reported as something to correct', () {
      expect(
        staffOrderStatusErrorMessage(
          orderPostgrestError(
            '22023',
            message: 'An order id and a status are required.',
          ),
        ),
        'Choose an order and a status first.',
      );
    });

    test('anything else falls back to safe wording that echoes nothing', () {
      const leak = 'relation public.orders does not exist for staff_member';

      expect(
        staffOrderListErrorMessage(orderPostgrestError('42P01', message: leak)),
        'We could not load these orders. Please try again.',
      );
      expect(
        staffOrderStatusErrorMessage(orderPostgrestError('42P01', message: leak)),
        'We could not change this order. Please try again.',
      );
      expect(
        staffOrderStatusErrorMessage(StateError(leak)),
        'We could not change this order. Please try again.',
      );
      expect(
        staffOrderListErrorMessage(StateError(leak)),
        'We could not load these orders. Please try again.',
      );
    });
  });
}