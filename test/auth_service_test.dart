import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/auth/data/services/auth_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late SupabaseClient client;
  late AuthService authService;

  setUp(() {
    client = SupabaseClient('http://localhost:54321', 'test-anon-key');
    authService = AuthService.withClient(client);
  });

  tearDown(() => client.dispose());

  test('returns no user or session for a new local client', () {
    expect(authService.getCurrentUser(), isNull);
    expect(authService.getCurrentSession(), isNull);
  });

  test('exposes the Supabase auth state stream', () {
    expect(authService.authStateChanges, isA<Stream<AuthState>>());
  });

  test('signs out locally when no session exists', () async {
    final authState = authService.authStateChanges.first;

    await authService.signOut();

    expect((await authState).event, AuthChangeEvent.signedOut);
  });
}
