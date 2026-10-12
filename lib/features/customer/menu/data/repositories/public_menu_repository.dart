import 'package:flutter/foundation.dart';
import 'package:menukg_flutter/core/services/supabase_service.dart';
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reads the public customer menu for a table QR code.
///
/// Unlike the admin repositories this one intentionally works for signed-out
/// visitors: a guest scanning a printed QR code has no account. It therefore
/// never checks `auth.currentUser` and only calls the read-only
/// `public_menu_by_qr_token` function.
///
/// The repository never receives or sends a restaurant, branch or table id.
/// Everything it returns is scoped to the single table the token resolves to,
/// and the database applies the restaurant isolation, so a caller cannot ask
/// for another restaurant's menu.
class PublicMenuRepository {
  /// Creates a repository backed by [SupabaseService]'s shared client.
  const PublicMenuRepository() : _client = null;

  /// Creates a repository with [client] for isolated tests.
  @visibleForTesting
  const PublicMenuRepository.withClient(SupabaseClient client)
    : _client = client;

  /// Name of the public read-only database function.
  static const String functionName = 'public_menu_by_qr_token';

  final SupabaseClient? _client;

  SupabaseClient get _supabaseClient => _client ?? SupabaseService.client;

  /// Loads the menu for [qrToken].
  ///
  /// Returns `null` when the token is empty, malformed, unknown, or belongs to a
  /// table, branch or restaurant that is no longer active. Those cases are
  /// intentionally indistinguishable to a guest.
  ///
  /// Throws only on genuine transport or database failures, which the page
  /// renders as a safe, non-technical message.
  Future<PublicMenuModel?> getMenuByQrToken(String qrToken) async {
    final token = qrToken.trim();
    if (token.isEmpty) {
      return null;
    }

    final response = await _supabaseClient.rpc(
      functionName,
      params: {'p_qr_token': token},
    );

    return PublicMenuModel.tryParse(response);
  }
}