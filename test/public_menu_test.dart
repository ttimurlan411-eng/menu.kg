import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:menukg_flutter/app/router/app_router.dart';
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/repositories/public_menu_repository.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/pages/public_menu_page.dart';
import 'package:menukg_flutter/features/customer/menu/presentation/public_menu_error_message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/public_menu_test_data.dart';

Future<void> pumpPublicMenu(
  WidgetTester tester,
  PublicMenuRepository repository, {
  String qrToken = validQrToken,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      onGenerateRoute: AppRouter.onGenerateRoute,
      home: Builder(
        builder: (context) => PublicMenuPage(
          qrToken: qrToken,
          repository: repository,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('PublicMenuModel', () {
    test('parses the public payload without any internal ids', () {
      final menu = PublicMenuModel.fromJson(buildMenuJson());

      expect(menu.restaurant.name, 'Ala-Too');
      expect(menu.restaurant.currency, 'KGS');
      expect(menu.restaurant.defaultLanguage, 'ky');
      expect(menu.branch.name, 'Center');
      expect(menu.table.number, '12');
      expect(menu.categories, hasLength(2));
      expect(menu.itemCount, 3);
      expect(menu.allItems, hasLength(3));
      expect(menu.isEmpty, isFalse);

      final item = menu.allItems.first;
      expect(item.name, 'Beshbarmak');
      expect(item.description, 'Boiled lamb with noodles');
      expect(item.price, 450);
      expect(item.oldPrice, 500);
      expect(item.preparationTimeMinutes, 20);
    });

    test('table label reads as a guest-facing label', () {
      expect(
        PublicTableInfo.fromJson({'number': '12', 'name': 'Window'}).label,
        'Table 12 · Window',
      );
      expect(
        PublicTableInfo.fromJson({'number': '7', 'name': null}).label,
        'Table 7',
      );
      expect(
        PublicTableInfo.fromJson({'number': '7', 'name': '  '}).label,
        'Table 7',
      );
    });

    test('discount is only reported for a real markdown', () {
      expect(
        PublicMenuItemModel.fromJson({
          'id': 'a',
          'name': 'Soup',
          'price': 200,
          'old_price': 300,
        }).hasDiscount,
        isTrue,
      );
      expect(
        PublicMenuItemModel.fromJson({
          'id': 'a',
          'name': 'Soup',
          'price': 300,
          'old_price': 200,
        }).hasDiscount,
        isFalse,
      );
      expect(
        PublicMenuItemModel.fromJson({
          'id': 'a',
          'name': 'Free water',
          'price': 0,
          'old_price': 100,
        }).hasDiscount,
        isFalse,
      );
    });

    test('prices are always shown with two decimals and the currency', () {
      expect(formatPublicPrice(450, 'KGS'), '450.00 KGS');
      expect(formatPublicPrice(450.5, 'kgs'), '450.50 KGS');
      expect(formatPublicPrice(0, 'KGS'), '0.00 KGS');
    });

    test('tryParse maps anything unusable to null', () {
      expect(PublicMenuModel.tryParse(null), isNull);
      expect(PublicMenuModel.tryParse(''), isNull);
      expect(PublicMenuModel.tryParse('not json'), isNull);
      expect(PublicMenuModel.tryParse(42), isNull);
      expect(PublicMenuModel.tryParse(<String>[]), isNull);
      expect(PublicMenuModel.tryParse(buildMenuJson()), isNotNull);
      expect(
        PublicMenuModel.tryParse(jsonEncode(buildMenuJson()))?.restaurant.name,
        'Ala-Too',
      );
    });

    test('a menu with no categories reports itself as empty', () {
      final menu = PublicMenuModel.fromJson(
        buildMenuJson(categories: const []),
      );
      expect(menu.isEmpty, isTrue);
      expect(menu.itemCount, 0);
    });
  });

  group('AppRouter public route', () {
    test('the public url carries only the opaque token', () {
      final url = AppRouter.publicMenuUrl(validQrToken);

      expect(url, '${AppRouter.publicMenuBaseUrl}/$validQrToken');
      expect(url, contains(validQrToken));
      expect(url, isNot(contains('restaurant-')));
      expect(url, isNot(contains('branch-')));
      expect(url, isNot(contains('table-')));
    });

    test('tokens are trimmed and url encoded', () {
      expect(AppRouter.publicMenuRoute('  abc  '), '/t/abc');
      expect(
        AppRouter.publicMenuUrl('a b'),
        '${AppRouter.publicMenuBaseUrl}/a%20b',
      );
    });

    test('the printed qr path is the path the app serves', () {
      // The QR image prints <base>/<token> and the app serves /t/<token>.
      final printed = Uri.parse(AppRouter.publicMenuUrl(validQrToken));
      expect(printed.path, AppRouter.publicMenuRoute(validQrToken));
      expect(
        AppRouter.parsePublicMenuQrToken(printed.path),
        validQrToken,
      );
    });

    test('parses the token out of the public path', () {
      expect(AppRouter.parsePublicMenuQrToken('/t/$validQrToken'), validQrToken);
      expect(AppRouter.parsePublicMenuQrToken('/t/a%20b'), 'a b');
    });

    test('refuses paths that are not a public menu', () {
      expect(AppRouter.parsePublicMenuQrToken(null), isNull);
      expect(AppRouter.parsePublicMenuQrToken('/'), isNull);
      expect(AppRouter.parsePublicMenuQrToken('/t'), isNull);
      expect(AppRouter.parsePublicMenuQrToken('/t/'), isNull);
      expect(AppRouter.parsePublicMenuQrToken('/admin/tables'), isNull);
      expect(AppRouter.parsePublicMenuQrToken('/menu/$validQrToken'), isNull);
      expect(
        AppRouter.parsePublicMenuQrToken('/t/$validQrToken/extra'),
        isNull,
      );
    });

    test('onGenerateRoute serves /t/<token> and ignores everything else', () {
      expect(
        AppRouter.onGenerateRoute(
          const RouteSettings(name: '/t/$validQrToken'),
        ),
        isA<MaterialPageRoute<void>>(),
      );
      expect(
        AppRouter.onGenerateRoute(const RouteSettings(name: '/')),
        isNull,
      );
      expect(
        AppRouter.onGenerateRoute(
          const RouteSettings(name: '/admin/tables'),
        ),
        isNull,
      );
    });

    testWidgets('the public page is reachable from the router while signed out', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: const Scaffold(body: Text('auth gate placeholder')),
        ),
      );

      unawaited(navigatorKey.currentState!.pushNamed('/t/$validQrToken'));
      await tester.pumpAndSettle();

      // The public menu replaced the auth gate without any sign-in step.
      expect(find.byType(PublicMenuPage), findsOneWidget);
      expect(find.text('auth gate placeholder'), findsNothing);
    });
  });

  group('PublicMenuRepository', () {
    test('resolves a token through the public rpc without a session', () async {
      late Map<String, dynamic> sentBody;
      final httpClient = RecordingHttpClient((request, body) async {
        sentBody = jsonDecode(body!) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(buildMenuJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      // No user is signed in: a guest scanning a QR code has no account.
      expect(client.auth.currentUser, isNull);

      final repository = PublicMenuRepository.withClient(client);
      final menu = await repository.getMenuByQrToken(validQrToken);

      expect(httpClient.requests.single.url.path, contains(
        '/rpc/${PublicMenuRepository.functionName}',
      ));
      expect(httpClient.requests.single.method, 'POST');
      expect(sentBody, {'p_qr_token': validQrToken});
      expect(menu?.restaurant.name, 'Ala-Too');
      expect(menu?.itemCount, 3);
    });

    test('never sends a restaurant, branch or table id', () async {
      Map<String, dynamic>? sentBody;
      final httpClient = RecordingHttpClient((request, body) async {
        sentBody = jsonDecode(body!) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(buildMenuJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      await PublicMenuRepository.withClient(
        client,
      ).getMenuByQrToken(validQrToken);

      expect(sentBody!.keys, ['p_qr_token']);
      expect(sentBody!.containsKey('restaurant_id'), isFalse);
      expect(sentBody!.containsKey('branch_id'), isFalse);
      expect(sentBody!.containsKey('table_id'), isFalse);
    });

    test('an unknown, deleted or inactive token resolves to null', () async {
      final httpClient = RecordingHttpClient((request, body) async {
        return http.Response(
          'null',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      final menu = await PublicMenuRepository.withClient(
        client,
      ).getMenuByQrToken(validQrToken);

      expect(menu, isNull);
    });

    test('a blank token never reaches the database', () async {
      final httpClient = RecordingHttpClient(
        (request, body) async => http.Response('null', 200),
      );
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      final repository = PublicMenuRepository.withClient(client);

      expect(await repository.getMenuByQrToken(''), isNull);
      expect(await repository.getMenuByQrToken('   '), isNull);
      expect(httpClient.requests, isEmpty);
    });

    test('database failures surface as errors for the page to map', () async {
      final httpClient = RecordingHttpClient((request, body) async {
        return http.Response(
          jsonEncode({
            'code': '42501',
            'message': 'permission denied for function',
            'details': null,
            'hint': null,
          }),
          401,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = buildSupabaseTestClient(httpClient);
      addTearDown(client.dispose);

      await expectLater(
        PublicMenuRepository.withClient(client).getMenuByQrToken(validQrToken),
        throwsA(isA<PostgrestException>()),
      );
    });
  });

  group('PublicMenuPage', () {
    testWidgets('renders the restaurant, branch, table, categories and items', (
      tester,
    ) async {
      await pumpPublicMenu(
        tester,
        FakePublicMenuRepository(buildMenuJson()),
      );

      expect(find.text('Ala-Too'), findsOneWidget);
      expect(find.text('Center · Table 12 · Window'), findsOneWidget);
      expect(find.text('Kyrgyz and European cuisine'), findsOneWidget);
      expect(find.text('Starters'), findsOneWidget);
      expect(find.text('Mains'), findsOneWidget);
      expect(find.text('Beshbarmak'), findsOneWidget);
      expect(find.text('Boiled lamb with noodles'), findsOneWidget);
      expect(find.text('Kebab'), findsOneWidget);
    });

    testWidgets('never shows table, restaurant or branch ids', (tester) async {
      await pumpPublicMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      // Nothing on screen may contain an internal identifier.
      for (final id in const [
        'category-1',
        'category-2',
        'item-1',
        'item-3',
      ]) {
        expect(find.textContaining(id), findsNothing);
      }
      expect(find.textContaining(validQrToken), findsNothing);
    });

    testWidgets('shows prices, strikethrough old prices and item counts', (
      tester,
    ) async {
      await pumpPublicMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      expect(find.byKey(const Key('menuItemPrice_item-1')), findsOneWidget);
      expect(find.text('450.00 KGS'), findsOneWidget);
      expect(find.text('500.00 KGS'), findsOneWidget);
      expect(find.text('Starters · 2 items · 250.00 KGS'), findsOneWidget);
      expect(find.text('Mains · 1 item · 600.00 KGS'), findsOneWidget);
    });

    testWidgets('filters the menu by category', (tester) async {
      await pumpPublicMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      await tester.tap(find.byKey(const Key('categoryChip_category-2')));
      await tester.pumpAndSettle();

      // Only the selected category's section header and items remain. The chip
      // labels still list every category, so headers are matched by their full
      // "name · count · from price" text.
      expect(find.text('Mains · 1 item · 600.00 KGS'), findsOneWidget);
      expect(find.textContaining('Starters ·'), findsNothing);
      expect(find.text('Kebab'), findsOneWidget);
      expect(find.text('Beshbarmak'), findsNothing);
      expect(find.text('Fresh Salad'), findsNothing);

      await tester.tap(find.byKey(const Key('categoryChip_all')));
      await tester.pumpAndSettle();

      expect(find.text('Beshbarmak'), findsOneWidget);
      expect(find.text('Kebab'), findsOneWidget);
    });

    testWidgets('an unknown or invalid token shows a safe message', (
      tester,
    ) async {
      await pumpPublicMenu(
        tester,
        FakePublicMenuRepository(buildMenuJson(), resolvesToNothing: true),
      );

      expect(find.byKey(const Key('publicMenuErrorMessage')), findsOneWidget);
      expect(
        find.text('This menu is not available right now.'),
        findsOneWidget,
      );
      expect(find.textContaining('exception'), findsNothing);
      expect(find.textContaining('SQL'), findsNothing);
      expect(find.textContaining('uuid'), findsNothing);
      expect(find.byType(PublicMenuPage), findsOneWidget);
    });

    testWidgets('a menu with no available items shows an empty state', (
      tester,
    ) async {
      await pumpPublicMenu(
        tester,
        FakePublicMenuRepository(buildMenuJson(categories: const [])),
      );

      expect(find.byKey(const Key('publicMenuEmptyMessage')), findsOneWidget);
      expect(
        find.text('The menu is being updated. Please check back shortly.'),
        findsOneWidget,
      );
      // The restaurant is still identified even with an empty menu.
      expect(find.text('Ala-Too'), findsOneWidget);
    });

    testWidgets('database failures show a safe message and can retry', (
      tester,
    ) async {
      final repository = FakePublicMenuRepository(
        buildMenuJson(),
        failuresRemaining: 1,
      );
      await pumpPublicMenu(tester, repository);

      expect(
        find.text('We could not load this menu. Please try again.'),
        findsOneWidget,
      );

      repository.failuresRemaining = 0;
      await tester.tap(find.byKey(const Key('publicMenuRetryButton')));
      await tester.pumpAndSettle();

      expect(find.text('Beshbarmak'), findsOneWidget);
    });

    testWidgets('a revoked public function is reported without internals', (
      tester,
    ) async {
      await pumpPublicMenu(
        tester,
        FakePublicMenuRepository(
          buildMenuJson(),
          error: const PostgrestException(
            message: 'permission denied for function public_menu_by_qr_token',
            code: '42501',
          ),
        ),
      );

      expect(
        find.text('This menu is not available right now.'),
        findsOneWidget,
      );
      expect(find.textContaining('permission denied'), findsNothing);
      expect(find.textContaining('public_menu_by_qr_token'), findsNothing);
    });

    testWidgets('shows a loading state while the menu is fetched', (
      tester,
    ) async {
      final completer = Completer<PublicMenuModel?>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PublicMenuPage(
              qrToken: validQrToken,
              repository: PendingPublicMenuRepository(completer),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Loading menu...'), findsOneWidget);

      completer.complete(PublicMenuModel.fromJson(buildMenuJson()));
      await tester.pumpAndSettle();
      expect(find.text('Beshbarmak'), findsOneWidget);
    });

    testWidgets('requests the menu for the scanned token', (tester) async {
      final repository = FakePublicMenuRepository(buildMenuJson());
      await pumpPublicMenu(tester, repository);

      expect(repository.requestedTokens, contains(validQrToken));
      expect(
        repository.requestedTokens.every((token) => token == validQrToken),
        isTrue,
      );
    });

    testWidgets('offers a local cart but no ordering or account action', (
      tester,
    ) async {
      await pumpPublicMenu(tester, FakePublicMenuRepository(buildMenuJson()));

      // The menu opens a local cart for this table and nothing else: the count
      // is hidden while the cart is empty, and no AppBar crowds the small screen.
      expect(find.byKey(const Key('cartButton')), findsOneWidget);
      expect(find.byIcon(Icons.shopping_cart_outlined), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      // Nothing is ordered, checked out or signed in to.
      expect(find.textContaining('Add to cart'), findsNothing);
      expect(find.textContaining('Checkout'), findsNothing);
      expect(find.textContaining('Sign in'), findsNothing);
    });
  });

  group('public menu error messages', () {
    test('never leak database internals', () {
      expect(
        publicMenuErrorMessage(
          const PostgrestException(
            message: 'invalid input syntax for type uuid',
            code: '22P02',
          ),
        ),
        'This QR code is not valid.',
      );
      expect(
        publicMenuErrorMessage(
          const PostgrestException(
            message: 'permission denied for function',
            code: '42501',
          ),
        ),
        'This menu is not available right now.',
      );
      expect(
        publicMenuErrorMessage(
          const PostgrestException(
            message: 'JWT expired',
            code: '28000',
          ),
        ),
        'This menu is not available right now.',
      );
      expect(
        publicMenuErrorMessage(
          const PostgrestException(
            message:
                'relation "public.tables" does not exist at public_menu_by_qr_token',
          ),
        ),
        'We could not load this menu. Please try again.',
      );
      expect(
        publicMenuErrorMessage(StateError('boom')),
        'We could not load this menu. Please try again.',
      );
      expect(
        publicMenuErrorMessage(
          const PublicMenuUnavailableException('This QR code is not valid.'),
        ),
        'This QR code is not valid.',
      );
    });
  });
}
