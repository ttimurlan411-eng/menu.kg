import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/auth/data/models/profile_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads and updates profiles available to the authenticated user.
class ProfileRepository {
  /// Creates a repository backed by [SupabaseService]'s shared client.
  const ProfileRepository() : _client = null;

  /// Creates a repository with [client] for isolated tests.
  @visibleForTesting
  const ProfileRepository.withClient(SupabaseClient client) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Returns the current authenticated user's profile, if available.
  Future<ProfileModel?> getCurrentProfile() {
    final userId = _supabaseClient.auth.currentUser?.id;
    if (userId == null) {
      return Future<ProfileModel?>.value(null);
    }

    return getProfileByUserId(userId);
  }

  /// Returns a profile visible to the current authenticated user.
  Future<ProfileModel?> getProfileByUserId(String userId) async {
    if (_supabaseClient.auth.currentUser == null) {
      return null;
    }

    final profile = await _supabaseClient
        .from('profiles')
        .select()
        .eq('id', userId)
        .maybeSingle();

    return profile == null ? null : ProfileModel.fromJson(profile);
  }

  /// Updates the current authenticated user's profile and returns the result.
  Future<ProfileModel?> updateCurrentProfile(ProfileModel profile) async {
    final userId = _supabaseClient.auth.currentUser?.id;
    if (userId == null) {
      return null;
    }

    final updatedProfile = await _supabaseClient
        .from('profiles')
        .update(profile.toUpdateJson())
        .eq('id', userId)
        .select()
        .maybeSingle();

    return updatedProfile == null
        ? null
        : ProfileModel.fromJson(updatedProfile);
  }
}
