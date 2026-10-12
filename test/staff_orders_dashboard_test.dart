import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_order_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/staff_order_details_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/staff_orders_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_order_actions.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_order_error_message.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/widgets/staff_order_status_chip.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/order_test_data.dart';
import 'support/staff_order_test_data.dart';

const String restaurantId = 'restaurant-1';
const String branchId = 'branch-1';

/// The credential a guest order can be read back with, which must never reach a
/// staff screen.
const String guestAccessToken = 'a1a1a1a1-1111-4111-8111-111111111111';

/// A `staff_list_orders` payload that also carries a guest's credential.
///
/// The database sends none, so this cannot happen today; it is built here because a
/// screen that renders whatever a payload contains has to be shown surviving one that
/// should not contain it.
Map<String, dynamic> _payloadWithGuestToken() {
  final payload = buildStaffOrdersJson(
    orders: [buildStaffOrderJson(id: 'order-1')],
  )..['access_token'] = guestAccessToken;

  ((payload['orders'] as List).first as Map<String, dynamic>)
    ..['access_token'] = guestAccessToken
    ..['order_access'] = [
      {'id': 'access-1', 'token_hash': 'e3b0c44298fc1c14'},
    ];

  return payload;
}

/// An order as a staff screen would hold one.
///
/// Only the fields a test cares about are named here, so a test can say what it is
/// about and nothing more.
StaffOrderModel buildOrder({
  String id = 'order-1',
  int orderNumber = 1043,
  OrderStatus status = OrderStatus.pending,
  String currency = 'KGS',
  int totalMinorUnits = 90000,
  int itemCount = 2,
  String? tableNumber = '12',
  String? tableName = 'Window',
  DateTime? createdAt,
  List<OrderLineModel>? lines,
}) {
  return StaffOrderModel(
    id: id,
    orderNumber: orderNumber,
    status: status,
    currency: currency,
    totalMinorUnits: totalMinorUnits,
    itemCount: itemCount,
    branchId: branchId,
    tableNumber: tableNumber,
    tableName: tableName,
    lines: lines ??
        const [
          OrderLineModel(
            productName: 'Beshbarmak',
            unitPriceMinorUnits: 45000,
            quantity: 2,
            lineTotalMinorUnits: 90000,
          ),
        ],
    createdAt: createdAt ?? DateTime.utc(2026, 10, 5, 14, 22),
    updatedAt: DateTime.utc(2026, 10, 5, 14, 25),
  );
}

/// Serves fixed orders and records what a screen asked for.
///
/// The repository is the whole of a screen's access to the database, so recording its
/// arguments is how a test proves a screen asked for orders and for nothing else. No
/// order id reaches a page any other way.
class _FakeStaffOrderRepository extends StaffOrderRepository {
  _FakeStaffOrderRepository({
    List<List<StaffOrderModel>>? responses,
    this.listError,
    this.statusError,
    List<StaffOrderHistoryPage>? historyResponses,
    this.historyError,
    this.historyMoreError,
  })  : responses = responses ?? <List<StaffOrderModel>>[const []],
        historyResponses =
            historyResponses ?? <StaffOrderHistoryPage>[const StaffOrderHistoryPage.empty()];

  /// One list per read, in order; the last one repeats for any read after it.
  List<List<StaffOrderModel>> responses;

  /// Thrown by [getOrders], standing in for a refused or failed read.
  Object? listError;

  /// Thrown by [setOrderStatus], standing in for a refused move.
  Object? statusError;

  /// One history page per read, in order; the last one repeats for any read after it.
  List<StaffOrderHistoryPage> historyResponses;

  /// Thrown by [getOrderHistory], standing in for a refused or failed page.
  Object? historyError;

  /// Thrown by [getOrderHistory] for a page asked for with a cursor, so a test can
  /// fail the load-more while the first page still reads.
  Object? historyMoreError;

  int listCalls = 0;
  int activeListCalls = 0;
  int historyCalls = 0;
  final List<({String? branchId, int limit})> listArguments = [];
  final List<({String orderId, OrderStatus status})> statusCalls = [];
  final List<StaffOrderHistoryCursor?> historyCursors = [];

  @override
  Future<List<StaffOrderModel>> getOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultLimit,
  }) async {
    listCalls++;
    listArguments.add((branchId: branchId, limit: limit));

    if (listError != null) {
      throw listError!;
    }

    final index = listCalls - 1;
    return index < responses.length ? responses[index] : responses.last;
  }

  @override
  Future<List<StaffOrderModel>> getActiveOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultActiveLimit,
  }) {
    activeListCalls++;
    return getOrders(restaurantId: restaurantId, branchId: branchId, limit: limit);
  }

  @override
  Future<StaffOrderHistoryPage> getOrderHistory({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultHistoryLimit,
    StaffOrderHistoryCursor? cursor,
  }) async {
    historyCalls++;
    historyCursors.add(cursor);

    if (historyError != null) {
      throw historyError!;
    }
    if (cursor != null && historyMoreError != null) {
      throw historyMoreError!;
    }

    final index = historyCalls - 1;
    return index < historyResponses.length
        ? historyResponses[index]
        : historyResponses.last;
  }

  @override
  Future<StaffOrderStatusUpdate?> setOrderStatus({
    required String orderId,
    required OrderStatus status,
  }) async {
    statusCalls.add((orderId: orderId, status: status));

    if (statusError != null) {
      throw statusError!;
    }

    return StaffOrderStatusUpdate(
      orderId: orderId,
      status: status,
      updatedAt: DateTime.utc(2026, 10, 5, 14, 30),
    );
  }
}

/// A read that has not answered yet, for the loading state.
///
/// A real network read is a future that has not completed; a fake that returns
/// immediately can never be observed mid-flight.
class _PendingStaffOrderRepository extends StaffOrderRepository {
  final Completer<List<StaffOrderModel>> _completer =
      Completer<List<StaffOrderModel>>();

  /// Completes the pending read with [orders].
  void answer(List<StaffOrderModel> orders) => _completer.complete(orders);

  @override
  Future<List<StaffOrderModel>> getOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultLimit,
  }) => _completer.future;

  @override
  Future<List<StaffOrderModel>> getActiveOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultActiveLimit,
  }) => _completer.future;
}

/// A repository whose status answer is unreadable, standing in for a response this
/// client cannot make sense of.
class _SilentStaffOrderRepository extends StaffOrderRepository {
  const _SilentStaffOrderRepository();

  @override
  Future<List<StaffOrderModel>> getOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultLimit,
  }) async => const [];

  @override
  Future<List<StaffOrderModel>> getActiveOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultActiveLimit,
  }) async => const [];

  @override
  Future<StaffOrderStatusUpdate?> setOrderStatus({
    required String orderId,
    required OrderStatus status,
  }) async => null;
}

/// A realtime channel that records its listeners and can replay events.
class _FakeRealtimeChannel extends RealtimeChannel {
  _FakeRealtimeChannel(this.channelName)
      : super(
          channelName,
          RealtimeClient('http://localhost:54321/realtime/v1'),
        );

  final String channelName;

  String get name => channelName;

  bool subscribed = false;

  void Function(RealtimeSubscribeStatus status, Object? error)? statusCallback;

  final List<
      ({PostgresChangeEvent event, void Function(PostgresChangePayload) callback})>
      listeners = [];

  @override
  RealtimeChannel onPostgresChanges({
    required PostgresChangeEvent event,
    String? schema,
    String? table,
    PostgresChangeFilter? filter,
    List<PostgresChangeFilter>? filters,
    List<String>? select,
    required void Function(PostgresChangePayload payload) callback,
  }) {
    listeners.add((event: event, callback: callback));
    return this;
  }

  @override
  RealtimeChannel subscribe([
    void Function(RealtimeSubscribeStatus status, Object? error)? callback,
    Duration? timeout,
  ]) {
    subscribed = true;
    statusCallback = callback;
    return this;
  }

  /// Fires the recorded subscribe callback, standing in for the realtime client
  /// reporting subscribe results and channel state that comes after.
  void changeStatus(RealtimeSubscribeStatus status, [Object? error]) {
    statusCallback?.call(status, error);
  }

  @override
  Future<String> unsubscribe([Duration? timeout]) async {
    subscribed = false;
    return channelName;
  }

  void triggerInsert(Map<String, dynamic> record) {
    final payload = PostgresChangePayload(
      eventType: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'order_change_events',
      newRecord: record,
      oldRecord: const {},
      commitTimestamp: DateTime.now(),
      errors: null,
    );
    for (final listener in listeners) {
      if (listener.event == PostgresChangeEvent.insert) {
        listener.callback(payload);
      }
    }
  }

  void triggerUpdate(Map<String, dynamic> record) {
    final payload = PostgresChangePayload(
      eventType: PostgresChangeEvent.update,
      schema: 'public',
      table: 'order_change_events',
      newRecord: record,
      oldRecord: record,
      commitTimestamp: DateTime.now(),
      errors: null,
    );
    for (final listener in listeners) {
      if (listener.event == PostgresChangeEvent.update) {
        listener.callback(payload);
      }
    }
  }
}

class _FakeSupabaseClient extends SupabaseClient {
  _FakeSupabaseClient()
      : super(
          'http://localhost:54321',
          'test-anon-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );

  final List<_FakeRealtimeChannel> channels = [];
  final List<String> removedChannels = [];

  @override
  RealtimeChannel channel(
    String channelName, {
    RealtimeChannelConfig opts = const RealtimeChannelConfig(),
  }) {
    final channel = _FakeRealtimeChannel(channelName);
    channels.add(channel);
    return channel;
  }

  @override
  Future<String> removeChannel(RealtimeChannel channel) async {
    if (channel is _FakeRealtimeChannel) {
      removedChannels.add(channel.channelName);
      await channel.unsubscribe();
    }
    return 'ok';
  }
}

/// A repository whose reads stay in flight until told to finish, so a test can
/// observe one refresh while another would have to wait.
class _ControlledStaffOrderRepository extends StaffOrderRepository {
  int listCalls = 0;
  final List<Completer<List<StaffOrderModel>>> _pending = [];

  @override
  Future<List<StaffOrderModel>> getOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultLimit,
  }) {
    listCalls++;
    final completer = Completer<List<StaffOrderModel>>();
    _pending.add(completer);
    return completer.future;
  }

  @override
  Future<List<StaffOrderModel>> getActiveOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultActiveLimit,
  }) => getOrders(restaurantId: restaurantId, branchId: branchId, limit: limit);

  void answerAll(List<StaffOrderModel> orders) {
    while (_pending.isNotEmpty) {
      _pending.removeAt(0).complete(orders);
    }
  }
}

/// Pumps the orders list on its own.
///
/// A widget test cannot sign a real session in: the test body runs in a fake-async
/// zone, and a real `SupabaseClient` needs a real one. The reads and the moves a real
/// client makes are asserted separately in the plain tests below.
Future<void> pumpOrdersPage(
  WidgetTester tester,
  StaffOrderRepository repository, {
  String role = 'OWNER',
  String? branchId,
  SupabaseClient? supabaseClient,
  bool enableRealtime = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StaffOrdersPage(
          restaurantId: restaurantId,
          role: role,
          branchId: branchId,
          repository: repository,
          supabaseClient: supabaseClient,
          enableRealtime: enableRealtime,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> pumpDetailsPage(
  WidgetTester tester,
  StaffOrderRepository repository, {
  StaffOrderModel? order,
  String role = 'OWNER',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StaffOrderDetailsPage(
          order: order ?? buildOrder(),
          role: role,
          repository: repository,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every string rendered anywhere in the tree, joined, for leak checks.
///
/// Walks the element tree rather than looking for the widget that built the text, so
/// a credential shown in a field, a tooltip or a snack bar would be caught too.
String renderedText(WidgetTester tester) {
  final buffer = StringBuffer();

  void visit(Element element) {
    final widget = element.widget;
    if (widget is Text) {
      buffer.write(widget.data);
      buffer.write(' ');
    }

    element.visitChildren(visit);
  }

  visit(tester.element(find.byType(Scaffold).first));
  return buffer.toString();
}

/// The statuses rendered as action buttons on a screen, in lifecycle order.
List<OrderStatus> offeredActions(WidgetTester tester) {
  return [
    for (final status in OrderStatus.values)
      if (find.byKey(staffOrderActionKey(status)).evaluate().isNotEmpty)
        status,
  ];
}

void main() {
  group('every order status the database can store is readable', () {
    const cases = {
      'PENDING': OrderStatus.pending,
      'ACCEPTED': OrderStatus.accepted,
      'PREPARING': OrderStatus.preparing,
      'READY': OrderStatus.ready,
      'SERVED': OrderStatus.served,
      'CANCELLED': OrderStatus.cancelled,
    };

    for (final entry in cases.entries) {
      test('${entry.key} parses and is shown as ${entry.value.displayLabel}', () {
        final orders = tryParseStaffOrders(
          buildStaffOrdersJson(orders: [buildStaffOrderJson(status: entry.key)]),
          restaurantId: restaurantA,
        );

        expect(orders, hasLength(1));
        expect(orders.single.status, entry.value);
        expect(orders.single.status.databaseValue, entry.key);
        expect(orders.single.status.displayLabel, isNotEmpty);
      });
    }

    test('the six statuses are the six the lifecycle has', () {
      expect(cases.values, hasLength(OrderStatus.values.length));
      expect(cases.values.toSet(), OrderStatus.values.toSet());
    });
  });

  group('staff order lists', () {
    test('several orders are parsed in the order the database sent them', () {
      final orders = tryParseStaffOrders(
        buildStaffOrdersJson(
          orders: [
            buildStaffOrderJson(id: 'order-3', orderNumber: 1045),
            buildStaffOrderJson(id: 'order-2', orderNumber: 1044),
            buildStaffOrderJson(id: 'order-1', orderNumber: 1043),
          ],
        ),
        restaurantId: restaurantA,
      );

      expect(orders.map((order) => order.orderNumber), [1045, 1044, 1043]);
      expect(orders.map((order) => order.id), [
        'order-3',
        'order-2',
        'order-1',
      ]);
    });

    test('an empty list from the database parses to no orders', () {
      final orders = tryParseStaffOrders(
        buildStaffOrdersJson(orders: const []),
        restaurantId: restaurantA,
      );

      expect(orders, isEmpty);
    });

    test('an order with no lines is skipped rather than half-read', () {
      final orders = tryParseStaffOrders(
        buildStaffOrdersJson(
          orders: [
            buildStaffOrderJson(id: 'order-1', items: const []),
            buildStaffOrderJson(id: 'order-2'),
          ],
        ),
        restaurantId: restaurantA,
      );

      expect(orders.map((order) => order.id), ['order-2']);
    });
  });

  group('the role matrix the UI offers', () {
    test('an owner may attempt every move the lifecycle has', () {
      expect(staffOrderTargetsForRole('OWNER'), OrderStatus.values.toSet());

      for (final status in OrderStatus.values) {
        expect(
          staffOrderActionsFor(role: 'OWNER', status: status),
          status.allowedNextStatuses.toList(),
          reason: 'OWNER should be offered every move out of $status',
        );
      }
    });

    test('a manager is treated as an owner', () {
      for (final status in OrderStatus.values) {
        expect(
          staffOrderActionsFor(role: 'MANAGER', status: status),
          staffOrderActionsFor(role: 'OWNER', status: status),
        );
      }
    });

    test('a waiter accepts, starts and serves, and may cancel', () {
      expect(
        staffOrderActionsFor(role: 'WAITER', status: OrderStatus.pending),
        [OrderStatus.accepted, OrderStatus.cancelled],
      );
      expect(
        staffOrderActionsFor(role: 'WAITER', status: OrderStatus.accepted),
        [OrderStatus.preparing, OrderStatus.cancelled],
      );
      expect(
        staffOrderActionsFor(role: 'WAITER', status: OrderStatus.preparing),
        [OrderStatus.cancelled],
        reason: 'finishing the food is a kitchen step, not a waiter step',
      );
      expect(
        staffOrderActionsFor(role: 'WAITER', status: OrderStatus.ready),
        [OrderStatus.served],
      );
    });

    test('a kitchen member starts and finishes, and may cancel', () {
      expect(
        staffOrderActionsFor(role: 'KITCHEN', status: OrderStatus.pending),
        [OrderStatus.cancelled],
      );
      expect(
        staffOrderActionsFor(role: 'KITCHEN', status: OrderStatus.accepted),
        [OrderStatus.preparing, OrderStatus.cancelled],
      );
      expect(
        staffOrderActionsFor(role: 'KITCHEN', status: OrderStatus.preparing),
        [OrderStatus.ready, OrderStatus.cancelled],
      );
      expect(
        staffOrderActionsFor(role: 'KITCHEN', status: OrderStatus.ready),
        isEmpty,
        reason: 'a kitchen member does not carry the order to the table',
      );
    });

    test('no role is offered a move out of a terminal status', () {
      for (final role in ['OWNER', 'MANAGER', 'WAITER', 'KITCHEN']) {
        for (final status in [OrderStatus.served, OrderStatus.cancelled]) {
          expect(
            staffOrderActionsFor(role: role, status: status),
            isEmpty,
            reason: '$status is terminal for everyone, $role included',
          );
        }
      }
    });

    test('a role with no order duties is offered nothing', () {
      for (final role in ['CASHIER', '', '  ', 'SUPERUSER']) {
        expect(staffOrderTargetsForRole(role), isEmpty);

        for (final status in OrderStatus.values) {
          expect(staffOrderActionsFor(role: role, status: status), isEmpty);
        }
      }

      expect(staffRoleWorksOrders('CASHIER'), isFalse);
      expect(staffRoleWorksOrders('WAITER'), isTrue);
    });

    test('a role is matched whatever case the membership row stored', () {
      expect(
        staffOrderActionsFor(role: 'waiter', status: OrderStatus.pending),
        staffOrderActionsFor(role: 'WAITER', status: OrderStatus.pending),
      );
      expect(
        staffOrderActionsFor(role: ' Owner ', status: OrderStatus.pending),
        staffOrderActionsFor(role: 'OWNER', status: OrderStatus.pending),
      );
    });

    test('every offered move is one the lifecycle has and can be named', () {
      for (final role in ['OWNER', 'MANAGER', 'WAITER', 'KITCHEN']) {
        for (final status in OrderStatus.values) {
          for (final action in staffOrderActionsFor(
            role: role,
            status: status,
          )) {
            expect(
              status.canTransitionTo(action),
              isTrue,
              reason: '$role may be offered $action from $status, and that has to '
                  'be a move the lifecycle allows',
            );
            expect(action.displayLabel, isNotEmpty);
            expect(staffOrderActionLabel(action), isNotEmpty);
          }
        }
      }
    });
  });

  group('StaffOrdersPage', () {
    testWidgets('loads orders through the repository', (tester) async {
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder(status: OrderStatus.accepted)],
        ],
      );

      await pumpOrdersPage(tester, repository, branchId: branchId);

      expect(
        repository.activeListCalls,
        1,
        reason: 'the live list reads the active orders, not the history window',
      );
      expect(repository.listCalls, 1);
      expect(repository.statusCalls, isEmpty);
      expect(repository.listArguments.single.branchId, branchId);
      expect(find.text('12 · Window'), findsOneWidget);
      expect(find.textContaining('Order #1043 · 2 items'), findsOneWidget);
      expect(find.text('Accepted'), findsOneWidget);
      expect(find.text('900.00 KGS'), findsOneWidget);
      expect(find.text('1 order'), findsOneWidget);
    });

    testWidgets('shows a loading state until the answer arrives', (
      tester,
    ) async {
      final repository = _PendingStaffOrderRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StaffOrdersPage(
              restaurantId: restaurantId,
              role: 'OWNER',
              repository: repository,
              enableRealtime: false,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Loading orders...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('No orders yet'), findsNothing);

      repository.answer([buildOrder()]);
      await tester.pumpAndSettle();

      expect(find.text('Loading orders...'), findsNothing);
      expect(find.byKey(const Key('staffOrdersList')), findsOneWidget);
    });

    testWidgets('shows an empty state when the restaurant has no orders', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository();

      await pumpOrdersPage(tester, repository);

      expect(find.byKey(const Key('staffOrdersEmptyState')), findsOneWidget);
      expect(find.text('No orders yet'), findsOneWidget);
      expect(find.byKey(const Key('staffOrdersList')), findsNothing);
    });

    testWidgets('shows a friendly error state and can retry', (tester) async {
      final repository = _FakeStaffOrderRepository(
        listError: orderPostgrestError(
          '42501',
          message: 'staff_order_access_denied',
        ),
      );

      await pumpOrdersPage(tester, repository);

      expect(
        find.text('You do not have permission to view these orders.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('staff_order_access_denied'),
        findsNothing,
        reason: "the database's own message is never shown",
      );

      repository.listError = null;
      repository.responses = [[buildOrder()]];

      await tester.tap(find.byKey(const Key('staffOrdersRetryButton')));
      await tester.pumpAndSettle();

      expect(repository.listCalls, 2);
      expect(find.byKey(const Key('staffOrdersList')), findsOneWidget);
    });

    testWidgets('an ended session is reported as a sign-in problem', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository(
        listError: orderPostgrestError(
          '28000',
          message: 'Authentication is required to read restaurant orders.',
        ),
      );

      await pumpOrdersPage(tester, repository);

      expect(
        find.text('Your session has ended. Please sign in again.'),
        findsOneWidget,
      );
    });

    testWidgets('pull to refresh re-reads the orders', (tester) async {
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder(id: 'order-1', orderNumber: 1043)],
          [
            buildOrder(
              id: 'order-2',
              orderNumber: 1044,
              tableNumber: '9',
              tableName: null,
            ),
          ],
        ],
      );

      await pumpOrdersPage(tester, repository);

      expect(find.text('12 · Window'), findsOneWidget);

      await tester.fling(
        find.byKey(const Key('staffOrdersList')),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();

      expect(repository.listCalls, 2);
      expect(find.text('12 · Window'), findsNothing);
      expect(find.text('9'), findsOneWidget);
    });

    testWidgets('opens the details of the order that was tapped', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder(id: 'order-1')],
        ],
      );

      await pumpOrdersPage(tester, repository);

      await tester.tap(find.byKey(const Key('staffOrderCard_order-1')));
      await tester.pumpAndSettle();

      expect(find.byType(StaffOrderDetailsPage), findsOneWidget);
      expect(find.text('Beshbarmak'), findsOneWidget);
    });

    testWidgets('re-reads the orders when the details page closes', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder(id: 'order-1')],
          [buildOrder(id: 'order-1', status: OrderStatus.accepted)],
        ],
      );

      await pumpOrdersPage(tester, repository);
      await tester.tap(find.byKey(const Key('staffOrderCard_order-1')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(repository.listCalls, 2);
      expect(find.text('Accepted'), findsOneWidget);
    });

    testWidgets('moves an order with the role\'s own actions', (tester) async {
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder(status: OrderStatus.pending)],
        ],
      );

      await pumpOrdersPage(tester, repository, role: 'WAITER');

      await tester.tap(find.byKey(staffOrderActionKey(OrderStatus.accepted)));
      await tester.pumpAndSettle();

      expect(repository.statusCalls, [
        (orderId: 'order-1', status: OrderStatus.accepted),
      ]);
      expect(find.text('Accepted'), findsOneWidget);
      expect(find.text('Pending'), findsNothing);
    });

    testWidgets('never offers a move the role cannot make', (tester) async {
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder(status: OrderStatus.pending)],
        ],
      );

      await pumpOrdersPage(tester, repository, role: 'KITCHEN');

      expect(
        offeredActions(tester),
        staffOrderActionsFor(role: 'KITCHEN', status: OrderStatus.pending),
      );
      expect(find.byKey(const Key('staffOrderAction_accepted')), findsNothing);
      expect(repository.statusCalls, isEmpty);
    });

    testWidgets('offers each role only its own moves on the list', (
      tester,
    ) async {
      const expectations = {
        'OWNER': [OrderStatus.accepted, OrderStatus.cancelled],
        'MANAGER': [OrderStatus.accepted, OrderStatus.cancelled],
        'WAITER': [OrderStatus.accepted, OrderStatus.cancelled],
        'KITCHEN': [OrderStatus.cancelled],
        'CASHIER': <OrderStatus>[],
      };

      for (final entry in expectations.entries) {
        final repository = _FakeStaffOrderRepository(
          responses: [
            [buildOrder(status: OrderStatus.pending)],
          ],
        );

        await pumpOrdersPage(tester, repository, role: entry.key);

        expect(
          offeredActions(tester),
          entry.value,
          reason: '${entry.key} must be offered exactly these moves out of PENDING',
        );
      }
    });

    testWidgets('a refused move shows the reason and re-reads the order', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder(status: OrderStatus.pending)],
          [buildOrder(status: OrderStatus.accepted)],
        ],
        statusError: orderPostgrestError(
          '42501',
          message: 'staff_order_status_not_permitted',
        ),
      );

      await pumpOrdersPage(tester, repository);

      await tester.tap(find.byKey(staffOrderActionKey(OrderStatus.accepted)));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Your role cannot make that status change.'),
        findsOneWidget,
      );

      await tester.pumpAndSettle();

      // The list is re-read after a refusal: the database, not this screen, decides
      // where the order is.
      expect(repository.listCalls, 2);
      expect(find.text('Accepted'), findsOneWidget);
    });

    testWidgets('a lifecycle refusal is reported as the rule, not permissions', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository(
        responses: [[buildOrder(status: OrderStatus.pending)]],
        statusError: orderPostgrestError(
          'P0001',
          message: 'invalid_order_status_transition',
        ),
      );

      await pumpOrdersPage(tester, repository);

      await tester.tap(find.byKey(staffOrderActionKey(OrderStatus.accepted)));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('This order cannot move to that status.'),
        findsOneWidget,
      );
    });

    testWidgets('a payload carrying a guest token shows nothing of it', (
      tester,
    ) async {
      // Parsed with the real parser, so a payload with a credential in it goes through
      // the same code the app runs rather than through a hand-built model.
      final orders = tryParseStaffOrders(
        jsonDecode(encodeOrderRpcResult(_payloadWithGuestToken())),
        restaurantId: restaurantA,
      );

      final repository = _FakeStaffOrderRepository(responses: [orders]);

      await pumpOrdersPage(tester, repository);

      // The order still reads, because a payload carrying a guest credential is a
      // database bug to report, not a reason to lose a live order over.
      expect(find.text('12 · Window'), findsOneWidget);
      expect(renderedText(tester), isNot(contains(guestAccessToken)));
      expect(find.textContaining(guestAccessToken), findsNothing);

      await tester.tap(find.byKey(const Key('staffOrderCard_order-1')));
      await tester.pumpAndSettle();

      expect(find.byType(StaffOrderDetailsPage), findsOneWidget);
      expect(renderedText(tester), isNot(contains(guestAccessToken)));
      expect(find.textContaining(guestAccessToken), findsNothing);
    });

    for (final status in OrderStatus.values) {
      testWidgets('a ${status.databaseValue} order shows its status as a word', (
        tester,
      ) async {
        final repository = _FakeStaffOrderRepository(
          responses: [
            [buildOrder(id: 'order-1', status: status)],
          ],
        );

        await pumpOrdersPage(tester, repository);

        expect(find.text(status.displayLabel), findsOneWidget);
        expect(find.byType(StaffOrderStatusChip), findsOneWidget);
        expect(find.byIcon(staffOrderStatusIcon(status)), findsOneWidget);
      });
    }
  });

  group('StaffOrdersPage history view', () {
    StaffOrderHistoryPage historyPage(
      List<StaffOrderModel> orders, {
      bool hasMore = false,
      StaffOrderHistoryCursor? nextCursor,
    }) {
      return StaffOrderHistoryPage(
        orders: orders,
        hasMore: hasMore,
        nextCursor: nextCursor,
      );
    }

    final cursor = StaffOrderHistoryCursor(
      createdAt: DateTime.utc(2026, 10, 5, 14, 22),
      orderNumber: 1043,
    );

    testWidgets('opens on the live list and reads no history', (tester) async {
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder(id: 'active-1')],
        ],
      );

      await pumpOrdersPage(tester, repository);

      expect(find.byKey(const Key('staffOrdersViewSelector')), findsOneWidget);
      expect(repository.activeListCalls, 1);
      expect(
        repository.historyCalls,
        0,
        reason: 'the history is not read until it is asked for',
      );
      expect(find.byKey(const Key('staffOrderCard_active-1')), findsOneWidget);
    });

    testWidgets('the History view reads the first page and shows every status', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder(id: 'active-1')],
        ],
        historyResponses: [
          historyPage([
            buildOrder(id: 'hist-1', orderNumber: 1045, status: OrderStatus.served),
            buildOrder(
              id: 'hist-2',
              orderNumber: 1044,
              status: OrderStatus.cancelled,
            ),
          ]),
        ],
      );

      await pumpOrdersPage(tester, repository);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      expect(repository.historyCalls, 1);
      expect(repository.historyCursors, [null]);
      expect(find.text('Order history'), findsOneWidget);
      expect(find.byKey(const Key('staffOrdersHistoryList')), findsOneWidget);
      expect(find.text('Served'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
      expect(
        find.byKey(const Key('staffOrderCard_active-1')),
        findsNothing,
        reason: 'the live list is not shown beside the history',
      );
      expect(find.text('2 orders'), findsOneWidget);
    });

    testWidgets('moving back to Active keeps both lists and re-reads neither', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder(id: 'active-1')],
        ],
        historyResponses: [
          historyPage([
            buildOrder(id: 'hist-1', status: OrderStatus.served),
          ]),
        ],
      );

      await pumpOrdersPage(tester, repository);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Active'));
      await tester.pumpAndSettle();

      expect(repository.historyCalls, 1);
      expect(repository.activeListCalls, 1);
      expect(find.byKey(const Key('staffOrderCard_active-1')), findsOneWidget);
    });

    testWidgets('Load more reads the next page from the database cursor', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository(
        historyResponses: [
          historyPage(
            [
              buildOrder(id: 'hist-1', orderNumber: 1043, status: OrderStatus.served),
            ],
            hasMore: true,
            nextCursor: cursor,
          ),
          historyPage([
            buildOrder(id: 'hist-2', orderNumber: 1042, status: OrderStatus.cancelled),
          ]),
        ],
      );

      await pumpOrdersPage(tester, repository);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      expect(find.text('1+ loaded'), findsOneWidget);
      expect(
        find.byKey(const Key('staffOrdersHistoryLoadMoreButton')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('staffOrdersHistoryLoadMoreButton')));
      await tester.pumpAndSettle();

      expect(repository.historyCalls, 2);
      expect(repository.historyCursors, [null, cursor]);
      expect(find.byKey(const Key('staffOrderCard_hist-2')), findsOneWidget);
      expect(find.text('2 orders'), findsOneWidget);
    });

    testWidgets('a failed first page is reported and can be retried', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository(
        historyError: orderPostgrestError(
          '42501',
          message: 'staff_order_access_denied',
        ),
      );

      await pumpOrdersPage(tester, repository);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      expect(
        find.text('You do not have permission to view these orders.'),
        findsOneWidget,
      );

      repository.historyError = null;
      repository.historyResponses = [
        historyPage([
          buildOrder(id: 'hist-1', status: OrderStatus.served),
        ]),
      ];

      await tester.tap(find.byKey(const Key('staffOrdersRetryButton')));
      await tester.pumpAndSettle();

      expect(repository.historyCalls, 2);
      expect(find.byKey(const Key('staffOrdersHistoryList')), findsOneWidget);
    });

    testWidgets('a failed Load more keeps the page and offers a retry', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository(
        historyResponses: [
          historyPage(
            [
              buildOrder(id: 'hist-1', orderNumber: 1043, status: OrderStatus.served),
            ],
            hasMore: true,
            nextCursor: cursor,
          ),
        ],
        historyMoreError: orderPostgrestError(
          '57P01',
          message: 'terminating connection',
        ),
      );

      await pumpOrdersPage(tester, repository);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('staffOrdersHistoryLoadMoreButton')));
      await tester.pumpAndSettle();

      expect(
        find.text('We could not load these orders. Please try again.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('staffOrdersHistoryLoadMoreRetryButton')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('staffOrderCard_hist-1')),
        findsOneWidget,
        reason: 'a failed next page never blanks the page already read',
      );
    });

    testWidgets('a realtime event refreshes the live list, never the history', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder(id: 'active-1')],
        ],
        historyResponses: [
          historyPage([
            buildOrder(id: 'hist-1', status: OrderStatus.served),
          ]),
        ],
      );

      await pumpOrdersPage(
        tester,
        repository,
        branchId: branchId,
        supabaseClient: client,
        enableRealtime: true,
      );
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      expect(repository.historyCalls, 1);

      client.channels.single.triggerInsert({'branch_id': branchId});
      await tester.pumpAndSettle();

      expect(
        repository.historyCalls,
        1,
        reason: 'history is refreshed by pulling down, not by realtime',
      );
      expect(
        repository.activeListCalls,
        2,
        reason: 'the live list keeps its own subscription whether or not it is shown',
      );
    });

    testWidgets('opening a history order re-reads the history on return', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository(
        historyResponses: [
          historyPage([
            buildOrder(id: 'hist-1', status: OrderStatus.served),
          ]),
        ],
      );

      await pumpOrdersPage(tester, repository);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('staffOrderCard_hist-1')));
      await tester.pumpAndSettle();
      expect(find.byType(StaffOrderDetailsPage), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(repository.historyCalls, 2);
      expect(find.byKey(const Key('staffOrdersHistoryList')), findsOneWidget);
    });

    testWidgets('a status change made on the history updates it in place', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository(
        historyResponses: [
          historyPage([
            buildOrder(id: 'hist-1', status: OrderStatus.pending),
          ]),
        ],
      );

      await pumpOrdersPage(tester, repository);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(staffOrderActionKey(OrderStatus.accepted)));
      await tester.pumpAndSettle();

      expect(repository.statusCalls, [
        (orderId: 'hist-1', status: OrderStatus.accepted),
      ]);
      expect(find.text('Accepted'), findsOneWidget);
      expect(
        repository.historyCalls,
        1,
        reason: 'a confirmed move is applied from the answer, with no extra read',
      );
    });
  });

  group('StaffOrderDetailsPage', () {
    testWidgets('shows the order, its items, quantities and total', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository();

      await pumpDetailsPage(
        tester,
        repository,
        order: buildOrder(
          lines: const [
            OrderLineModel(
              productName: 'Beshbarmak',
              unitPriceMinorUnits: 45000,
              quantity: 2,
              lineTotalMinorUnits: 90000,
            ),
            OrderLineModel(
              productName: 'Kompot',
              unitPriceMinorUnits: 8000,
              quantity: 1,
              lineTotalMinorUnits: 8000,
            ),
          ],
          itemCount: 3,
          totalMinorUnits: 98000,
        ),
      );

      expect(find.text('Order #1043'), findsOneWidget);
      expect(find.text('12 · Window'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('2×'), findsOneWidget);
      expect(find.text('Beshbarmak'), findsOneWidget);
      expect(find.text('450.00 KGS each'), findsOneWidget);
      expect(find.text('900.00 KGS'), findsOneWidget);
      expect(find.text('Kompot'), findsOneWidget);
      expect(find.text('980.00 KGS'), findsOneWidget);
      expect(find.text('Placed'), findsOneWidget);
    });

    testWidgets('shows when the order was placed', (tester) async {
      final repository = _FakeStaffOrderRepository();

      await pumpDetailsPage(tester, repository);

      expect(
        find.text(formatOrderPlacedAt(DateTime.utc(2026, 10, 5, 14, 22))),
        findsOneWidget,
      );
    });

    testWidgets('an order with no table says so rather than showing nothing', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository();

      await pumpDetailsPage(
        tester,
        repository,
        order: buildOrder(tableNumber: null, tableName: null),
      );

      expect(find.text('No table'), findsOneWidget);
    });

    testWidgets('offers only the role\'s own moves', (tester) async {
      final repository = _FakeStaffOrderRepository();

      await pumpDetailsPage(
        tester,
        repository,
        role: 'KITCHEN',
        order: buildOrder(status: OrderStatus.accepted),
      );

      expect(
        offeredActions(tester),
        [OrderStatus.preparing, OrderStatus.cancelled],
        reason: 'a kitchen member starts the food and may cancel, nothing else',
      );
      expect(find.byKey(const Key('staffOrderAction_served')), findsNothing);
    });

    testWidgets('offers no arbitrary status choice at all', (tester) async {
      final repository = _FakeStaffOrderRepository();

      await pumpDetailsPage(
        tester,
        repository,
        role: 'OWNER',
        order: buildOrder(status: OrderStatus.pending),
      );

      // Every status is a named button on a lifecycle move; there is no dropdown, no
      // free text and no picker that could send a status this order does not allow.
      expect(find.byType(DropdownButton<Object?>), findsNothing);
      expect(find.byType(DropdownMenu<Object?>), findsNothing);
      expect(offeredActions(tester), [
        OrderStatus.accepted,
        OrderStatus.cancelled,
      ]);
      expect(find.text('Accept order'), findsOneWidget);
      expect(find.text('Cancel order'), findsOneWidget);
    });

    testWidgets('a finished order offers nothing', (tester) async {
      for (final status in [OrderStatus.served, OrderStatus.cancelled]) {
        final repository = _FakeStaffOrderRepository();

        await pumpDetailsPage(tester, repository, order: buildOrder(status: status));

        expect(find.byKey(const Key('staffOrderNoActions')), findsOneWidget);
        expect(offeredActions(tester), isEmpty);
        expect(repository.statusCalls, isEmpty);
      }
    });

    testWidgets('a move updates the order from the database answer', (
      tester,
    ) async {
      final repository = _FakeStaffOrderRepository();

      await pumpDetailsPage(
        tester,
        repository,
        order: buildOrder(status: OrderStatus.pending),
      );

      await tester.tap(find.byKey(staffOrderActionKey(OrderStatus.accepted)));
      await tester.pumpAndSettle();

      expect(repository.statusCalls, [
        (orderId: 'order-1', status: OrderStatus.accepted),
      ]);
      expect(find.text('Accepted'), findsOneWidget);
      expect(find.text('Pending'), findsNothing);
      expect(
        find.textContaining('is now accepted'),
        findsOneWidget,
        reason: 'the move is confirmed in the wording the database returned',
      );
    });

    testWidgets('a refused move changes nothing on screen', (tester) async {
      final repository = _FakeStaffOrderRepository(
        statusError: orderPostgrestError(
          '42501',
          message: 'staff_order_access_denied',
        ),
      );

      await pumpDetailsPage(
        tester,
        repository,
        order: buildOrder(status: OrderStatus.pending),
      );

      await tester.tap(find.byKey(staffOrderActionKey(OrderStatus.accepted)));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('You do not have permission to change this order.'),
        findsOneWidget,
      );
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Accepted'), findsNothing);
    });

    testWidgets('a malformed answer claims no move was made', (tester) async {
      const repository = _SilentStaffOrderRepository();

      await pumpDetailsPage(
        tester,
        repository,
        order: buildOrder(status: OrderStatus.pending),
      );

      await tester.tap(find.byKey(staffOrderActionKey(OrderStatus.accepted)));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('could not confirm'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
    });
  });

  group('the staff screens reach the database only through the staff rpcs', () {
    test('reading orders goes through staff_list_orders, not a table', () async {
      final httpClient = staffHttpClient(
        payload: encodeOrderRpcResult(buildStaffOrdersJson()),
      );
      final client = await signedInStaffClient(httpClient);
      addTearDown(client.dispose);

      final orders = await StaffOrderRepository.withClient(client).getOrders(
        restaurantId: restaurantA,
        branchId: centerBranch,
      );

      expect(orders, hasLength(1));
      expect(lastRpcBody(httpClient), {
        'p_restaurant_id': restaurantA,
        'p_branch_id': centerBranch,
        'p_limit': StaffOrderRepository.defaultLimit,
      });

      final paths = httpClient.requests.map((request) => request.url.path);
      expect(
        paths.where((path) => path.contains('/rest/v1/rpc/')),
        [contains('/rpc/staff_list_orders')],
      );
      expect(
        paths.where((path) => path.contains('/rest/v1/orders')),
        isEmpty,
        reason: 'the orders tables carry no grant for a client role, so a screen '
            'that queried one would simply be refused',
      );
    });

    test('the live lists read staff_list_active_orders, not a table', () async {
      final httpClient = staffHttpClient(
        payload: encodeOrderRpcResult(buildStaffOrdersJson()),
      );
      final client = await signedInStaffClient(httpClient);
      addTearDown(client.dispose);

      final orders = await StaffOrderRepository.withClient(client).getActiveOrders(
        restaurantId: restaurantA,
        branchId: centerBranch,
      );

      expect(orders, hasLength(1));
      expect(lastRpcBody(httpClient), {
        'p_restaurant_id': restaurantA,
        'p_branch_id': centerBranch,
        'p_limit': StaffOrderRepository.defaultActiveLimit,
      });

      final paths = httpClient.requests.map((request) => request.url.path);
      expect(
        paths.where((path) => path.contains('/rest/v1/rpc/')),
        [contains('/rpc/staff_list_active_orders')],
      );
      expect(paths.where((path) => path.contains('/rest/v1/orders')), isEmpty);
    });

    test('moving an order goes through staff_set_order_status', () async {
      final httpClient = staffHttpClient(
        payload: encodeOrderRpcResult(
          buildStaffOrderStatusUpdateJson(id: 'order-1'),
        ),
      );
      final client = await signedInStaffClient(httpClient);
      addTearDown(client.dispose);

      final update = await StaffOrderRepository.withClient(client)
          .setOrderStatus(orderId: 'order-1', status: OrderStatus.accepted);

      expect(update?.status, OrderStatus.accepted);
      expect(lastRpcBody(httpClient), {
        'p_order_id': 'order-1',
        'p_new_status': 'ACCEPTED',
      });

      final paths = httpClient.requests.map((request) => request.url.path);
      expect(
        paths.where((path) => path.contains('/rest/v1/rpc/')),
        [contains('/rpc/staff_set_order_status')],
      );
      expect(paths.where((path) => path.contains('/rest/v1/orders')), isEmpty);
    });

    test('a read this client cannot read claims nothing rather than throwing',
        () async {
      final httpClient = staffHttpClient(payload: 'not json at all');
      final client = await signedInStaffClient(httpClient);
      addTearDown(client.dispose);

      final orders = await StaffOrderRepository.withClient(client)
          .getOrders(restaurantId: restaurantA);

      expect(orders, isEmpty);
    });
  });

  group('staff error wording on the orders screens', () {
    test('a refused read is reported as a permission problem', () {
      final message = staffOrderListErrorMessage(
        orderPostgrestError(
          '42501',
          message: 'relation "public.orders" does not exist',
        ),
      );

      expect(message, 'You do not have permission to view these orders.');
      expect(message, isNot(contains('public.orders')));
    });

    test('any other failed read falls back to safe wording', () {
      final message = staffOrderListErrorMessage(
        orderPostgrestError('57P01', message: 'terminating connection'),
      );

      expect(message, 'We could not load these orders. Please try again.');
    });

    test('a failed write never echoes what the database said', () {
      final message = staffOrderStatusErrorMessage(
        orderPostgrestError(
          'P0001',
          message: 'invalid_order_status_transition from PENDING to SERVED',
        ),
      );

      expect(message, 'This order cannot move to that status.');
      expect(message, isNot(contains('PENDING')));
    });
  });

  group('StaffOrdersPage realtime', () {
    const channelName = 'orders:order_change_events:restaurant-1';

    testWidgets('subscribes to the restaurant-scoped channel for insert and update', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeStaffOrderRepository();

      await pumpOrdersPage(
        tester,
        repository,
        supabaseClient: client,
        enableRealtime: true,
      );

      expect(client.channels, hasLength(1));
      expect(client.channels.single.channelName, channelName);
      expect(client.channels.single.subscribed, isTrue);
      expect(
        client.channels.single.listeners.map((listener) => listener.event),
        containsAll([PostgresChangeEvent.insert, PostgresChangeEvent.update]),
      );
    });

    testWidgets('an INSERT for this branch refreshes the orders', (tester) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeStaffOrderRepository(
        responses: [
          const <StaffOrderModel>[],
          [buildOrder()],
        ],
      );

      await pumpOrdersPage(
        tester,
        repository,
        supabaseClient: client,
        enableRealtime: true,
      );

      expect(repository.listCalls, 1);
      expect(find.byKey(const Key('staffOrdersEmptyState')), findsOneWidget);

      client.channels.single.triggerInsert({'branch_id': branchId});
      await tester.pumpAndSettle();

      expect(repository.listCalls, 2);
      expect(find.byKey(const Key('staffOrderCard_order-1')), findsOneWidget);
      expect(find.byKey(const Key('staffOrdersEmptyState')), findsNothing);
    });

    testWidgets('an UPDATE for this branch refreshes the orders', (tester) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder(status: OrderStatus.preparing, itemCount: 2)],
          [buildOrder(status: OrderStatus.preparing, itemCount: 3)],
        ],
      );

      await pumpOrdersPage(
        tester,
        repository,
        supabaseClient: client,
        enableRealtime: true,
      );

      expect(repository.listCalls, 1);
      expect(find.textContaining('· 2 items'), findsOneWidget);

      client.channels.single.triggerUpdate({'branch_id': branchId});
      await tester.pumpAndSettle();

      expect(repository.listCalls, 2);
      expect(find.textContaining('· 3 items'), findsOneWidget);
    });

    testWidgets('an event for another branch is ignored', (tester) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder()],
        ],
      );

      await pumpOrdersPage(
        tester,
        repository,
        branchId: branchId,
        supabaseClient: client,
        enableRealtime: true,
      );

      expect(repository.listCalls, 1);

      client.channels.single.triggerInsert({'branch_id': 'branch-2'});
      client.channels.single.triggerUpdate({'branch_id': 'branch-2'});
      await tester.pumpAndSettle();

      expect(
        repository.listCalls,
        1,
        reason: 'an event for another branch is not this list\'s feed',
      );
      expect(find.byKey(const Key('staffOrderCard_order-1')), findsOneWidget);
    });

    testWidgets('an event without a branch is ignored when one branch is scoped', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder()],
        ],
      );

      await pumpOrdersPage(
        tester,
        repository,
        branchId: branchId,
        supabaseClient: client,
        enableRealtime: true,
      );

      client.channels.single.triggerInsert(<String, dynamic>{});
      await tester.pumpAndSettle();

      expect(repository.listCalls, 1);
    });

    testWidgets('a burst of realtime events becomes one follow-up read', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _ControlledStaffOrderRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StaffOrdersPage(
              restaurantId: restaurantId,
              role: 'OWNER',
              branchId: branchId,
              repository: repository,
              supabaseClient: client,
              enableRealtime: true,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(repository.listCalls, 1);
      repository.answerAll([buildOrder()]);
      await tester.pumpAndSettle();

      client.channels.single.triggerInsert({'branch_id': branchId});
      await tester.pump();
      expect(repository.listCalls, 2);

      client.channels.single.triggerInsert({'branch_id': branchId});
      client.channels.single.triggerUpdate({'branch_id': branchId});
      await tester.pump();
      expect(
        repository.listCalls,
        2,
        reason: 'events that arrive during a read are folded into the next one, '
            'never read one at a time',
      );

      repository.answerAll([buildOrder()]);
      await tester.pumpAndSettle();
      expect(
        repository.listCalls,
        3,
        reason: 'the whole burst is served by exactly one follow-up read',
      );
    });

    testWidgets('a pull during a realtime refresh waits for that read cycle', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _ControlledStaffOrderRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StaffOrdersPage(
              restaurantId: restaurantId,
              role: 'OWNER',
              branchId: branchId,
              repository: repository,
              supabaseClient: client,
              enableRealtime: true,
            ),
          ),
        ),
      );
      await tester.pump();
      repository.answerAll([buildOrder()]);
      await tester.pumpAndSettle();

      client.channels.single.triggerInsert({'branch_id': branchId});
      await tester.pump();
      expect(repository.listCalls, 2);

      // A pull that lands while a realtime read runs joins that cycle instead of
      // opening a second read. The indicator needs a few frames to reach the point
      // where it calls onRefresh; across all of them the read count must not move.
      final refresh = tester.state<RefreshIndicatorState>(
        find.byType(RefreshIndicator),
      );
      final pulled = refresh.show();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          repository.listCalls,
          2,
          reason: 'the pull joins the read already running, it never races it',
        );
      }

      // The realtime read finishes and one follow-up read serves the pull.
      repository.answerAll([buildOrder()]);
      await tester.pump();
      expect(
        repository.listCalls,
        3,
        reason: 'one follow-up read serves the pull that joined the cycle',
      );

      repository.answerAll([buildOrder()]);
      await tester.pumpAndSettle();
      // The pull's future completes only once its queued read cycle has finished.
      await pulled;
    });

    testWidgets('a lost channel is announced, and a reconnect clears it', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder()],
        ],
      );

      await pumpOrdersPage(
        tester,
        repository,
        supabaseClient: client,
        enableRealtime: true,
      );

      final channel = client.channels.single;
      expect(find.byKey(const Key('staffOrdersRealtimeNotice')), findsNothing);

      channel.changeStatus(RealtimeSubscribeStatus.channelError, 'boom');
      await tester.pump();

      expect(find.byKey(const Key('staffOrdersRealtimeNotice')), findsOneWidget);
      expect(
        find.textContaining('Live order updates are unavailable'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('staffOrdersList')), findsOneWidget);

      channel.changeStatus(RealtimeSubscribeStatus.subscribed);
      await tester.pump();

      expect(find.byKey(const Key('staffOrdersRealtimeNotice')), findsNothing);
      expect(repository.listCalls, 1);
    });

    testWidgets('a timeout and a closed channel also show the notice', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder()],
        ],
      );

      await pumpOrdersPage(
        tester,
        repository,
        supabaseClient: client,
        enableRealtime: true,
      );

      final channel = client.channels.single;
      for (final status in [
        RealtimeSubscribeStatus.channelError,
        RealtimeSubscribeStatus.timedOut,
        RealtimeSubscribeStatus.closed,
      ]) {
        channel.changeStatus(status);
        await tester.pump();
        expect(find.byKey(const Key('staffOrdersRealtimeNotice')), findsOneWidget);
      }
    });

    testWidgets('disposal during a realtime refresh leaves nothing pending', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _ControlledStaffOrderRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StaffOrdersPage(
              restaurantId: restaurantId,
              role: 'OWNER',
              branchId: branchId,
              repository: repository,
              supabaseClient: client,
              enableRealtime: true,
            ),
          ),
        ),
      );
      await tester.pump();
      repository.answerAll([buildOrder()]);
      await tester.pumpAndSettle();

      client.channels.single.triggerInsert({'branch_id': branchId});
      await tester.pump();
      expect(repository.listCalls, 2);

      final channel = client.channels.single;
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();

      expect(client.removedChannels, [channelName]);
      expect(channel.subscribed, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed refresh does not stop later refreshes', (tester) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder()],
          [buildOrder()],
        ],
      );

      await pumpOrdersPage(
        tester,
        repository,
        supabaseClient: client,
        enableRealtime: true,
      );

      expect(repository.listCalls, 1);

      repository.listError = orderPostgrestError(
        '42501',
        message: 'staff_order_access_denied',
      );
      client.channels.single.triggerInsert({'branch_id': branchId});
      await tester.pumpAndSettle();

      // The failed burst reported the error and freed the read slot rather than
      // wedging the queue.
      expect(
        find.text('You do not have permission to view these orders.'),
        findsOneWidget,
      );

      repository.listError = null;
      repository.responses = [
        [buildOrder(status: OrderStatus.accepted)],
      ];

      await tester.tap(find.byKey(const Key('staffOrdersRetryButton')));
      await tester.pumpAndSettle();

      expect(repository.listCalls, 3);
      expect(find.text('Accepted'), findsOneWidget);
    });

    testWidgets('realtime disabled makes no channel and keeps the read working', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder()],
        ],
      );

      await pumpOrdersPage(
        tester,
        repository,
        supabaseClient: client,
        enableRealtime: false,
      );

      expect(repository.listCalls, 1);
      expect(client.channels, isEmpty);
      expect(client.removedChannels, isEmpty);
      expect(find.byKey(const Key('staffOrderCard_order-1')), findsOneWidget);
    });

    testWidgets('the channel is removed when the page is disposed', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeStaffOrderRepository(
        responses: [
          [buildOrder()],
        ],
      );

      await pumpOrdersPage(
        tester,
        repository,
        supabaseClient: client,
        enableRealtime: true,
      );

      final channel = client.channels.single;
      expect(client.removedChannels, isEmpty);
      expect(channel.subscribed, isTrue);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();

      expect(client.removedChannels, [channelName]);
      expect(channel.subscribed, isFalse);
    });
  });
}