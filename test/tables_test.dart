import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/app/router/app_router.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/table_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/table_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/table_error_message.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/tables_page.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

TableModel buildTable({
  String id = 'table-1',
  String tableNumber = 'A1',
  int capacity = 4,
  String? name,
  String? zone,
  String status = 'AVAILABLE',
  String qrToken = 'qr-token-1',
  bool isActive = true,
}) {
  return TableModel(
    id: id,
    restaurantId: 'restaurant-1',
    branchId: 'branch-1',
    tableNumber: tableNumber,
    name: name,
    capacity: capacity,
    zone: zone,
    status: status,
    qrToken: qrToken,
    isActive: isActive,
    createdAt: DateTime.utc(2026, 9, 18),
    updatedAt: DateTime.utc(2026, 9, 18),
  );
}

Future<void> pumpTablesPage(
  WidgetTester tester,
  TableRepository repository,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TablesPage(
          restaurantId: 'restaurant-1',
          branchId: 'branch-1',
          repository: repository,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('TableModel', () {
    test('parses a table row including its qr token', () {
      final table = TableModel.fromJson({
        'id': 'table-1',
        'restaurant_id': 'restaurant-1',
        'branch_id': 'branch-1',
        'table_number': 'A1',
        'name': 'Window table',
        'capacity': 4,
        'zone': 'Terrace',
        'status': 'AVAILABLE',
        'qr_token': 'qr-token-1',
        'is_active': true,
        'created_at': '2026-09-18T00:00:00.000Z',
        'updated_at': '2026-09-18T00:00:00.000Z',
      });

      expect(table.id, 'table-1');
      expect(table.restaurantId, 'restaurant-1');
      expect(table.branchId, 'branch-1');
      expect(table.tableNumber, 'A1');
      expect(table.name, 'Window table');
      expect(table.capacity, 4);
      expect(table.zone, 'Terrace');
      expect(table.status, 'AVAILABLE');
      expect(table.qrToken, 'qr-token-1');
      expect(table.isActive, isTrue);
      expect(table.createdAt, DateTime.utc(2026, 9, 18));
    });

    test('mutation payload never carries id, restaurant or qr token', () {
      final table = buildTable(
        tableNumber: 'B7',
        capacity: 6,
        name: 'Corner',
        zone: 'Main hall',
      );

      final payload = table.toMutationJson();

      expect(payload['table_number'], 'B7');
      expect(payload['capacity'], 6);
      expect(payload['name'], 'Corner');
      expect(payload['zone'], 'Main hall');
      expect(payload.containsKey('qr_token'), isFalse);
      expect(payload.containsKey('id'), isFalse);
      expect(payload.containsKey('restaurant_id'), isFalse);
      expect(payload.containsKey('branch_id'), isFalse);
    });

    test('display name falls back to the table number', () {
      expect(buildTable(name: null).displayName, 'A1');
      expect(buildTable(name: 'Window table').displayName, 'A1 · Window table');
    });
  });

  group('qr helpers', () {
    test('public url uses only the opaque qr token', () {
      expect(
        AppRouter.publicMenuUrl('abc-123'),
        '${AppRouter.publicMenuBaseUrl}/abc-123',
      );
    });

    test('capacity is formatted with a readable suffix', () {
      expect(formatTableCapacity(1), '1 seat');
      expect(formatTableCapacity(4), '4 seats');
    });
  });

  group('validation', () {
    test('table number is required and length limited', () {
      expect(validateTableNumber(null), 'Enter a table number.');
      expect(validateTableNumber('   '), 'Enter a table number.');
      expect(validateTableNumber('A1'), isNull);
      expect(
        validateTableNumber('A' * (maxTableNumberLength + 1)),
        'Table number must be $maxTableNumberLength characters or fewer.',
      );
    });

    test('capacity matches the database capacity > 0 constraint', () {
      expect(validateTableCapacity(null), 'Enter a capacity.');
      expect(validateTableCapacity('  '), 'Enter a capacity.');
      expect(
        validateTableCapacity('0'),
        'Capacity must be a whole number of 1 or more.',
      );
      expect(
        validateTableCapacity('abc'),
        'Capacity must be a whole number of 1 or more.',
      );
      expect(validateTableCapacity('1'), isNull);
      expect(validateTableCapacity('12'), isNull);
    });
  });

  group('TableRepository', () {
    late SupabaseClient client;

    setUp(() {
      client = SupabaseClient('http://localhost:54321', 'test-anon-key');
    });

    tearDown(() => client.dispose());

    test('avoids database calls when unauthenticated', () async {
      final repository = TableRepository.withClient(client);

      expect(await repository.getTables('restaurant-1'), isEmpty);
      expect(
        await repository.createTable(
          restaurantId: 'restaurant-1',
          branchId: 'branch-1',
          tableNumber: 'A1',
        ),
        isNull,
      );
      expect(
        await repository.updateTable(
          restaurantId: 'restaurant-1',
          tableId: 'table-1',
          tableNumber: 'A1',
          capacity: 2,
        ),
        isNull,
      );
      expect(
        await repository.updateTableStatus(
          restaurantId: 'restaurant-1',
          tableId: 'table-1',
          status: 'OCCUPIED',
        ),
        isNull,
      );
      await repository.deleteTable(
        restaurantId: 'restaurant-1',
        tableId: 'table-1',
      );
    });
  });

  group('TablesPage', () {
    testWidgets('shows an empty state when there are no tables', (
      tester,
    ) async {
      await pumpTablesPage(tester, FakeTableRepository());

      expect(find.text('No tables yet'), findsOneWidget);
      expect(find.byKey(const Key('emptyAddTableButton')), findsOneWidget);
    });

    testWidgets('renders tables with capacity, zone and QR action', (
      tester,
    ) async {
      final repository = FakeTableRepository(
        initial: [
          buildTable(tableNumber: 'A1', capacity: 4, zone: 'Terrace'),
          buildTable(
            id: 'table-2',
            tableNumber: 'B2',
            capacity: 1,
            name: 'Bar',
            isActive: false,
          ),
        ],
      );
      await pumpTablesPage(tester, repository);

      expect(find.text('A1'), findsOneWidget);
      expect(find.text('B2 · Bar'), findsOneWidget);
      expect(find.text('4 seats · Terrace'), findsOneWidget);
      expect(find.text('1 seat · Inactive'), findsOneWidget);
      expect(find.byKey(const Key('showQrButton_table-1')), findsOneWidget);
      expect(find.byKey(const Key('editTableButton_table-1')), findsOneWidget);
      expect(
        find.byKey(const Key('deleteTableButton_table-1')),
        findsOneWidget,
      );
    });

    testWidgets('creates a table scoped to the restaurant and branch', (
      tester,
    ) async {
      final repository = FakeTableRepository();
      await pumpTablesPage(tester, repository);

      await tester.tap(find.byKey(const Key('addTableButton')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('tableNumberField')), 'A1');
      await tester.enterText(find.byKey(const Key('tableCapacityField')), '4');
      await tester.enterText(find.byKey(const Key('tableZoneField')), 'Terrace');
      await tester.tap(find.byKey(const Key('tableFormSubmitButton')));
      await tester.pumpAndSettle();

      expect(repository.createdTableNumbers, contains('A1'));
      expect(repository.createdRestaurantIds, contains('restaurant-1'));
      expect(repository.createdBranchIds, contains('branch-1'));
      expect(find.text('A1'), findsOneWidget);
    });

    testWidgets('add dialog validates required fields', (tester) async {
      final repository = FakeTableRepository();
      await pumpTablesPage(tester, repository);

      await tester.tap(find.byKey(const Key('addTableButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tableFormSubmitButton')));
      await tester.pump();

      expect(find.text('Enter a table number.'), findsOneWidget);
      expect(find.text('Enter a capacity.'), findsOneWidget);
      expect(repository.createdTableNumbers, isEmpty);
    });

    testWidgets('edit dialog is prefilled and saves without changing the token', (
      tester,
    ) async {
      final repository = FakeTableRepository(
        initial: [buildTable(tableNumber: 'A1', capacity: 4, zone: 'Terrace')],
      );
      await pumpTablesPage(tester, repository);

      await tester.tap(find.byKey(const Key('editTableButton_table-1')));
      await tester.pumpAndSettle();

      expect(find.text('Edit table'), findsOneWidget);
      final numberField = tester.widget<TextFormField>(
        find.byKey(const Key('tableNumberField')),
      );
      final capacityField = tester.widget<TextFormField>(
        find.byKey(const Key('tableCapacityField')),
      );
      expect(numberField.controller?.text, 'A1');
      expect(capacityField.controller?.text, '4');

      await tester.enterText(find.byKey(const Key('tableNumberField')), 'A2');
      await tester.tap(find.byKey(const Key('tableFormSubmitButton')));
      await tester.pumpAndSettle();

      expect(repository.updatedTableNumbers, contains('A2'));
      expect(repository.updatedTableIds, contains('table-1'));
      expect(find.text('A2'), findsOneWidget);
      // The database owns the token, so it must survive an edit unchanged.
      expect(repository.tables.single.qrToken, 'qr-token-1');
    });

    testWidgets('delete asks for confirmation and then removes the table', (
      tester,
    ) async {
      final repository = FakeTableRepository(
        initial: [buildTable(tableNumber: 'A1')],
      );
      await pumpTablesPage(tester, repository);

      await tester.tap(find.byKey(const Key('deleteTableButton_table-1')));
      await tester.pumpAndSettle();

      expect(find.text('Delete table?'), findsOneWidget);
      expect(
        find.text('Delete "A1"? Its QR code will stop working.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('deleteTableConfirmButton')));
      await tester.pumpAndSettle();

      expect(repository.deleteCalls, 1);
      expect(find.text('A1'), findsNothing);
      expect(find.text('No tables yet'), findsOneWidget);
    });

    testWidgets('cancelling the delete dialog does not delete', (tester) async {
      final repository = FakeTableRepository(
        initial: [buildTable(tableNumber: 'A1')],
      );
      await pumpTablesPage(tester, repository);

      await tester.tap(find.byKey(const Key('deleteTableButton_table-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('deleteTableCancelButton')));
      await tester.pumpAndSettle();

      expect(repository.deleteCalls, 0);
      expect(find.text('A1'), findsOneWidget);
    });

    testWidgets('shows a QR code built from the table token', (tester) async {
      await pumpTablesPage(
        tester,
        FakeTableRepository(initial: [buildTable(qrToken: 'qr-token-1')]),
      );

      await tester.tap(find.byKey(const Key('showQrButton_table-1')));
      await tester.pumpAndSettle();

      expect(find.byType(QrImageView), findsOneWidget);
      expect(
        find.byKey(const Key('tableQrUrl')),
        findsOneWidget,
      );
      expect(
        AppRouter.publicMenuUrl('qr-token-1'),
        '${AppRouter.publicMenuBaseUrl}/qr-token-1',
      );
      expect(
        find.textContaining('qr-token-1'),
        findsOneWidget,
        reason: 'The QR must encode the public token, not internal ids.',
      );
    });

    testWidgets('QR dialog never exposes internal database ids', (
      tester,
    ) async {
      await pumpTablesPage(
        tester,
        FakeTableRepository(initial: [buildTable(qrToken: 'qr-token-1')]),
      );

      await tester.tap(find.byKey(const Key('showQrButton_table-1')));
      await tester.pumpAndSettle();

      final qrUrl = tester
          .widget<SelectableText>(find.byKey(const Key('tableQrUrl')))
          .data!;
      expect(qrUrl, AppRouter.publicMenuUrl('qr-token-1'));
      expect(qrUrl, isNot(contains('table-1')));
      expect(qrUrl, isNot(contains('restaurant-1')));
      expect(qrUrl, isNot(contains('branch-1')));

      await tester.tap(find.byKey(const Key('tableQrCloseButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tableQrCode')), findsNothing);
    });

    testWidgets('status changes keep the qr token stable', (tester) async {
      final repository = FakeTableRepository(
        initial: [buildTable(tableNumber: 'A1', qrToken: 'qr-token-1')],
      );
      await pumpTablesPage(tester, repository);

      await repository.updateTableStatus(
        restaurantId: 'restaurant-1',
        tableId: 'table-1',
        status: 'OCCUPIED',
      );

      expect(repository.statusRestaurantIds, contains('restaurant-1'));
      expect(repository.tables.single.status, 'OCCUPIED');
      expect(
        repository.tables.single.qrToken,
        'qr-token-1',
        reason: 'A status change must never invalidate a printed QR code.',
      );
    });

    testWidgets('scopes every operation to the restaurant and branch', (
      tester,
    ) async {
      final repository = FakeTableRepository(
        initial: [buildTable(tableNumber: 'A1')],
      );
      await pumpTablesPage(tester, repository);

      expect(repository.requestedRestaurantIds, contains('restaurant-1'));
      expect(repository.requestedBranchIds, contains('branch-1'));

      await tester.tap(find.byKey(const Key('addTableButton')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('tableNumberField')), 'A2');
      await tester.enterText(find.byKey(const Key('tableCapacityField')), '2');
      await tester.tap(find.byKey(const Key('tableFormSubmitButton')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('deleteTableButton_table-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('deleteTableConfirmButton')));
      await tester.pumpAndSettle();

      expect(
        repository.requestedRestaurantIds.every(
          (id) => id == 'restaurant-1',
        ),
        isTrue,
      );
      expect(
        repository.createdRestaurantIds.every(
          (id) => id == 'restaurant-1',
        ),
        isTrue,
      );
      expect(repository.deletedRestaurantIds, contains('restaurant-1'));
    });

    testWidgets('shows an error state and retries', (tester) async {
      final repository = _FailingTableRepository();
      await pumpTablesPage(tester, repository);

      expect(
        find.text('We could not load your tables. Please try again.'),
        findsOneWidget,
      );

      repository.failuresRemaining = 0;
      await tester.tap(find.byKey(const Key('tablesRetryButton')));
      await tester.pumpAndSettle();

      expect(find.text('No tables yet'), findsOneWidget);
    });

    testWidgets('shows a loading state while tables are fetched', (
      tester,
    ) async {
      final completer = Completer<List<TableModel>>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TablesPage(
              restaurantId: 'restaurant-1',
              branchId: 'branch-1',
              repository: _PendingTableRepository(completer),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Loading tables...'), findsOneWidget);

      completer.complete([]);
      await tester.pumpAndSettle();
      expect(find.text('No tables yet'), findsOneWidget);
    });
  });

  group('error messages', () {
    test('mutation errors are converted into safe messages', () {
      expect(
        tableMutationErrorMessage(ArgumentError('bad')),
        'Check the table details and try again.',
      );
      expect(
        tableMutationErrorMessage(
          const PostgrestException(
            message: 'new row violates check constraint',
            code: '23514',
          ),
        ),
        'Enter a capacity of at least 1 and a valid status.',
      );
      expect(
        tableMutationErrorMessage(
          const PostgrestException(
            message: 'foreign key violation',
            code: '23503',
          ),
        ),
        'That branch does not belong to your restaurant.',
      );
      expect(
        tableMutationErrorMessage(
          const PostgrestException(
            message: 'new row violates row-level security policy',
            code: '42501',
          ),
        ),
        'You do not have permission to manage tables.',
      );
      expect(
        tableMutationErrorMessage(StateError('boom')),
        'We could not save this table. Please try again.',
      );
    });

    test('deletion errors explain related records', () {
      expect(
        tableDeleteErrorMessage(
          const PostgrestException(
            message: 'violates foreign key constraint',
            code: '23503',
          ),
        ),
        'This table is used by other records and cannot be deleted yet.',
      );
      expect(
        tableDeleteErrorMessage(StateError('boom')),
        'We could not delete this table. Please try again.',
      );
    });
  });
}

class FakeTableRepository extends TableRepository {
  FakeTableRepository({List<TableModel>? initial}) : tables = initial ?? [];

  List<TableModel> tables;
  int deleteCalls = 0;
  final List<String> createdTableNumbers = [];
  final List<String> createdRestaurantIds = [];
  final List<String> createdBranchIds = [];
  final List<String> updatedTableNumbers = [];
  final List<String> updatedTableIds = [];
  final List<String> requestedRestaurantIds = [];
  final List<String> requestedBranchIds = [];
  final List<String> deletedRestaurantIds = [];
  final List<String> statusRestaurantIds = [];

  @override
  Future<List<TableModel>> getTables(
    String restaurantId, {
    String? branchId,
  }) async {
    requestedRestaurantIds.add(restaurantId);
    requestedBranchIds.add(branchId ?? '');
    return tables;
  }

  @override
  Future<TableModel?> createTable({
    required String restaurantId,
    required String branchId,
    required String tableNumber,
    int capacity = 1,
    String? name,
    String? zone,
  }) async {
    createdTableNumbers.add(tableNumber);
    createdRestaurantIds.add(restaurantId);
    createdBranchIds.add(branchId);
    final table = buildTable(
      id: 'table-new-${tables.length}',
      tableNumber: tableNumber,
      capacity: capacity,
      name: name,
      zone: zone,
      // The database generates the real token; the fake mimics a fresh one.
      qrToken: 'qr-token-generated',
    );
    tables = [...tables, table];
    return table;
  }

  @override
  Future<TableModel?> updateTable({
    required String restaurantId,
    required String tableId,
    required String tableNumber,
    required int capacity,
    String? name,
    String? zone,
    bool isActive = true,
  }) async {
    updatedTableNumbers.add(tableNumber);
    updatedTableIds.add(tableId);
    final updated = buildTable(
      id: tableId,
      tableNumber: tableNumber,
      capacity: capacity,
      name: name,
      zone: zone,
      qrToken: tables
          .firstWhere((table) => table.id == tableId)
          .qrToken,
    );
    tables = [
      for (final table in tables)
        if (table.id == tableId) updated else table,
    ];
    return updated;
  }

  @override
  Future<TableModel?> updateTableStatus({
    required String restaurantId,
    required String tableId,
    required String status,
  }) async {
    statusRestaurantIds.add(restaurantId);
    final updated = buildTable(
      id: tableId,
      tableNumber: tables.firstWhere((table) => table.id == tableId).tableNumber,
      qrToken: tables.firstWhere((table) => table.id == tableId).qrToken,
      status: status,
    );
    tables = [
      for (final table in tables)
        if (table.id == tableId) updated else table,
    ];
    return updated;
  }

  @override
  Future<void> deleteTable({
    required String restaurantId,
    required String tableId,
  }) async {
    deletedRestaurantIds.add(restaurantId);
    deleteCalls++;
    tables = [
      for (final table in tables)
        if (table.id != tableId) table,
    ];
  }
}

class _PendingTableRepository extends TableRepository {
  _PendingTableRepository(this.completer);

  final Completer<List<TableModel>> completer;

  @override
  Future<List<TableModel>> getTables(
    String restaurantId, {
    String? branchId,
  }) => completer.future;
}

class _FailingTableRepository extends TableRepository {
  int failuresRemaining = 1;

  @override
  Future<List<TableModel>> getTables(
    String restaurantId, {
    String? branchId,
  }) async {
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('network down');
    }
    return [];
  }
}
