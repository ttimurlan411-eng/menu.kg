/// A profile row from the `profiles` table.
class ProfileModel {
  const ProfileModel({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.avatarUrl,
    required this.preferredLanguage,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String? fullName;
  final String? phone;
  final String? avatarUrl;
  final String preferredLanguage;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ProfileModel.fromJson(Map<String, dynamic> json) {
    return ProfileModel(
      id: json['id'] as String,
      fullName: json['full_name'] as String?,
      phone: json['phone'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      preferredLanguage: json['preferred_language'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  /// Returns fields that may be updated on the `profiles` table.
  Map<String, dynamic> toUpdateJson() {
    return {
      'full_name': fullName,
      'phone': phone,
      'avatar_url': avatarUrl,
      'preferred_language': preferredLanguage,
    };
  }
}
