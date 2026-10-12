import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:menukg_flutter/features/customer/menu/data/models/public_menu_model.dart';
import 'package:menukg_flutter/features/customer/menu/data/repositories/public_menu_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A valid opaque token shaped exactly like a database generated one.
const String validQrToken = '3f0b2a1c-9d4e-4f7a-8b6c-1d2e3f4a5b6c';

/// Builds the json the public `public_menu_by_qr_token` rpc returns.
Map<String, dynamic> buildMenuJson({
  String restaurantName = 'Ala-Too',
  List<Map<String, dynamic>>? categories,
}) {
  return {
    'restaurant': {
      'name': restaurantName,
      'logo_url': null,
      'cover_url': null,
      'description': 'Kyrgyz and European cuisine',
      'currency': 'KGS',
      'default_language': 'ky',
    },
    'branch': {'name': 'Center'},
    'table': {'number': '12', 'name': 'Window'},
    'categories': categories ??
        [
          {
            'id': 'category-1',
            'name': 'Starters',
            'description': null,
            'image_url': null,
            'items': [
              {
                'id': 'item-1',
                'name': 'Beshbarmak',
                'description': 'Boiled lamb with noodles',
                'price': 450,
                'old_price': 500,
                'main_image_url': null,
                'preparation_time_minutes': 20,
              },
              {
                'id': 'item-2',
                'name': 'Fresh Salad',
                'description': null,
                'price': 250,
                'old_price': null,
                'main_image_url': null,
                'preparation_time_minutes': 5,
              },
            ],
          },
          {
            'id': 'category-2',
            'name': 'Mains',
            'description': null,
            'image_url': null,
            'items': [
              {
                'id': 'item-3',
                'name': 'Kebab',
                'description': null,
                'price': 600,
                'old_price': null,
                'main_image_url': 'https://cdn.example/kebab.jpg',
                'preparation_time_minutes': 25,
              },
            ],
          },
        ],
  };
}

/// Records rpc requests and replays a canned response, so repository tests
/// assert the real request without any network access.
class RecordingHttpClient extends http.BaseClient {
  RecordingHttpClient(this._handler);

  final Future<http.Response> Function(http.BaseRequest request, String? body)
  _handler;

  final List<http.BaseRequest> requests = [];
  final List<String?> requestBodies = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : null;
    requests.add(request);
    requestBodies.add(body);
    final response = await _handler(request, body);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

/// A client with no signed-in user, because a scanned guest has no session.
SupabaseClient buildSupabaseTestClient(RecordingHttpClient httpClient) {
  return SupabaseClient(
    'http://localhost:54321',
    'test-anon-key',
    httpClient: httpClient,
    // A guest has no session, so there is nothing to refresh. Left on, GoTrue
    // starts a `Timer.periodic` in the constructor, which stays pending inside
    // the fake-async zone of a widget test and fails it with "A Timer is still
    // pending even after the widget tree was disposed".
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
}

/// A repository that serves a fixed payload and records requested tokens.
class FakePublicMenuRepository extends PublicMenuRepository {
  FakePublicMenuRepository(
    this._json, {
    this.resolvesToNothing = false,
    this.error,
    this.failuresRemaining = 0,
  });

  final Map<String, dynamic> _json;

  /// When true the token resolves to nothing, like an unknown or inactive one.
  final bool resolvesToNothing;

  final Object? error;
  int failuresRemaining;

  final List<String> requestedTokens = [];

  @override
  Future<PublicMenuModel?> getMenuByQrToken(String qrToken) async {
    requestedTokens.add(qrToken);
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('network down');
    }
    if (error != null) {
      throw error!;
    }
    if (resolvesToNothing) {
      return null;
    }
    return PublicMenuModel.fromJson(_json);
  }
}

/// A repository that never completes, for exercising loading states.
class PendingPublicMenuRepository extends PublicMenuRepository {
  PendingPublicMenuRepository(this.completer);

  final Completer<PublicMenuModel?> completer;

  @override
  Future<PublicMenuModel?> getMenuByQrToken(String qrToken) => completer.future;
}
