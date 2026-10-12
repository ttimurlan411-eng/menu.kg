import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_member_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_member_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/staff_members_page.dart';

import 'support/staff_member_test_data.dart';
import 'support/staff_order_test_data.dart';

class _FakeStaffMemberRepository extends StaffMemberRepository {
  _FakeStaffMemberRepository({
    List<StaffMemberModel>? members,
    this.failuresRemaining = 0,
  }) : members = members ?? const [];

  List<StaffMemberModel> members;
  int failuresRemaining;
  int calls = 0;
  String? lastRestaurantId;

  @override
  Future<List<StaffMemberModel>> getMembers({required String restaurantId}) async {
    calls++;
    lastRestaurantId = restaurantId;
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('network down');
    }
    return members;
  }
}

class _PendingStaffMemberRepository extends StaffMemberRepository {
  _PendingStaffMemberRepository(this.completer);

  final Completer<List<StaffMemberModel>> completer;

  @override
  Future<List<StaffMemberModel>> getMembers({required String restaurantId}) {
    return completer.future;
  }
}

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required String role,
    required StaffMemberRepository repository,
    String restaurantId = restaurantA,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StaffMembersPage(
          restaurantId: restaurantId,
          role: role,
          repository: repository,
        ),
      ),
    );
  }

  group('staffRoleManagesMembers', () {
    test('owners and managers may manage members', () {
      for (final role in ['OWNER', 'MANAGER', 'owner', ' manager ']) {
        expect(staffRoleManagesMembers(role), isTrue, reason: '$role may manage');
      }
    });

    test('every other role may not', () {
      for (final role in ['WAITER', 'KITCHEN', 'CASHIER', '', '  ', 'OWNER ']) {
        final expected = role.trim().toUpperCase() == 'OWNER';
        expect(
          staffRoleManagesMembers(role),
          expected,
          reason: '$role: only owner and manager may manage',
        );
      }
    });
  });

  testWidgets('an owner sees a loading indicator then the member list', (
    tester,
  ) async {
    final repository = _FakeStaffMemberRepository(
      members: [
        buildStaffMemberModel(displayName: 'Aigerim Owner', role: 'OWNER'),
        buildStaffMemberModel(
          id: managedMemberId,
          userId: managedMemberUserId,
          displayName: 'Bakyt Manager',
          role: 'MANAGER',
        ),
      ],
    );

    await pumpPage(tester, role: 'OWNER', repository: repository);

    expect(find.byKey(const Key('staffMembersLoading')), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('Aigerim Owner'), findsOneWidget);
    expect(find.text('Bakyt Manager'), findsOneWidget);
    expect(find.text('OWNER'), findsOneWidget);
    expect(find.text('MANAGER'), findsOneWidget);
    expect(repository.calls, 1);
    expect(repository.lastRestaurantId, restaurantA);
  });

  testWidgets('a manager may view the member list', (tester) async {
    final repository = _FakeStaffMemberRepository(
      members: [buildStaffMemberModel(role: 'OWNER')],
    );

    await pumpPage(tester, role: 'MANAGER', repository: repository);
    await tester.pumpAndSettle();

    expect(find.text('Aigerim Owner'), findsOneWidget);
    expect(find.byKey(const Key('staffMembersRestricted')), findsNothing);
    expect(repository.calls, 1);
  });

  testWidgets('an empty member list shows the empty state', (tester) async {
    final repository = _FakeStaffMemberRepository(members: const []);

    await pumpPage(tester, role: 'OWNER', repository: repository);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('staffMembersEmpty')), findsOneWidget);
    expect(find.text('No staff members yet'), findsOneWidget);
  });

  testWidgets('a nameless member and an inactive member are shown as such', (
    tester,
  ) async {
    final repository = _FakeStaffMemberRepository(
      members: [
        buildStaffMemberModel(displayName: null, role: 'WAITER'),
        buildStaffMemberModel(
          id: managedMemberId,
          userId: managedMemberUserId,
          displayName: 'Nurlan Inactive',
          role: 'WAITER',
          isActive: false,
        ),
      ],
    );

    await pumpPage(tester, role: 'OWNER', repository: repository);
    await tester.pumpAndSettle();

    expect(find.text('Unnamed staff member'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Inactive'), findsOneWidget);
  });

  testWidgets('a failed read shows the error state and a retry recovers', (
    tester,
  ) async {
    final repository = _FakeStaffMemberRepository(
      members: [buildStaffMemberModel()],
      failuresRemaining: 1,
    );

    await pumpPage(tester, role: 'OWNER', repository: repository);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('staffMembersError')), findsOneWidget);
    expect(
      find.text('We could not load staff members. Please try again.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('staffMembersRetryButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('staffMembersError')), findsNothing);
    expect(find.text('Aigerim Owner'), findsOneWidget);
    expect(repository.calls, 2);
  });

  testWidgets('the refresh button re-reads the list', (tester) async {
    final repository = _FakeStaffMemberRepository(
      members: [buildStaffMemberModel(displayName: 'First')],
    );

    await pumpPage(tester, role: 'OWNER', repository: repository);
    await tester.pumpAndSettle();

    expect(find.text('First'), findsOneWidget);

    repository.members = [buildStaffMemberModel(displayName: 'Second')];

    await tester.tap(find.byKey(const Key('staffMembersRefreshButton')));
    await tester.pumpAndSettle();

    expect(find.text('Second'), findsOneWidget);
    expect(find.text('First'), findsNothing);
    expect(repository.calls, 2);
  });

  testWidgets('a pending read keeps the loading state', (tester) async {
    final completer = Completer<List<StaffMemberModel>>();
    final repository = _PendingStaffMemberRepository(completer);

    await pumpPage(tester, role: 'OWNER', repository: repository);

    expect(find.byKey(const Key('staffMembersLoading')), findsOneWidget);
  });

  testWidgets('roles that may not manage members see a clear explanation', (
    tester,
  ) async {
    for (final role in ['WAITER', 'KITCHEN', 'CASHIER']) {
      final repository = _FakeStaffMemberRepository(
        members: [buildStaffMemberModel()],
      );

      await pumpPage(tester, role: role, repository: repository);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('staffMembersRestricted')),
        findsOneWidget,
        reason: '$role is refused the list',
      );
      expect(
        find.text('Only owners and managers can view staff members.'),
        findsOneWidget,
      );
      expect(
        repository.calls,
        0,
        reason: '$role never reaches the database read',
      );
      expect(find.byKey(const Key('staffMembersError')), findsNothing);
    }
  });
}
