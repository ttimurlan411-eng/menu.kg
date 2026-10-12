import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/auth/data/models/restaurant_membership_model.dart';
import 'package:menukg_flutter/features/auth/data/models/restaurant_summary_model.dart';
import 'package:menukg_flutter/features/auth/data/repositories/restaurant_membership_repository.dart';
import 'package:menukg_flutter/features/auth/data/repositories/restaurant_repository.dart';
import 'package:menukg_flutter/features/auth/data/services/auth_service.dart';
import 'package:menukg_flutter/features/auth/presentation/pages/auth_gate.dart';
import 'package:menukg_flutter/features/auth/presentation/pages/login_page.dart';
import 'package:menukg_flutter/features/auth/presentation/pages/register_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/create_restaurant_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/restaurant_dashboard_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('login form validates required email and password', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));

    await tester.tap(find.byKey(const Key('loginSubmitButton')));
    await tester.pump();

    expect(find.text('Enter your email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
  });

  testWidgets('register form validates all required fields', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RegisterPage()));

    await tester.tap(find.byKey(const Key('registerSubmitButton')));
    await tester.pump();

    expect(find.text('Enter your email address.'), findsOneWidget);
    expect(find.text('Enter a password.'), findsOneWidget);
    expect(find.text('Confirm your password.'), findsOneWidget);
  });

  testWidgets('register form validates matching passwords', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RegisterPage()));

    await tester.enterText(
      find.byKey(const Key('registerEmailField')),
      'owner@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('registerPasswordField')),
      'password-one',
    );
    await tester.enterText(
      find.byKey(const Key('registerConfirmPasswordField')),
      'password-two',
    );
    await tester.tap(find.byKey(const Key('registerSubmitButton')));
    await tester.pump();

    expect(find.text('Passwords do not match.'), findsOneWidget);
  });

  testWidgets('auth gate shows restaurant creation for a new user', (
    tester,
  ) async {
    final authService = FakeAuthService();
    addTearDown(authService.dispose);
    final membershipRepository = FakeRestaurantMembershipRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: AuthGate(
          authService: authService,
          membershipRepository: membershipRepository,
        ),
      ),
    );
    expect(find.byType(LoginPage), findsOneWidget);

    authService.emit(
      AuthState(
        AuthChangeEvent.signedIn,
        Session(
          accessToken: 'test-token',
          tokenType: 'bearer',
          user: _testUser,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(CreateRestaurantPage), findsOneWidget);

    authService.emit(const AuthState(AuthChangeEvent.signedOut, null));
    await tester.pump();
    await tester.pump();

    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('an active WAITER membership reaches the dashboard', (
    tester,
  ) async {
    final authService = FakeAuthService();
    addTearDown(authService.dispose);
    final membershipRepository = FakeRestaurantMembershipRepository(
      memberships: [_membership(role: 'WAITER', restaurantId: 'restaurant-waiter')],
    );
    final restaurantRepository = FakeRestaurantRepository(
      summary: const RestaurantSummaryModel(
        id: 'restaurant-waiter',
        name: 'Ala-Too',
        branchName: 'Main',
      ),
    );

    await _pumpSignedInAuthGate(
      tester,
      authService: authService,
      membershipRepository: membershipRepository,
      restaurantRepository: restaurantRepository,
    );

    expect(find.byType(RestaurantDashboardPage), findsOneWidget);
    expect(find.byType(CreateRestaurantPage), findsNothing);
    expect(restaurantRepository.requestedRestaurantIds, ['restaurant-waiter']);
    expect(authService.getCurrentUser()?.id, _testUser.id);
  });

  testWidgets('an active KITCHEN membership reaches the dashboard', (
    tester,
  ) async {
    final authService = FakeAuthService();
    addTearDown(authService.dispose);
    final membershipRepository = FakeRestaurantMembershipRepository(
      memberships: [
        _membership(role: 'KITCHEN', restaurantId: 'restaurant-kitchen'),
      ],
    );
    final restaurantRepository = FakeRestaurantRepository(
      summary: const RestaurantSummaryModel(
        id: 'restaurant-kitchen',
        name: 'Ala-Too',
        branchName: 'Main',
      ),
    );

    await _pumpSignedInAuthGate(
      tester,
      authService: authService,
      membershipRepository: membershipRepository,
      restaurantRepository: restaurantRepository,
    );

    expect(find.byType(RestaurantDashboardPage), findsOneWidget);
    expect(find.byType(CreateRestaurantPage), findsNothing);
    expect(restaurantRepository.requestedRestaurantIds, ['restaurant-kitchen']);
  });

  testWidgets('a CASHIER-only membership reaches the dashboard instead of the creation form', (
    tester,
  ) async {
    final authService = FakeAuthService();
    addTearDown(authService.dispose);
    final membershipRepository = FakeRestaurantMembershipRepository(
      memberships: [
        _membership(role: 'CASHIER', restaurantId: 'restaurant-cashier'),
      ],
    );
    final restaurantRepository = FakeRestaurantRepository(
      summary: const RestaurantSummaryModel(
        id: 'restaurant-cashier',
        name: 'Ala-Too',
        branchName: 'Main',
      ),
    );

    await _pumpSignedInAuthGate(
      tester,
      authService: authService,
      membershipRepository: membershipRepository,
      restaurantRepository: restaurantRepository,
    );

    expect(find.byType(RestaurantDashboardPage), findsOneWidget);
    expect(find.byType(CreateRestaurantPage), findsNothing);
    expect(restaurantRepository.requestedRestaurantIds, ['restaurant-cashier']);
  });

  testWidgets('an OWNER membership wins over order roles regardless of list order', (
    tester,
  ) async {
    final authService = FakeAuthService();
    addTearDown(authService.dispose);
    final membershipRepository = FakeRestaurantMembershipRepository(
      memberships: [
        _membership(role: 'WAITER', restaurantId: 'restaurant-waiter'),
        _membership(role: 'KITCHEN', restaurantId: 'restaurant-kitchen'),
        _membership(role: 'OWNER', restaurantId: 'restaurant-owner'),
      ],
    );
    final restaurantRepository = FakeRestaurantRepository(
      summary: const RestaurantSummaryModel(
        id: 'restaurant-owner',
        name: 'Ala-Too',
        branchName: 'Main',
      ),
    );

    await _pumpSignedInAuthGate(
      tester,
      authService: authService,
      membershipRepository: membershipRepository,
      restaurantRepository: restaurantRepository,
    );

    expect(find.byType(RestaurantDashboardPage), findsOneWidget);
    expect(restaurantRepository.requestedRestaurantIds, ['restaurant-owner']);
  });

  testWidgets('a MANAGER membership wins over a KITCHEN membership', (
    tester,
  ) async {
    final authService = FakeAuthService();
    addTearDown(authService.dispose);
    final membershipRepository = FakeRestaurantMembershipRepository(
      memberships: [
        _membership(role: 'KITCHEN', restaurantId: 'restaurant-kitchen'),
        _membership(role: 'MANAGER', restaurantId: 'restaurant-manager'),
      ],
    );
    final restaurantRepository = FakeRestaurantRepository(
      summary: const RestaurantSummaryModel(
        id: 'restaurant-manager',
        name: 'Ala-Too',
        branchName: 'Main',
      ),
    );

    await _pumpSignedInAuthGate(
      tester,
      authService: authService,
      membershipRepository: membershipRepository,
      restaurantRepository: restaurantRepository,
    );

    expect(find.byType(RestaurantDashboardPage), findsOneWidget);
    expect(restaurantRepository.requestedRestaurantIds, ['restaurant-manager']);
  });

  testWidgets('an order role wins over a CASHIER membership', (tester) async {
    final authService = FakeAuthService();
    addTearDown(authService.dispose);
    final membershipRepository = FakeRestaurantMembershipRepository(
      memberships: [
        _membership(role: 'CASHIER', restaurantId: 'restaurant-cashier'),
        _membership(role: 'KITCHEN', restaurantId: 'restaurant-kitchen'),
      ],
    );
    final restaurantRepository = FakeRestaurantRepository(
      summary: const RestaurantSummaryModel(
        id: 'restaurant-kitchen',
        name: 'Ala-Too',
        branchName: 'Main',
      ),
    );

    await _pumpSignedInAuthGate(
      tester,
      authService: authService,
      membershipRepository: membershipRepository,
      restaurantRepository: restaurantRepository,
    );

    expect(find.byType(RestaurantDashboardPage), findsOneWidget);
    expect(restaurantRepository.requestedRestaurantIds, ['restaurant-kitchen']);
  });

  testWidgets('inactive memberships are never chosen', (tester) async {
    final authService = FakeAuthService();
    addTearDown(authService.dispose);
    final membershipRepository = FakeRestaurantMembershipRepository(
      memberships: [
        _membership(role: 'OWNER', isActive: false, restaurantId: 'restaurant-a'),
        _membership(role: 'WAITER', isActive: true, restaurantId: 'restaurant-b'),
      ],
    );
    final restaurantRepository = FakeRestaurantRepository(
      summary: const RestaurantSummaryModel(
        id: 'restaurant-b',
        name: 'Ala-Too',
        branchName: 'Main',
      ),
    );

    await _pumpSignedInAuthGate(
      tester,
      authService: authService,
      membershipRepository: membershipRepository,
      restaurantRepository: restaurantRepository,
    );

    expect(find.byType(RestaurantDashboardPage), findsOneWidget);
    expect(restaurantRepository.requestedRestaurantIds, ['restaurant-b']);
  });

  testWidgets('a signed-in user with only inactive memberships keeps the creation form', (
    tester,
  ) async {
    final authService = FakeAuthService();
    addTearDown(authService.dispose);
    final membershipRepository = FakeRestaurantMembershipRepository(
      memberships: [
        _membership(role: 'OWNER', isActive: false),
        _membership(role: 'KITCHEN', isActive: false),
      ],
    );
    final restaurantRepository = FakeRestaurantRepository();

    await _pumpSignedInAuthGate(
      tester,
      authService: authService,
      membershipRepository: membershipRepository,
      restaurantRepository: restaurantRepository,
    );

    expect(find.byType(CreateRestaurantPage), findsOneWidget);
    expect(find.byType(RestaurantDashboardPage), findsNothing);
    expect(restaurantRepository.summaryCalls, 0);
  });

  testWidgets('an unreadable restaurant shows the restaurant access error', (
    tester,
  ) async {
    final authService = FakeAuthService();
    addTearDown(authService.dispose);
    final membershipRepository = FakeRestaurantMembershipRepository(
      memberships: [_membership(role: 'KITCHEN', restaurantId: 'restaurant-hidden')],
    );
    final restaurantRepository = FakeRestaurantRepository(summary: null);

    await _pumpSignedInAuthGate(
      tester,
      authService: authService,
      membershipRepository: membershipRepository,
      restaurantRepository: restaurantRepository,
    );

    expect(
      find.text('We could not load your restaurant. Please try again.'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(CreateRestaurantPage), findsNothing);
  });
}

final _testUser = User(
  id: 'test-user-id',
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  email: 'owner@example.com',
  createdAt: '2026-09-19T00:00:00.000Z',
);

RestaurantMembershipModel _membership({
  String role = 'OWNER',
  bool isActive = true,
  String restaurantId = 'restaurant-1',
}) {
  return RestaurantMembershipModel(
    id: 'membership-1',
    restaurantId: restaurantId,
    userId: _testUser.id,
    role: role,
    isActive: isActive,
    createdAt: DateTime.utc(2026, 9, 1),
    updatedAt: DateTime.utc(2026, 9, 1),
  );
}

Future<void> _pumpSignedInAuthGate(
  WidgetTester tester, {
  required FakeAuthService authService,
  required FakeRestaurantMembershipRepository membershipRepository,
  required FakeRestaurantRepository restaurantRepository,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AuthGate(
        authService: authService,
        membershipRepository: membershipRepository,
        restaurantRepository: restaurantRepository,
      ),
    ),
  );
  expect(find.byType(LoginPage), findsOneWidget);

  authService.emit(
    AuthState(
      AuthChangeEvent.signedIn,
      Session(
        accessToken: 'test-token',
        tokenType: 'bearer',
        user: _testUser,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

class FakeAuthService extends AuthService {
  FakeAuthService({this.currentUser});

  User? currentUser;
  final StreamController<AuthState> _authStateController =
      StreamController<AuthState>.broadcast();

  @override
  User? getCurrentUser() => currentUser;

  @override
  Stream<AuthState> get authStateChanges => _authStateController.stream;

  void emit(AuthState authState) {
    currentUser = authState.session?.user;
    _authStateController.add(authState);
  }

  Future<void> dispose() => _authStateController.close();
}

class FakeRestaurantMembershipRepository extends RestaurantMembershipRepository {
  FakeRestaurantMembershipRepository({this.memberships = const []});

  final List<RestaurantMembershipModel> memberships;

  @override
  Future<List<RestaurantMembershipModel>> getMyMemberships() async => memberships;
}

class FakeRestaurantRepository extends RestaurantRepository {
  FakeRestaurantRepository({this.summary});

  RestaurantSummaryModel? summary;
  int summaryCalls = 0;
  final List<String> requestedRestaurantIds = [];

  @override
  Future<RestaurantSummaryModel?> getRestaurantSummary(
    String restaurantId,
  ) async {
    summaryCalls++;
    requestedRestaurantIds.add(restaurantId);
    return summary;
  }
}
