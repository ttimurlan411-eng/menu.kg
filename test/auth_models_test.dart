import 'package:flutter_test/flutter_test.dart';
import 'package:menukg_flutter/features/auth/data/models/profile_model.dart';
import 'package:menukg_flutter/features/auth/data/models/restaurant_bootstrap_result_model.dart';
import 'package:menukg_flutter/features/auth/data/models/restaurant_membership_model.dart';
import 'package:menukg_flutter/features/auth/data/models/restaurant_summary_model.dart';

void main() {
  test('parses a profile row and serializes its updatable fields', () {
    final profile = ProfileModel.fromJson({
      'id': 'profile-id',
      'full_name': 'Aizada',
      'phone': '+996555000000',
      'avatar_url': 'https://example.com/avatar.png',
      'preferred_language': 'ky',
      'created_at': '2026-09-18T00:00:00.000Z',
      'updated_at': '2026-09-18T01:00:00.000Z',
    });

    expect(profile.id, 'profile-id');
    expect(profile.fullName, 'Aizada');
    expect(profile.createdAt, DateTime.parse('2026-09-18T00:00:00.000Z'));
    expect(profile.toUpdateJson(), {
      'full_name': 'Aizada',
      'phone': '+996555000000',
      'avatar_url': 'https://example.com/avatar.png',
      'preferred_language': 'ky',
    });
  });

  test('parses a restaurant membership row', () {
    final membership = RestaurantMembershipModel.fromJson({
      'id': 'membership-id',
      'restaurant_id': 'restaurant-id',
      'user_id': 'profile-id',
      'role': 'WAITER',
      'is_active': true,
      'created_at': '2026-09-18T00:00:00.000Z',
      'updated_at': '2026-09-18T01:00:00.000Z',
    });

    expect(membership.restaurantId, 'restaurant-id');
    expect(membership.userId, 'profile-id');
    expect(membership.role, 'WAITER');
    expect(membership.isActive, isTrue);
  });

  test('parses a restaurant bootstrap RPC result', () {
    final result = RestaurantBootstrapResultModel.fromJson({
      'id': 'restaurant-id',
      'name': 'Besh Barmak',
      'slug': 'besh-barmak',
      'description': 'Traditional cuisine',
      'phone': '+996555000000',
      'address': 'Bishkek',
      'currency': 'KGS',
      'default_language': 'ky',
      'is_active': true,
      'created_at': '2026-09-18T00:00:00.000Z',
      'updated_at': '2026-09-18T01:00:00.000Z',
      'branch_id': 'branch-id',
      'branch_name': 'Main branch',
    });

    expect(result.restaurantId, 'restaurant-id');
    expect(result.slug, 'besh-barmak');
    expect(result.branchId, 'branch-id');
    expect(result.branchName, 'Main branch');
    expect(result.createdAt, DateTime.parse('2026-09-18T00:00:00.000Z'));
  });

  test('parses a restaurant summary and its active branch', () {
    final summary = RestaurantSummaryModel.fromJson({
      'id': 'restaurant-id',
      'name': 'Besh Barmak',
      'branches': [
        {'id': 'inactive-branch', 'name': 'Closed branch', 'is_active': false},
        {'id': 'branch-id', 'name': 'Main branch', 'is_active': true},
      ],
    });

    expect(summary.id, 'restaurant-id');
    expect(summary.name, 'Besh Barmak');
    expect(summary.branchName, 'Main branch');
  });
}
