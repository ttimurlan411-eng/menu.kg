import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/customer/orders/data/models/order_model.dart';
import 'package:menukg_flutter/features/kitchen/presentation/pages/kitchen_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_order_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_order_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/order_test_data.dart';
import 'support/staff_order_test_data.dart';

const String restaurantId = 'restaurant-1';
const String branchId = 'branch-1';

/// The credential a guest order can be read back with, which must never reach a
/// kitchen screen.
const String guestAccessToken = 'a1a1a1a1-1111-4111-8111-111111111111';

/// An order as the kitchen would hold one.
///
/// Only the fields a test cares about are named, so a test can say what it is about
/// and nothing more.
StaffOrderModel buildKitchenOrder({
  String id = 'order-1',
  int orderNumber = 1043,
  OrderStatus status = OrderStatus.accepted,
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
    currency: 'KGS',
    totalMinorUnits: 90000,
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

/// Serves fixed orders and records what the page asked for.
class _FakeKitchenOrderRepository extends StaffOrderRepository {
  _FakeKitchenOrderRepository({
    List<List<StaffOrderModel>>? responses,
    this.listError,
    this.statusError,
  }) : responses = responses ?? <List<StaffOrderModel>>[const []];

  /// One list per read, in order; the last one repeats for any read after it.
  List<List<StaffOrderModel>> responses;

  /// Thrown by [getOrders], standing in for a refused or failed read.
  Object? listError;

  /// Thrown by [setOrderStatus], standing in for a refused move.
  Object? statusError;

  int listCalls = 0;
  int activeListCalls = 0;
  final List<({String restaurantId, String? branchId, int limit})>
      listArguments = [];
  final List<({String orderId, OrderStatus status})> statusCalls = [];

  
  @override
  Future<List<StaffOrderModel>> getOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultLimit,
  }) async {
    listCalls++;
    listArguments.add(
      (restaurantId: restaurantId, branchId: branchId, limit: limit),
    );

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
class _PendingKitchenOrderRepository extends StaffOrderRepository {
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

/// A repository whose reads stay in flight until told to finish, so a test can
/// observe one refresh while another would have to wait.
class _ControlledKitchenOrderRepository extends StaffOrderRepository {
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
    for (final l in listeners) {
      if (l.event == PostgresChangeEvent.insert) {
        l.callback(payload);
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
    for (final l in listeners) {
      if (l.event == PostgresChangeEvent.update) {
        l.callback(payload);
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
    final ch = _FakeRealtimeChannel(channelName);
    channels.add(ch);
    return ch;
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


Future<void> pumpKitchenPage(
  WidgetTester tester,
  StaffOrderRepository repository, {
  String? branch = branchId,
  Size size = const Size(1000, 2000),
  SupabaseClient? supabaseClient,
  bool enableRealtime = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: KitchenPage(
          restaurantId: restaurantId,
          branchId: branch,
          repository: repository,
          supabaseClient: supabaseClient ?? Supabase.instance.client,
          enableRealtime: enableRealtime,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every string rendered anywhere in the tree, joined, for leak checks.
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

/// The statuses rendered as action controls on the page, in lifecycle order.
List<OrderStatus> offeredActions(WidgetTester tester) {
  return [
    for (final status in OrderStatus.values)
      if (find.byKey(staffOrderActionKey(status)).evaluate().isNotEmpty) status,
  ];
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
        url: 'http://localhost:54321',
        publishableKey: 'test-anon-key',
      );
    } catch (_) {}
  });

  tearDownAll(() async {
    try {
      await Supabase.instance.dispose();
    } catch (_) {}
  });

  group('formatKitchenElapsed', () {
    test('reads whole minutes, hours and hours with minutes', () {
      expect(formatKitchenElapsed(const Duration(seconds: 5)), 'Just now');
      expect(formatKitchenElapsed(const Duration(minutes: 5)), '5 min');
      expect(formatKitchenElapsed(const Duration(minutes: 18)), '18 min');
      expect(
        formatKitchenElapsed(const Duration(hours: 1, minutes: 12)),
        '1 h 12 min',
      );
      expect(formatKitchenElapsed(const Duration(hours: 2)), '2 h');
    });

    test('never reports a time in the future as an age', () {
      expect(formatKitchenElapsed(const Duration(minutes: -3)), 'Just now');
    });
  });

  group('KitchenPage', () {
    testWidgets('loads orders through the repository for its branch', (
      tester,
    ) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder(status: OrderStatus.accepted)],
        ],
      );

      await pumpKitchenPage(tester, repository);

      expect(
        repository.activeListCalls,
        1,
        reason: 'the kitchen reads active orders, not the history window',
      );
      expect(repository.listCalls, 1);
      expect(repository.statusCalls, isEmpty);
      expect(repository.listArguments.single.restaurantId, restaurantId);
      expect(repository.listArguments.single.branchId, branchId);
      expect(find.byKey(const Key('kitchenCard_order-1')), findsOneWidget);
      expect(find.text('1 order'), findsOneWidget);
    });

    testWidgets('shows a loading state until the answer arrives', (
      tester,
    ) async {
      final repository = _PendingKitchenOrderRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
        body: KitchenPage(
          restaurantId: restaurantId,
          repository: repository,
          supabaseClient: Supabase.instance.client,
          enableRealtime: false,
        ),
      ),
    ),
  );
  await tester.pump();

      expect(find.text('Loading kitchen orders...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const Key('kitchenEmptyState')), findsNothing);

      repository.answer([buildKitchenOrder()]);
      await tester.pumpAndSettle();

      expect(find.text('Loading kitchen orders...'), findsNothing);
      expect(find.byKey(const Key('kitchenList')), findsOneWidget);
    });

    testWidgets('shows a kitchen empty state when no order is being worked', (
      tester,
    ) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder(status: OrderStatus.ready)],
        ],
      );

      await pumpKitchenPage(tester, repository);

      expect(find.byKey(const Key('kitchenEmptyState')), findsOneWidget);
      expect(find.text('No active kitchen orders'), findsOneWidget);
      expect(find.byKey(const Key('kitchenList')), findsNothing);
      // No fake ticket is invented to fill the space.
      expect(find.byKey(const Key('kitchenCard_order-1')), findsNothing);
    });

    testWidgets('shows a friendly error state and can retry', (tester) async {
      final repository = _FakeKitchenOrderRepository(
        listError: orderPostgrestError(
          '42501',
          message: 'staff_order_access_denied',
        ),
      );

      await pumpKitchenPage(tester, repository);

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
      repository.responses = [
        [buildKitchenOrder()],
      ];

      await tester.tap(find.byKey(const Key('kitchenRetryButton')));
      await tester.pumpAndSettle();

      expect(repository.listCalls, 2);
      expect(find.byKey(const Key('kitchenList')), findsOneWidget);
    });

    testWidgets('shows accepted and preparing orders, and hides the rest', (
      tester,
    ) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [
            buildKitchenOrder(id: 'accepted', orderNumber: 1043),
            buildKitchenOrder(
              id: 'preparing',
              orderNumber: 1044,
              status: OrderStatus.preparing,
            ),
            buildKitchenOrder(
              id: 'pending',
              orderNumber: 1045,
              status: OrderStatus.pending,
            ),
            buildKitchenOrder(
              id: 'ready',
              orderNumber: 1046,
              status: OrderStatus.ready,
            ),
            buildKitchenOrder(
              id: 'served',
              orderNumber: 1047,
              status: OrderStatus.served,
            ),
            buildKitchenOrder(
              id: 'cancelled',
              orderNumber: 1048,
              status: OrderStatus.cancelled,
            ),
          ],
        ],
      );

      await pumpKitchenPage(tester, repository);

      expect(find.byKey(const Key('kitchenCard_accepted')), findsOneWidget);
      expect(find.byKey(const Key('kitchenCard_preparing')), findsOneWidget);

      for (final hidden in ['pending', 'ready', 'served', 'cancelled']) {
        expect(
          find.byKey(Key('kitchenCard_$hidden')),
          findsNothing,
          reason: 'a $hidden order is not a kitchen ticket',
        );
      }

      // The hidden statuses are not shown as words either.
      expect(find.text('Pending'), findsNothing);
      expect(find.text('Ready'), findsNothing);
      expect(find.text('Served'), findsNothing);
      expect(find.text('Cancelled'), findsNothing);
      expect(find.text('2 orders'), findsOneWidget);
    });

    testWidgets('sorts the tickets oldest first', (tester) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [
            buildKitchenOrder(
              id: 'newest',
              orderNumber: 1046,
              createdAt: DateTime.utc(2026, 10, 5, 14, 30),
            ),
            buildKitchenOrder(
              id: 'oldest',
              orderNumber: 1043,
              createdAt: DateTime.utc(2026, 10, 5, 14, 10),
            ),
            buildKitchenOrder(
              id: 'middle',
              orderNumber: 1044,
              createdAt: DateTime.utc(2026, 10, 5, 14, 20),
            ),
          ],
        ],
      );

      await pumpKitchenPage(tester, repository);

      // The order of the rendered cards in the tree is the order on screen, top to
      // bottom: the oldest ticket is first.
      final ids = find
          .byWidgetPredicate(
            (widget) =>
                widget.key is Key &&
                widget.key.toString().contains('kitchenCard_'),
          )
          .evaluate()
          .map((element) => element.widget.key.toString())
          .toList();

      expect(ids, hasLength(3));
      expect(ids[0], contains('kitchenCard_oldest'));
      expect(ids[1], contains('kitchenCard_middle'));
      expect(ids[2], contains('kitchenCard_newest'));
    });

    testWidgets('shows the elapsed time, order number and table label', (
      tester,
    ) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [
            buildKitchenOrder(
              createdAt: DateTime.now().subtract(
                const Duration(minutes: 5, seconds: 30),
              ),
            ),
          ],
        ],
      );

      await pumpKitchenPage(tester, repository);

      expect(find.byKey(const Key('kitchenOrderNumber_order-1')), findsOneWidget);
      expect(find.text('#1043 · 2 items'), findsOneWidget);
      expect(find.text('12 · Window'), findsOneWidget);
      expect(find.byKey(const Key('kitchenElapsed_order-1')), findsOneWidget);
      expect(find.text('5 min'), findsOneWidget);
    });

    testWidgets('an order with no table says so rather than showing nothing', (
      tester,
    ) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [
            buildKitchenOrder(tableNumber: null, tableName: null),
          ],
        ],
      );

      await pumpKitchenPage(tester, repository);

      expect(find.text('No table'), findsOneWidget);
    });

    testWidgets('shows the ordered items with their quantities', (
      tester,
    ) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [
            buildKitchenOrder(
              itemCount: 3,
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
            ),
          ],
        ],
      );

      await pumpKitchenPage(tester, repository);

      expect(find.text('2 × Beshbarmak'), findsOneWidget);
      expect(find.text('1 × Kompot'), findsOneWidget);
    });

    testWidgets('never shows an order id or a table id', (tester) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder(id: 'order-1', tableNumber: '12')],
        ],
      );

      await pumpKitchenPage(tester, repository);

      // The table is named '12 · Window' and the order '#1043'; neither the row id
      // nor the table's id belongs on a ticket.
      expect(find.text('12 · Window'), findsOneWidget);
      expect(find.textContaining('order-1'), findsNothing);
      expect(renderedText(tester), isNot(contains('order-1')));
    });

    testWidgets('a payload carrying a guest token shows nothing of it', (
      tester,
    ) async {
      final payload = buildStaffOrdersJson(
        orders: [buildStaffOrderJson(id: 'order-1', status: 'ACCEPTED')],
      )..['access_token'] = guestAccessToken;
      ((payload['orders'] as List).first as Map<String, dynamic>)['access_token'] =
          guestAccessToken;

      final orders = tryParseStaffOrders(
        jsonDecode(encodeOrderRpcResult(payload)),
        restaurantId: restaurantA,
      );

      final repository = _FakeKitchenOrderRepository(responses: [orders]);

      await pumpKitchenPage(tester, repository);

      expect(find.text('12 · Window'), findsOneWidget);
      expect(renderedText(tester), isNot(contains(guestAccessToken)));
      expect(find.textContaining(guestAccessToken), findsNothing);
    });

    testWidgets('offers a preparing move for an accepted order', (tester) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder(status: OrderStatus.accepted)],
        ],
      );

      await pumpKitchenPage(tester, repository);

      expect(offeredActions(tester), [
        OrderStatus.preparing,
        OrderStatus.cancelled,
      ]);
      expect(
        find.byKey(staffOrderActionKey(OrderStatus.preparing)),
        findsOneWidget,
      );
    });

    testWidgets('offers a ready move for a preparing order', (tester) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder(status: OrderStatus.preparing)],
        ],
      );

      await pumpKitchenPage(tester, repository);

      expect(offeredActions(tester), [
        OrderStatus.ready,
        OrderStatus.cancelled,
      ]);
      expect(find.byKey(staffOrderActionKey(OrderStatus.ready)), findsOneWidget);
    });

    testWidgets('never offers a move the kitchen cannot make for an accepted order', (
      tester,
    ) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder(status: OrderStatus.accepted)],
        ],
      );

      await pumpKitchenPage(tester, repository);

      // A kitchen member starts the food; it does not accept the order, finish it or
      // put it back to pending.
      expect(find.byKey(const Key('staffOrderAction_accepted')), findsNothing);
      expect(find.byKey(const Key('staffOrderAction_ready')), findsNothing);
      expect(find.byKey(const Key('staffOrderAction_served')), findsNothing);
      expect(find.byKey(const Key('staffOrderAction_pending')), findsNothing);
    });

    testWidgets('never offers a move the kitchen cannot make for a preparing order', (
      tester,
    ) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder(status: OrderStatus.preparing)],
        ],
      );

      await pumpKitchenPage(tester, repository);

      // A kitchen member finishes the food; it does not step back to preparing or
      // carry the order to the table.
      expect(find.byKey(const Key('staffOrderAction_preparing')), findsNothing);
      expect(find.byKey(const Key('staffOrderAction_accepted')), findsNothing);
      expect(find.byKey(const Key('staffOrderAction_served')), findsNothing);
    });

    testWidgets('a successful move re-reads the list and updates the status', (
      tester,
    ) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder(status: OrderStatus.accepted)],
          [buildKitchenOrder(status: OrderStatus.preparing)],
        ],
      );

      await pumpKitchenPage(tester, repository);

      await tester.tap(
        find.byKey(staffOrderActionKey(OrderStatus.preparing)),
      );
      await tester.pumpAndSettle();

      expect(repository.statusCalls, [
        (orderId: 'order-1', status: OrderStatus.preparing),
      ]);
      expect(repository.listCalls, 2, reason: 'the list is re-read after a move');
      expect(find.text('Preparing'), findsOneWidget);
      expect(find.text('Accepted'), findsNothing);
      expect(find.textContaining('is now preparing'), findsOneWidget);
    });

    testWidgets('a refused move shows safe wording and never the raw message', (
      tester,
    ) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder(status: OrderStatus.accepted)],
        ],
        statusError: orderPostgrestError(
          '42501',
          message: 'staff_order_status_not_permitted',
        ),
      );

      await pumpKitchenPage(tester, repository);

      await tester.tap(
        find.byKey(staffOrderActionKey(OrderStatus.preparing)),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Your role cannot make that status change.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('staff_order_status_not_permitted'),
        findsNothing,
      );
      expect(renderedText(tester), isNot(contains('42501')));
      // The order keeps the status the database still holds it in.
      expect(find.text('Accepted'), findsOneWidget);
      expect(find.text('Preparing'), findsNothing);
    });

    testWidgets('pull to refresh re-reads the orders', (tester) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder(id: 'order-1', orderNumber: 1043)],
          [
            buildKitchenOrder(
              id: 'order-2',
              orderNumber: 1044,
              tableNumber: '9',
              tableName: null,
            ),
          ],
        ],
      );

      await pumpKitchenPage(tester, repository, size: const Size(400, 500));

      expect(find.text('12 · Window'), findsOneWidget);

      await tester.fling(
        find.byKey(const Key('kitchenList')),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();

      expect(repository.listCalls, 2);
      expect(find.text('12 · Window'), findsNothing);
      expect(find.text('9'), findsOneWidget);
    });

    testWidgets('the elapsed timer sends no request and is disposed safely', (
      tester,
    ) async {
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder(status: OrderStatus.accepted)],
        ],
      );

      await pumpKitchenPage(tester, repository);

      expect(repository.listCalls, 1);

      // A tick redraws the elapsed text and nothing else: no read, no write.
      await tester.pump(kitchenElapsedTick);
      await tester.pump();

      expect(repository.listCalls, 1);
      expect(repository.statusCalls, isEmpty);
      expect(find.byKey(const Key('kitchenCard_order-1')), findsOneWidget);

      // Unmounting must cancel the timer; a live timer fails the test framework's
      // own "a Timer is still pending" check at the end of the test.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(tester.takeException(), isNull);
    });
  });

  group('KitchenPage realtime', () {
    const channelName = 'kitchen:order_change_events:restaurant-1';

    testWidgets('an INSERT for this branch refreshes the kitchen orders', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeKitchenOrderRepository(
        responses: [
          const <StaffOrderModel>[],
          [buildKitchenOrder()],
        ],
      );

      await pumpKitchenPage(
        tester,
        repository,
        supabaseClient: client,
        enableRealtime: true,
      );

      expect(client.channels, hasLength(1));
      expect(client.channels.single.channelName, channelName);
      expect(client.channels.single.subscribed, isTrue);
      expect(repository.listCalls, 1);
      expect(find.byKey(const Key('kitchenCard_order-1')), findsNothing);

      client.channels.single.triggerInsert({'branch_id': branchId});
      await tester.pumpAndSettle();

      expect(repository.listCalls, 2);
      expect(find.byKey(const Key('kitchenCard_order-1')), findsOneWidget);
    });

    testWidgets('an UPDATE for this branch refreshes the kitchen orders', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [
            buildKitchenOrder(status: OrderStatus.preparing, itemCount: 2),
          ],
          [
            buildKitchenOrder(status: OrderStatus.preparing, itemCount: 3),
          ],
        ],
      );

      await pumpKitchenPage(
        tester,
        repository,
        supabaseClient: client,
        enableRealtime: true,
      );

      expect(repository.listCalls, 1);
      expect(find.text('#1043 · 2 items'), findsOneWidget);

      client.channels.single.triggerUpdate({'branch_id': branchId});
      await tester.pumpAndSettle();

      expect(repository.listCalls, 2);
      expect(find.text('#1043 · 3 items'), findsOneWidget);
    });

    testWidgets('an event for another branch is ignored', (tester) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder()],
        ],
      );

      await pumpKitchenPage(
        tester,
        repository,
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
        reason: 'an event for another branch is not this kitchen\'s feed',
      );
      expect(find.byKey(const Key('kitchenCard_order-1')), findsOneWidget);
    });

    testWidgets('a burst of realtime events becomes one follow-up read', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _ControlledKitchenOrderRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KitchenPage(
              restaurantId: restaurantId,
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
      repository.answerAll([buildKitchenOrder()]);
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

      repository.answerAll([buildKitchenOrder()]);
      await tester.pumpAndSettle();
      expect(
        repository.listCalls,
        3,
        reason: 'the whole burst is served by exactly one follow-up read',
      );
    });

    testWidgets('a lost channel is announced, and a reconnect clears it', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder()],
        ],
      );

      await pumpKitchenPage(
        tester,
        repository,
        supabaseClient: client,
        enableRealtime: true,
      );

      final channel = client.channels.single;
      expect(find.byKey(const Key('kitchenRealtimeNotice')), findsNothing);

      channel.changeStatus(RealtimeSubscribeStatus.channelError, 'boom');
      await tester.pump();

      expect(find.byKey(const Key('kitchenRealtimeNotice')), findsOneWidget);
      expect(
        find.textContaining('Live order updates are unavailable'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('kitchenList')), findsOneWidget);

      channel.changeStatus(RealtimeSubscribeStatus.subscribed);
      await tester.pump();

      expect(find.byKey(const Key('kitchenRealtimeNotice')), findsNothing);
      expect(repository.listCalls, 1);
    });

    testWidgets('disposal during a realtime refresh leaves nothing pending', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _ControlledKitchenOrderRepository();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KitchenPage(
              restaurantId: restaurantId,
              branchId: branchId,
              repository: repository,
              supabaseClient: client,
              enableRealtime: true,
            ),
          ),
        ),
      );
      await tester.pump();
      repository.answerAll([buildKitchenOrder()]);
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

    testWidgets('the realtime channel is removed when the page is disposed', (
      tester,
    ) async {
      final client = _FakeSupabaseClient();
      final repository = _FakeKitchenOrderRepository(
        responses: [
          [buildKitchenOrder()],
        ],
      );

      await pumpKitchenPage(
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
