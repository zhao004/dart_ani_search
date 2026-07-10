import '../exceptions.dart';
import '../models/provider.dart';
import 'base_provider.dart';
import 'providers.dart';

/// Provider 注册表，负责名称解析、去重和顺序保持。
class ProviderRegistry {
  /// 创建默认注册表。
  ProviderRegistry({Map<String, BaseProvider>? providers})
    : _providers = providers ?? buildDefaultProviders();

  final Map<String, BaseProvider> _providers;

  /// 读取单个 Provider。
  BaseProvider getProvider(String providerName) {
    final normalized = _normalizeProviderName(providerName);
    final provider = _providers[normalized];
    if (provider == null) {
      throw ProviderNotFoundException('未找到 Provider: $normalized');
    }
    return provider;
  }

  /// 列出所有 Provider 名称。
  List<String> listProviderNames() =>
      List<String>.unmodifiable(_providers.keys);

  /// 返回列表数据。
  ProviderListData listProviders() {
    final providers = listProviderNames();
    return ProviderListData(total: providers.length, providers: providers);
  }

  /// 批量解析 Provider，支持逗号分隔、去重和注册表顺序。
  List<MapEntry<String, BaseProvider>> getProviders([Iterable<String>? names]) {
    final resolvedNames = resolveProviderNames(names);
    return <MapEntry<String, BaseProvider>>[
      for (final name in resolvedNames)
        MapEntry<String, BaseProvider>(name, _providers[name]!),
    ];
  }

  /// 解析 Provider 名称列表。
  List<String> resolveProviderNames([Iterable<String>? names]) {
    if (names == null) {
      final allNames = listProviderNames();
      if (allNames.isEmpty) {
        throw const ProviderNotFoundException('当前未注册任何 Provider');
      }
      return allNames;
    }

    final requested = <String>{};
    for (final rawName in names) {
      for (final name in rawName.split(',')) {
        final normalized = name.trim().toLowerCase();
        if (normalized.isEmpty) {
          continue;
        }
        if (!_providers.containsKey(normalized)) {
          throw ProviderNotFoundException('未找到 Provider: $normalized');
        }
        requested.add(normalized);
      }
    }

    if (requested.isEmpty) {
      return listProviderNames();
    }
    return _providers.keys.where(requested.contains).toList();
  }

  String _normalizeProviderName(String providerName) {
    final normalized = providerName.trim().toLowerCase();
    if (normalized.isEmpty) {
      throw const InvalidQueryParameterException('provider 参数不能为空');
    }
    return normalized;
  }
}
