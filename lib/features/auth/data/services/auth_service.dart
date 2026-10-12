import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Provides email/password authentication through the shared Supabase client.
class AuthService {
  /// Creates an auth service backed by [SupabaseService]'s shared client.
  const AuthService() : _client = null;

  /// Creates an auth service with [client] for isolated tests.
  @visibleForTesting
  const AuthService.withClient(SupabaseClient client) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Registers a user with an email address and password.
  Future<AuthResponse> signUpWithEmail({
    required String email,
    required String password,
  }) {
    return _supabaseClient.auth.signUp(email: email, password: password);
  }

  /// Signs in an existing user with an email address and password.
  Future<AuthResponse> signInWithEmail({
    required String email,
    required String password,
  }) {
    return _supabaseClient.auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  /// Signs out the current user from this device.
  Future<void> signOut() => _supabaseClient.auth.signOut();

  /// Returns the locally stored user, if one is signed in.
  User? getCurrentUser() => _supabaseClient.auth.currentUser;

  /// Returns the locally stored session, if one is available.
  Session? getCurrentSession() => _supabaseClient.auth.currentSession;

  /// Emits Supabase authentication state changes.
  Stream<AuthState> get authStateChanges =>
      _supabaseClient.auth.onAuthStateChange;
}
