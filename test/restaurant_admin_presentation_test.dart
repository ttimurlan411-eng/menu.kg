import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/create_restaurant_page.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/pages/restaurant_home_page.dart';

void main() {
  test('normalizes and validates a restaurant slug', () {
    expect(normalizeRestaurantSlug('  Bishkek-Cafe  '), 'bishkek-cafe');
    expect(validateRestaurantSlug('bishkek-cafe'), isNull);
    expect(
      validateRestaurantSlug('bishkek cafe'),
      'Use lowercase letters, numbers, and hyphens only.',
    );
    expect(validateRestaurantSlug(''), 'Enter a restaurant slug.');
  });

  testWidgets('create restaurant page renders required fields and defaults', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: CreateRestaurantPage()));

    expect(find.byKey(const Key('restaurantNameField')), findsOneWidget);
    expect(find.byKey(const Key('restaurantSlugField')), findsOneWidget);
    expect(find.byKey(const Key('restaurantBranchNameField')), findsOneWidget);
    expect(find.text('KGS'), findsOneWidget);
    expect(find.text('ky'), findsOneWidget);
  });

  testWidgets('create restaurant page validates required fields', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: CreateRestaurantPage()));

    await tester.tap(find.byKey(const Key('createRestaurantSubmitButton')));
    await tester.pump();

    expect(find.text('Enter a restaurant name.'), findsOneWidget);
    expect(find.text('Enter a restaurant slug.'), findsOneWidget);
    expect(find.text('Enter a branch name.'), findsOneWidget);
  });

  testWidgets('create restaurant page validates a required branch name', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: CreateRestaurantPage()));

    await tester.enterText(
      find.byKey(const Key('restaurantNameField')),
      'Bishkek Cafe',
    );
    await tester.enterText(
      find.byKey(const Key('restaurantSlugField')),
      'bishkek-cafe',
    );
    await tester.tap(find.byKey(const Key('createRestaurantSubmitButton')));
    await tester.pump();

    expect(find.text('Enter a branch name.'), findsOneWidget);
  });

  testWidgets('restaurant home renders the selected restaurant', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: RestaurantHomePage(
          restaurantName: 'Bishkek Cafe',
          branchName: 'Main branch',
          role: 'OWNER',
          showCreationSuccess: true,
        ),
      ),
    );

    expect(find.text('Restaurant created successfully'), findsOneWidget);
    expect(find.text('Bishkek Cafe'), findsOneWidget);
    expect(find.text('Main branch'), findsOneWidget);
    expect(find.text('Role: OWNER'), findsOneWidget);
    expect(find.byKey(const Key('restaurantHomeSignOutButton')), findsOneWidget);
  });
}
