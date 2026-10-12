import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'order_test_data.dart';
import 'public_menu_test_data.dart';

const String restaurantA = '11111111-1111-1111-1111-111111111111';
const String restaurantB = '22222222-2222-2222-2222-222222222222';
const String centerBranch = '33333333-3333-3333-3333-333333333333';
const String staffUserId = 'e0000000-0000-4000-8000-000000000001';
const String orderCreatedAt = '2026-10-05T14:22:31.504534+00:00';
const String orderUpdatedAt = '2026-10-05T14:25:00.000000+00:00';

/// Builds one entry of the `staff_list_orders` payload.
///
/// The same shape `guest_orders` sends for the lines, plus what only staff are told:
/// the branch, the ordered table and when the order last changed. There is no access
/// token in it, and none is built here, because the database sends none.
Map<String, dynamic> buildStaffOrderJson({
  String id = '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136',
  int orderNumber = 1043,
  String status = 'PENDING',
  String currency = 'KGS',
  num total = 900,
  int itemCount = 2,
  String branchId = centerBranch,
  String? tableId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  String? tableNumber = '12',
  String? tableName = 'Window',
  String createdAt = orderCreatedAt,
  String updatedAt = orderUpdatedAt,
  List<Map<String, dynamic>>? items,
}) {
  return {
    'id': id,
    'order_number': orderNumber,
    'status': status,
    'currency': currency,
    'total': total,
    'item_count': itemCount,
    'branch_id': branchId,
    'table': tableId == null
        ? null
        : {'id': tableId, 'number': tableNumber, 'name': tableName},
    'items': items ?? [buildOrderLineJson()],
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}

/// Builds the whole `staff_list_orders` payload, which is the wrapper the database
/// sends around the orders: the restaurant and branch it answered for, and the orders.
///
/// The orders are [Object] rather than [Map] so a test can put something that is not an
/// order in the list, which is the shape a caller has to survive.
Map<String, dynamic> buildStaffOrdersJson({
  String restaurantId = restaurantA,
  String? branchId,
  List<Object?>? orders,
}) {
  return {
    'restaurant_id': restaurantId,
    'branch_id': branchId,
    'orders': orders ?? [buildStaffOrderJson()],
  };
}

/// Builds the whole `staff_list_order_history` payload: the `staff_list_orders`
/// envelope plus the two paging fields.
///
/// [nextCursor] is built with [buildStaffOrderHistoryCursor] when it is not handed in,
/// so a test cannot accidentally pair `has_more` true with no position to read from,
/// which is the state a screen has to survive rather than one it should meet.
Map<String, dynamic> buildStaffOrderHistoryJson({
  String restaurantId = restaurantA,
  String? branchId,
  List<Object?>? orders,
  bool hasMore = false,
  Map<String, dynamic>? nextCursor,
}) {
  return {
    'restaurant_id': restaurantId,
    'branch_id': branchId,
    'orders': orders ?? [buildStaffOrderJson()],
    'has_more': hasMore,
    'next_cursor': nextCursor,
  };
}

/// Builds a `next_cursor` as the database sends it: the two halves of one key.
Map<String, dynamic> buildStaffOrderHistoryCursor({
  String createdAt = orderCreatedAt,
  int orderNumber = 1043,
}) {
  return {'created_at': createdAt, 'order_number': orderNumber};
}

/// Builds the whole `staff_set_order_status` payload: only what changed.
Map<String, dynamic> buildStaffOrderStatusUpdateJson({
  String id = '8b8a7fe9-f457-494c-9f0a-e8f40ae9f136',
  String status = 'ACCEPTED',
  String updatedAt = orderUpdatedAt,
}) {
  return {'id': id, 'status': status, 'updated_at': updatedAt};
}

/// A token shaped like the one GoTrue hands out, so a canned sign-in is accepted.
///
/// Only the claims matter here: the `sub` is the staff member the request will be made
/// as, and an expiry far in the future keeps the client from refreshing.
String buildStaffAccessToken() {
  String segment(Map<String, dynamic> claims) =>
      base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');

  return '${segment({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${segment({'sub': staffUserId, 'role': 'authenticated', 'exp': 4102444800})}'
      '.signature';
}

/// A client with a signed-in staff member, built without any network access.
///
/// A test client has no session of its own, which is what a guest gets, so a staff
/// repository would answer "nothing" against it and never send the request its tests
/// are about. Signing in against a canned response gives a real session, so the real
/// repository code runs: the real guard for "is somebody signed in", and the real
/// postgrest request.
Future<SupabaseClient> signedInStaffClient(RecordingHttpClient httpClient) async {
  final client = buildSupabaseTestClient(httpClient);
  await client.auth.signInWithPassword(
    email: 'owner@example.com',
    password: 'password',
  );
  return client;
}

/// An http client that answers a sign-in and then answers every rpc with [payload].
///
/// A refused rpc answers with the shape postgrest turns into a
/// [PostgrestException]: a non-2xx status and the database's error object.
RecordingHttpClient staffHttpClient({
  Object? payload,
  int statusCode = 200,
}) {
  return RecordingHttpClient((request, body) async {
    if (request.url.path.contains('/auth/v1/token')) {
      return http.Response(
        jsonEncode({
          'access_token': buildStaffAccessToken(),
          'token_type': 'bearer',
          'expires_in': 3600,
          'expires_at': 4102444800,
          'refresh_token': 'refresh-token',
          'user': {
            'id': staffUserId,
            'aud': 'authenticated',
            'role': 'authenticated',
            'email': 'owner@example.com',
            'app_metadata': {'role': 'authenticated'},
            'user_metadata': <String, dynamic>{},
            'created_at': '2026-10-01T00:00:00Z',
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    return http.Response(
      jsonEncode(payload),
      statusCode,
      headers: {'content-type': 'application/json'},
    );
  });
}

/// The decoded body of the rpc request, so a test can assert on what would be sent.
Map<String, dynamic> lastRpcBody(RecordingHttpClient httpClient) {
  final bodies = httpClient.requestBodies
      .where((body) => body != null && body.contains('p_'))
      .toList();
  return jsonDecode(bodies.last!) as Map<String, dynamic>;
}
