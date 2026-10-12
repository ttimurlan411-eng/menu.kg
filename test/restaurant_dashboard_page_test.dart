import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/kitchen/presentation/pages/kitchen_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/category_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/menu_item_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_member_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/table_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/category_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/menu_item_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_member_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/table_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/bookings_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/categories_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/module_placeholder_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/products_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_order_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_reservation_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_order_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_reservation_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/restaurant_dashboard_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/staff_members_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/staff_orders_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/tables_page.dart';

TableModel buildTable({
  String id = 'table-1',
  String tableNumber = 'A1',
  int capacity = 4,
  String qrToken = 'qr-token-1',
}) {
  return TableModel(
    id: id,
    restaurantId: 'restaurant-id',
    branchId: 'branch-id',
    tableNumber: tableNumber,
    capacity: capacity,
    status: 'AVAILABLE',
    qrToken: qrToken,
    isActive: true,
    createdAt: DateTime.utc(2026, 9, 18),
    updatedAt: DateTime.utc(2026, 9, 18),
  );
}

/// Realtime options for the test-global Supabase client.
///
/// The dashboard builds the kitchen screen with the real [SupabaseClient], and
/// that screen subscribes to Realtime order changes by default. No test here
/// wants a socket: throwing from the transport keeps the Realtime client from
/// ever connecting (its pushes are buffered instead), and a zero empty-channel
/// disconnect keeps it from leaving a deferred disconnect timer behind.
RealtimeClientOptions _testRealtimeClientOptions() => RealtimeClientOptions(
  disconnectOnEmptyChannelsAfter: Duration.zero,
  transport: (String url, [Map<String, String>? headers]) =>
      throw StateError('Tests do not open a Realtime socket: $url'),
);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
        url: 'http://localhost:54321',
        publishableKey: 'test-anon-key',
        realtimeClientOptions: _testRealtimeClientOptions(),
      );
    } catch (_) {}
  });

  tearDownAll(() async {
    try {
      await Supabase.instance.dispose();
    } catch (_) {}
  });

  void setViewSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpDashboard(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
    String role = 'OWNER',
    bool showCreationSuccess = false,
    CategoryRepository categoryRepository = const _EmptyCategoryRepository(),
    MenuItemRepository menuItemRepository = const _EmptyMenuItemRepository(),
    TableRepository tableRepository = const _EmptyTableRepository(),
    StaffOrderRepository staffOrderRepository = const _EmptyStaffOrderRepository(),
    StaffReservationRepository staffReservationRepository =
        const _EmptyStaffReservationRepository(),
    StaffMemberRepository staffMemberRepository =
        const _EmptyStaffMemberRepository(),
    String? branchId = 'branch-id',
  }) async {
    setViewSize(tester, size);
    await tester.pumpWidget(
      MaterialApp(
        home: RestaurantDashboardPage(
          restaurantId: 'restaurant-id',
          restaurantName: 'Bishkek Cafe',
          branchName: 'Main branch',
          branchId: branchId,
          role: role,
          userEmail: 'owner@example.com',
          membershipCount: 1,
          showCreationSuccess: showCreationSuccess,
          categoryRepository: categoryRepository,
          menuItemRepository: menuItemRepository,
          tableRepository: tableRepository,
          staffOrderRepository: staffOrderRepository,
          staffReservationRepository: staffReservationRepository,
          staffMemberRepository: staffMemberRepository,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('dashboard renders restaurant context', (tester) async {
    await pumpDashboard(tester);

    expect(find.text('Bishkek Cafe'), findsWidgets);
    expect(find.text('Main branch'), findsWidgets);
    expect(find.text('OWNER'), findsWidgets);
    expect(find.text('1 membership'), findsOneWidget);
    expect(find.text('owner@example.com'), findsWidgets);
  });

  testWidgets('dashboard renders the currently available data cards', (
    tester,
  ) async {
    await pumpDashboard(tester);

    expect(find.text('Restaurant'), findsOneWidget);
    expect(find.text('Branch'), findsOneWidget);
    expect(find.text('Role'), findsOneWidget);
    expect(find.text('Memberships'), findsOneWidget);
  });

  testWidgets('navigation items render for every admin section the owner may use', (
    tester,
  ) async {
    await pumpDashboard(tester, size: const Size(1400, 1200));

    for (final section in AdminDashboardSection.values) {
      final tile = find.byKey(Key('adminNav_${section.name}'));
      if (section == AdminDashboardSection.kitchen) {
        // Kitchen is the kitchen role's screen, so an owner is not offered it.
        expect(tile, findsNothing);
        continue;
      }
      expect(tile, findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.text(section.label)),
        findsOneWidget,
      );
    }
  });

  testWidgets('kitchen is offered to a kitchen member and opens the kitchen', (
    tester,
  ) async {
    await pumpDashboard(
      tester,
      role: 'KITCHEN',
      staffOrderRepository: const _EmptyStaffOrderRepository(),
    );

    final tile = find.byKey(const Key('adminNav_kitchen'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.text('Kitchen')),
      findsOneWidget,
    );

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.byType(KitchenPage), findsOneWidget);
    expect(find.text('No active kitchen orders'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hands the kitchen page the injected order repository', (
    tester,
  ) async {
    final repository = _RecordingStaffOrderRepository();
    await pumpDashboard(
      tester,
      role: 'KITCHEN',
      staffOrderRepository: repository,
    );

    await tester.tap(find.byKey(const Key('adminNav_kitchen')));
    await tester.pumpAndSettle();

    expect(repository.listCalls, 1);
    expect(repository.lastRestaurantId, 'restaurant-id');
    expect(repository.lastBranchId, 'branch-id');
  });

  testWidgets('kitchen is not offered to a manager or a waiter', (tester) async {
    for (final role in ['MANAGER', 'WAITER']) {
      await pumpDashboard(tester, role: role);
      expect(
        find.byKey(const Key('adminNav_kitchen')),
        findsNothing,
        reason: 'Kitchen belongs to the kitchen role, not to $role',
      );
    }
  });

  testWidgets('placeholder page renders for an unfinished module', (
    tester,
  ) async {
    await pumpDashboard(tester);

    await tester.tap(find.byKey(const Key('adminNav_analytics')));
    await tester.pump();

    expect(find.text('Analytics'), findsWidgets);
    expect(find.text('Coming soon'), findsOneWidget);
    expect(find.text('Бул бөлүк кийинки этапта кошулат'), findsOneWidget);

    expect(find.byType(ModulePlaceholderPage), findsOneWidget);
  });

  testWidgets('staff opens the staff members page', (tester) async {
    await pumpDashboard(
      tester,
      staffMemberRepository: const _EmptyStaffMemberRepository(),
    );

    await tester.tap(find.byKey(const Key('adminNav_staff')));
    await tester.pumpAndSettle();

    expect(find.byType(StaffMembersPage), findsOneWidget);
    expect(find.byType(ModulePlaceholderPage), findsNothing);
    expect(find.text('No staff members yet'), findsOneWidget);
  });

  testWidgets('staff uses the injected member repository', (tester) async {
    final repository = _RecordingStaffMemberRepository();
    await pumpDashboard(tester, staffMemberRepository: repository);

    await tester.tap(find.byKey(const Key('adminNav_staff')));
    await tester.pumpAndSettle();

    expect(repository.listCalls, 1);
    expect(repository.lastRestaurantId, 'restaurant-id');
  });

  testWidgets('tables opens the real tables page for the active branch', (
    tester,
  ) async {
    await pumpDashboard(tester);

    await tester.tap(find.byKey(const Key('adminNav_tables')));
    await tester.pumpAndSettle();

    expect(find.byType(TablesPage), findsOneWidget);
    expect(find.text('No tables yet'), findsOneWidget);
  });

  testWidgets('qr codes opens the tables page with QR actions', (tester) async {
    final tableRepository = _FakeTableRepository(
      initial: [buildTable(tableNumber: 'A1')],
    );
    await pumpDashboard(tester, tableRepository: tableRepository);

    await tester.tap(find.byKey(const Key('adminNav_qrCodes')));
    await tester.pumpAndSettle();

    expect(find.byType(TablesPage), findsOneWidget);
    expect(find.byKey(const Key('showQrButton_table-1')), findsOneWidget);
  });

  testWidgets('tables falls back to a placeholder without a branch id', (
    tester,
  ) async {
    await pumpDashboard(tester, branchId: null);

    await tester.tap(find.byKey(const Key('adminNav_tables')));
    await tester.pump();

    expect(find.byType(ModulePlaceholderPage), findsOneWidget);
  });

  testWidgets('categories opens the real categories page', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.byKey(const Key('adminNav_categories')));
    await tester.pumpAndSettle();

    expect(find.byType(CategoriesPage), findsOneWidget);
    expect(find.text('No categories yet'), findsOneWidget);
  });

  testWidgets('products opens the real products page', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.byKey(const Key('adminNav_products')));
    await tester.pumpAndSettle();

    expect(find.byType(ProductsPage), findsOneWidget);
    expect(find.text('No products yet'), findsOneWidget);
  });

  testWidgets('dashboard shows neutral empty states, not fake numbers', (
    tester,
  ) async {
    await pumpDashboard(tester);

    expect(
      find.text(
        'Analytics will appear here after the analytics module is implemented.',
      ),
      findsOneWidget,
    );
    // Orders are a real section now, so they are no longer announced as upcoming.
    expect(
      find.text(
        'Orders will appear here after the ordering module is implemented.',
      ),
      findsNothing,
    );
  });

  testWidgets('orders opens the staff orders list', (tester) async {
    await pumpDashboard(
      tester,
      staffOrderRepository: const _EmptyStaffOrderRepository(),
    );

    await tester.tap(find.byKey(const Key('adminNav_orders')));
    await tester.pumpAndSettle();

    expect(find.byType(StaffOrdersPage), findsOneWidget);
    expect(find.text('No orders yet'), findsOneWidget);
  });

  testWidgets('bookings opens the real bookings page', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.byKey(const Key('adminNav_bookings')));
    await tester.pumpAndSettle();

    expect(find.byType(BookingsPage), findsOneWidget);
    expect(find.byType(ModulePlaceholderPage), findsNothing);
    expect(find.text('No reservations for this day'), findsOneWidget);
  });

  testWidgets('bookings no longer shows the placeholder', (tester) async {
    await pumpDashboard(tester);

    await tester.tap(find.byKey(const Key('adminNav_bookings')));
    await tester.pump();

    expect(find.byType(ModulePlaceholderPage), findsNothing);
    expect(find.text('Coming soon'), findsNothing);
  });

  testWidgets('bookings uses the injected reservation repository', (
    tester,
  ) async {
    final repository = _RecordingStaffReservationRepository();
    await pumpDashboard(tester, staffReservationRepository: repository);

    await tester.tap(find.byKey(const Key('adminNav_bookings')));
    await tester.pumpAndSettle();

    expect(repository.listCalls, 1);
    expect(repository.lastRestaurantId, 'restaurant-id');
    expect(repository.lastBranchId, 'branch-id');
  });

  testWidgets('analytics and settings still show their placeholders', (
    tester,
  ) async {
    await pumpDashboard(tester);

    for (final section in [
      AdminDashboardSection.analytics,
      AdminDashboardSection.settings,
    ]) {
      await tester.tap(find.byKey(Key('adminNav_${section.name}')));
      await tester.pumpAndSettle();

      expect(find.byType(ModulePlaceholderPage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ModulePlaceholderPage),
          matching: find.text(section.label),
        ),
        findsOneWidget,
      );
      expect(find.text('Coming soon'), findsOneWidget);
    }
  });

  testWidgets('logout button is present', (tester) async {
    await pumpDashboard(tester);

    expect(find.byKey(const Key('dashboardSignOutButton')), findsOneWidget);
  });

  testWidgets('responsive navigation renders without errors', (tester) async {
    await pumpDashboard(tester, size: const Size(2560, 1440));

    expect(find.byKey(const Key('adminNav_dashboard')), findsOneWidget);
    expect(find.byKey(const Key('dashboardSignOutButton')), findsOneWidget);

    await pumpDashboard(tester, size: const Size(390, 844));

    expect(find.byKey(const Key('adminNav_dashboard')), findsNothing);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('adminNav_dashboard')), findsOneWidget);

    await tester.tap(find.byKey(const Key('adminNav_products')));
    await tester.pumpAndSettle();

    expect(find.byType(ProductsPage), findsOneWidget);
    expect(find.text('No products yet'), findsOneWidget);
  });

  testWidgets('orders is reachable from the mobile drawer too', (
    tester,
  ) async {
    await pumpDashboard(
      tester,
      size: const Size(390, 844),
      staffOrderRepository: const _EmptyStaffOrderRepository(),
    );

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('adminNav_orders')));
    await tester.pumpAndSettle();

    expect(find.byType(StaffOrdersPage), findsOneWidget);
    expect(find.text('No orders yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the success banner right after creating a restaurant', (
    tester,
  ) async {
    await pumpDashboard(tester, showCreationSuccess: true);

    expect(find.text('Restaurant created successfully'), findsOneWidget);
  });
}

class _EmptyCategoryRepository extends CategoryRepository {
  const _EmptyCategoryRepository();

  @override
  Future<List<CategoryModel>> getCategories(String restaurantId) async => [];
}

class _EmptyMenuItemRepository extends MenuItemRepository {
  const _EmptyMenuItemRepository();

  @override
  Future<List<MenuItemModel>> getMenuItems(String restaurantId) async => [];
}

/// The dashboard test needs no session and no database, so the orders list is handed
/// an empty restaurant rather than a real read.
class _EmptyStaffOrderRepository extends StaffOrderRepository {
  const _EmptyStaffOrderRepository();

  @override
  Future<List<StaffOrderModel>> getOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultLimit,
  }) async => [];

  @override
  Future<List<StaffOrderModel>> getActiveOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultActiveLimit,
  }) async => [];
}

/// Records the reads it is asked for, so a test can prove the repository the
/// dashboard was handed is the one the kitchen page used.
class _RecordingStaffOrderRepository extends StaffOrderRepository {
  _RecordingStaffOrderRepository();

  int listCalls = 0;
  String? lastRestaurantId;
  String? lastBranchId;

  @override
  Future<List<StaffOrderModel>> getOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultLimit,
  }) async {
    listCalls++;
    lastRestaurantId = restaurantId;
    lastBranchId = branchId;
    return [];
  }

  @override
  Future<List<StaffOrderModel>> getActiveOrders({
    required String restaurantId,
    String? branchId,
    int limit = StaffOrderRepository.defaultActiveLimit,
  }) => getOrders(restaurantId: restaurantId, branchId: branchId, limit: limit);
}

class _EmptyTableRepository extends TableRepository {
  const _EmptyTableRepository();

  @override
  Future<List<TableModel>> getTables(
    String restaurantId, {
    String? branchId,
  }) async => [];
}

class _FakeTableRepository extends TableRepository {
  _FakeTableRepository({List<TableModel>? initial}) : tables = initial ?? [];

  List<TableModel> tables;

  @override
  Future<List<TableModel>> getTables(
    String restaurantId, {
    String? branchId,
  }) async => tables;
}

/// The dashboard test needs no session and no database, so the staff list is handed
/// an empty restaurant rather than a real read.
class _EmptyStaffMemberRepository extends StaffMemberRepository {
  const _EmptyStaffMemberRepository();

  @override
  Future<List<StaffMemberModel>> getMembers({
    required String restaurantId,
  }) async => [];
}

/// Records the read it is asked for, so a test can prove the repository the dashboard
/// was handed is the one the staff page used.
class _RecordingStaffMemberRepository extends StaffMemberRepository {
  _RecordingStaffMemberRepository();

  int listCalls = 0;
  String? lastRestaurantId;

  @override
  Future<List<StaffMemberModel>> getMembers({
    required String restaurantId,
  }) async {
    listCalls++;
    lastRestaurantId = restaurantId;
    return [];
  }
}

/// The dashboard test needs no session and no database, so the bookings list is
/// handed an empty restaurant rather than a real read.
class _EmptyStaffReservationRepository extends StaffReservationRepository {
  const _EmptyStaffReservationRepository();

  @override
  Future<List<StaffReservationModel>> getReservations({
    required String restaurantId,
    String? branchId,
    DateTime? date,
    int limit = StaffReservationRepository.defaultLimit,
  }) async => [];
}

/// Records the reads it is asked for, so a test can prove the repository the
/// dashboard was handed is the one the bookings page used.
class _RecordingStaffReservationRepository extends StaffReservationRepository {
  _RecordingStaffReservationRepository();

  int listCalls = 0;
  String? lastRestaurantId;
  String? lastBranchId;

  @override
  Future<List<StaffReservationModel>> getReservations({
    required String restaurantId,
    String? branchId,
    DateTime? date,
    int limit = StaffReservationRepository.defaultLimit,
  }) async {
    listCalls++;
    lastRestaurantId = restaurantId;
    lastBranchId = branchId;
    return [];
  }
}