import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/auth/data/models/profile_model.dart';
import 'package:menukg_flutter/features/auth/data/repositories/profile_repository.dart';
import 'package:menukg_flutter/features/auth/data/repositories/restaurant_membership_repository.dart';
import 'package:menukg_flutter/features/auth/data/repositories/restaurant_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late SupabaseClient client;
  late ProfileRepository profileRepository;
  late RestaurantMembershipRepository membershipRepository;
  late RestaurantRepository restaurantRepository;

  setUp(() {
    client = SupabaseClient('http://localhost:54321', 'test-anon-key');
    profileRepository = ProfileRepository.withClient(client);
    membershipRepository = RestaurantMembershipRepository.withClient(client);
    restaurantRepository = RestaurantRepository.withClient(client);
  });

  tearDown(() => client.dispose());

  test('profile repository avoids requests when unauthenticated', () async {
    final profile = ProfileModel(
      id: 'profile-id',
      fullName: null,
      phone: null,
      avatarUrl: null,
      preferredLanguage: 'ky',
      createdAt: DateTime.utc(2026, 9, 18),
      updatedAt: DateTime.utc(2026, 9, 18),
    );

    expect(await profileRepository.getCurrentProfile(), isNull);
    expect(await profileRepository.getProfileByUserId('profile-id'), isNull);
    expect(await profileRepository.updateCurrentProfile(profile), isNull);
  });

  test(
    'membership repository returns empty results when unauthenticated',
    () async {
      expect(await membershipRepository.getMyMemberships(), isEmpty);
      expect(
        await membershipRepository.getMembershipForRestaurant('restaurant-id'),
        isNull,
      );
    },
  );

  test(
    'restaurant bootstrap avoids an RPC call when unauthenticated',
    () async {
      final result = await restaurantRepository.createRestaurant(
        name: 'Besh Barmak',
        slug: 'besh-barmak',
        branchName: 'Main branch',
      );

      expect(result, isNull);
    },
  );

  test('restaurant bootstrap validates required input locally', () async {
    await expectLater(
      restaurantRepository.createRestaurant(
        name: '   ',
        slug: 'besh-barmak',
        branchName: 'Main branch',
      ),
      throwsArgumentError,
    );
    await expectLater(
      restaurantRepository.createRestaurant(
        name: 'Besh Barmak',
        slug: '',
        branchName: 'Main branch',
      ),
      throwsArgumentError,
    );
    await expectLater(
      restaurantRepository.createRestaurant(
        name: 'Besh Barmak',
        slug: 'besh-barmak',
        branchName: '\t',
      ),
      throwsArgumentError,
    );
  });
}
