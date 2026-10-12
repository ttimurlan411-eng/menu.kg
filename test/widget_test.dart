import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/app/app.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/auth/data/services/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('Supabase initializes', () async {
    await SupabaseService.initialize();

    expect(SupabaseService.client, isA<SupabaseClient>());

    await Supabase.instance.dispose();
  });

  testWidgets('application starts', (WidgetTester tester) async {
    await tester.pumpWidget(
      MenukgApp(authService: _UnauthenticatedAuthService()),
    );

    expect(find.byType(MenukgApp), findsOneWidget);
  });
}

class _UnauthenticatedAuthService extends AuthService {
  @override
  User? getCurrentUser() => null;

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();
}
