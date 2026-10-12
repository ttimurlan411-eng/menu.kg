/// The restaurant details needed by the temporary authenticated landing page.
class RestaurantSummaryModel {
  const RestaurantSummaryModel({
    required this.id,
    required this.name,
    required this.branchName,
    this.branchId,
  });

  final String id;
  final String name;
  final String? branchName;

  /// Id of the active branch, when one is available.
  ///
  /// Tables require a `branch_id`, so the admin screens use it to scope table
  /// management. It is optional to stay backward compatible with callers that
  /// only display the branch name.
  final String? branchId;

  factory RestaurantSummaryModel.fromJson(Map<String, dynamic> json) {
    final branches = json['branches'];
    String? branchName;
    String? branchId;

    if (branches is List) {
      for (final branch in branches) {
        if (branch is Map && branch['is_active'] == true) {
          branchName = branch['name'] as String?;
          branchId = branch['id'] as String?;
          break;
        }
      }
    }

    return RestaurantSummaryModel(
      id: json['id'] as String,
      name: json['name'] as String,
      branchName: branchName,
      branchId: branchId,
    );
  }
}
