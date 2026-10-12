import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/models/staff_member_model.dart';
import 'package:menukg_flutter/features/restaurant_admin/data/repositories/staff_member_repository.dart';
import 'package:menukg_flutter/features/restaurant_admin/presentation/staff_member_error_message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/public_menu_test_data.dart';
import 'support/staff_member_test_data.dart';
import 'support/staff_order_test_data.dart';
import 'support/staff_reservation_test_data.dart';

void main() {
  group('StaffMemberModel', () {
    test('parses a member with an id, a profile, a role and an active flag', () {
      final member = StaffMemberModel.fromJson(buildStaffMemberJson());

      expect(member.id, staffMemberId);
      expect(member.userId, staffUserId);
      expect(member.displayName, 'Aigerim Owner');
      expect(member.role, 'OWNER');
      expect(member.isActive, isTrue);
      expect(member.hasDisplayName, isTrue);
      expect(member.trimmedDisplayName, 'Aigerim Owner');
    });

    test('a member with no display name is readable and reads as null', () {
      final member = StaffMemberModel.fromJson(
        buildStaffMemberJson(displayName: null),
      );

      expect(member.displayName, isNull);
      expect(member.hasDisplayName, isFalse);
      expect(member.trimmedDisplayName, isNull);
    });

    test('a blank display name is treated as no name', () {
      final member = StaffMemberModel.fromJson(
        buildStaffMemberJson(displayName: '   '),
      );

      expect(member.hasDisplayName, isFalse);
      expect(member.trimmedDisplayName, isNull);
    });

    test('a deactivated member keeps the stored false', () {
      final member = StaffMemberModel.fromJson(
        buildStaffMemberJson(isActive: false),
      );

      expect(member.isActive, isFalse);
    });

    test('a member the model cannot read is refused rather than guessed at', () {
      for (final json in <Map<String, dynamic>>[
        buildStaffMemberJson()..remove('id'),
        buildStaffMemberJson()..remove('user_id'),
        buildStaffMemberJson()..remove('role'),
        buildStaffMemberJson()..remove('is_active'),
        buildStaffMemberJson()..['id'] = 42,
        buildStaffMemberJson()..['is_active'] = 'true',
      ]) {
        expect(
          () => StaffMemberModel.fromJson(json),
          throwsFormatException,
          reason: 'an unreadable member is refused: $json',
        );
      }
    });

    test('ignores a field it must never hold', () {
      // The payload carries none; a field placed in it anyway is simply not a
      // field of this model, so it cannot be read out of one.
      final json = buildStaffMemberJson()
        ..['email'] = 'secret@example.com'
        ..['access_token'] = 'guest-secret-token';

      final member = StaffMemberModel.fromJson(json);

      expect(member.id, staffMemberId);
      expect(member.role, 'OWNER');
    });
  });

  group('tryParseStaffMembers', () {
    test('parses the payload the database sends', () {
      final members = tryParseStaffMembers(
        encodeReservationRpcResult(buildStaffMembersJson()),
        restaurantId: restaurantA,
      );

      expect(members, hasLength(1));
      expect(members.single.role, 'OWNER');
      expect(members.single.displayName, 'Aigerim Owner');
    });

    test('accepts a payload delivered as a string', () {
      final members = tryParseStaffMembers(
        jsonEncode(buildStaffMembersJson()),
        restaurantId: restaurantA,
      );

      expect(members, hasLength(1));
    });

    test('skips a member it cannot read and keeps the ones around it', () {
      final members = tryParseStaffMembers(
        encodeReservationRpcResult(
          buildStaffMembersJson(
            members: [
              buildStaffMemberJson(displayName: 'First'),
              buildStaffMemberJson(displayName: 'Second', id: 'not-a-uuid')
                ..['is_active'] = 'not a bool',
              buildStaffMemberJson(displayName: 'Third'),
            ],
          ),
        ),
        restaurantId: restaurantA,
      );

      expect(members.map((member) => member.displayName), ['First', 'Third']);
    });

    test('skips entries that are not members at all', () {
      final members = tryParseStaffMembers(
        encodeReservationRpcResult(
          buildStaffMembersJson(
            members: ['not a member', 42, buildStaffMemberJson()],
          ),
        ),
        restaurantId: restaurantA,
      );

      expect(members, hasLength(1));
    });

    test('refuses a payload that names another restaurant', () {
      final members = tryParseStaffMembers(
        encodeReservationRpcResult(
          buildStaffMembersJson(restaurantId: restaurantB),
        ),
        restaurantId: restaurantA,
      );

      expect(members, isEmpty);
    });

    test('reads nothing from an answer it cannot understand', () {
      for (final response in <Object?>[
        null,
        '',
        '   ',
        'not json',
        jsonEncode('a string, not an object'),
        jsonEncode({'members': 'not a list'}),
        jsonEncode({'restaurant_id': restaurantA}),
        42,
      ]) {
        expect(
          tryParseStaffMembers(response, restaurantId: restaurantA),
          isEmpty,
          reason: 'nothing is read from $response',
        );
      }
    });
  });

  group('StaffMemberRepository.getMembers', () {
    test('makes no request when nobody is signed in', () async {
      final httpClient = staffHttpClient(payload: buildStaffMembersJson());
      final repository = StaffMemberRepository.withClient(
        buildSupabaseTestClient(httpClient),
      );

      expect(await repository.getMembers(restaurantId: restaurantA), isEmpty);
      expect(httpClient.requestBodies, isEmpty);
    });

    test('makes no request for a blank restaurant', () async {
      final httpClient = staffHttpClient(payload: buildStaffMembersJson());
      final repository = StaffMemberRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      expect(await repository.getMembers(restaurantId: '  '), isEmpty);
      expect(
        httpClient.requestBodies.where((body) => body!.contains('p_')),
        isEmpty,
      );
    });

    test('sends the restaurant and nothing else', () async {
      final httpClient = staffHttpClient(payload: buildStaffMembersJson());
      final repository = StaffMemberRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      final members = await repository.getMembers(restaurantId: restaurantA);

      expect(members, hasLength(1));
      expect(
        lastRpcBody(httpClient).keys.toSet(),
        {'p_restaurant_id'},
        reason: 'a staff read names only the restaurant, with no paging argument',
      );
      expect(lastRpcBody(httpClient)['p_restaurant_id'], restaurantA);
    });

    test('never sends a token, a user id or a role', () async {
      final httpClient = staffHttpClient(payload: buildStaffMembersJson());
      final repository = StaffMemberRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await repository.getMembers(restaurantId: restaurantA);

      final body = httpClient.requestBodies.firstWhere(
        (body) => body!.contains('p_restaurant_id'),
      );
      expect(body, isNot(contains('access_token')));
      expect(body, isNot(contains(staffUserId)));
      expect(body, isNot(contains('role')));
    });

    test('refuses an answer that belongs to another restaurant', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffMembersJson(restaurantId: restaurantB),
      );
      final repository = StaffMemberRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      expect(await repository.getMembers(restaurantId: restaurantA), isEmpty);
    });

    test('an empty member list is an empty list, not an error', () async {
      final httpClient = staffHttpClient(
        payload: buildStaffMembersJson(members: const []),
      );
      final repository = StaffMemberRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      expect(await repository.getMembers(restaurantId: restaurantA), isEmpty);
    });

    test('lets a refusal through instead of hiding it', () async {
      final httpClient = staffHttpClient(
        payload: {
          'code': '42501',
          'message': 'staff_member_access_denied',
          'details': null,
          'hint': null,
        },
        statusCode: 400,
      );
      final repository = StaffMemberRepository.withClient(
        await signedInStaffClient(httpClient),
      );

      await expectLater(
        repository.getMembers(restaurantId: restaurantA),
        throwsA(
          isA<PostgrestException>().having(
            (error) => error.message,
            'message',
            'staff_member_access_denied',
          ),
        ),
      );
    });
  });

  group('staff member error messages', () {
    test('an ended session is reported as a sign-in problem', () {
      expect(
        staffMemberListErrorMessage(
          reservationPostgrestError(
            '28000',
            message: 'Authentication is required to read restaurant members.',
          ),
        ),
        'Your session has ended. Please sign in again.',
      );
    });

    test('a refused read is reported as a permission problem', () {
      final message = staffMemberListErrorMessage(
        reservationPostgrestError(
          '42501',
          message: 'staff_member_access_denied',
        ),
      );

      expect(message, 'You do not have permission to view staff members.');
      expect(message, isNot(contains('staff_member')));
      expect(message, isNot(contains('denied')));
    });

    test('anything else falls back to safe wording that echoes nothing', () {
      const leak = 'relation public.restaurant_members does not exist for staff_member';

      expect(
        staffMemberListErrorMessage(
          reservationPostgrestError('42P01', message: leak),
        ),
        'We could not load staff members. Please try again.',
      );
      expect(
        staffMemberListErrorMessage(StateError(leak)),
        'We could not load staff members. Please try again.',
      );
    });
  });
}
