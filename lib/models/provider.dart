/// Provider 列表数据。
class ProviderListData {
  /// 创建 Provider 列表。
  const ProviderListData({
    required this.total,
    this.providers = const <String>[],
  });

  /// 已注册 Provider 总数。
  final int total;

  /// 已注册 Provider 名称列表。
  final List<String> providers;

  /// 转为 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'total': total,
    'providers': providers,
  };
}
