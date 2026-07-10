/// 单个 Provider 搜索请求的网络策略。
class ProviderSearchPolicy {
  /// 创建搜索策略。
  const ProviderSearchPolicy({required this.timeout, this.retryTimes = 0});

  /// 单次搜索允许占用的最长时间。
  final Duration timeout;

  /// 搜索请求重试次数；聚合搜索优先及时返回，因此默认不重试。
  final int retryTimes;
}

const _fastSearchPolicy = ProviderSearchPolicy(timeout: Duration(seconds: 8));
const _slowSearchPolicy = ProviderSearchPolicy(timeout: Duration(seconds: 18));
const _customProviderPolicy = ProviderSearchPolicy(
  timeout: Duration(seconds: 20),
);

/// 按 Provider 返回搜索策略，未知自定义来源保留原 20 秒兼容窗口。
ProviderSearchPolicy providerSearchPolicyFor(String providerName) {
  return switch (providerName.trim().toLowerCase()) {
    'hmgdm' ||
    'yinhuadm' ||
    'qydm' ||
    'yhdmoe' ||
    'xgcartoon' => _fastSearchPolicy,
    'mxdm2' => _slowSearchPolicy,
    _ => _customProviderPolicy,
  };
}
