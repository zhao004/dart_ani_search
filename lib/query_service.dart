import 'dart:async';

import 'exceptions.dart';
import 'models/anime.dart';
import 'models/provider.dart';
import 'providers/base_provider.dart';
import 'providers/registry.dart';

/// 统一封装查询类接口的调度逻辑。
class AnimeQueryService {
  /// 创建查询服务。
  AnimeQueryService({
    ProviderRegistry? registry,
    this.providerTimeout = const Duration(seconds: 20),
  }) : registry = registry ?? ProviderRegistry();

  /// Provider 注册表。
  final ProviderRegistry registry;

  /// 聚合搜索中单个 Provider 的超时时间。
  final Duration? providerTimeout;

  /// 返回 Provider 列表。
  Future<ProviderListData> listProviders() async => registry.listProviders();

  /// 执行聚合搜索。
  Future<AnimeAggregateSearchResult> searchAggregate({
    required String keyword,
    Iterable<String>? providerNames,
  }) async {
    final normalizedKeyword = _normalizeNonEmptyText(keyword, 'keyword');
    final providers = registry.getProviders(providerNames);
    if (providers.isEmpty) {
      throw const ProviderRequestException('没有可用的 Provider 可执行聚合搜索');
    }

    final results = await Future.wait(
      providers.map(
        (entry) =>
            _searchSingleProvider(entry.key, entry.value, normalizedKeyword),
      ),
    );

    final items = <AnimeCard>[];
    final succeededProviders = <String>[];
    final failedProviders = <ProviderSearchFailure>[];
    for (final result in results) {
      if (result.failure != null) {
        failedProviders.add(result.failure!);
        continue;
      }
      succeededProviders.add(result.providerName);
      items.addAll(result.result!.items);
    }

    if (succeededProviders.isEmpty) {
      throw ProviderRequestException(_buildAllFailedMessage(failedProviders));
    }

    return AnimeAggregateSearchResult(
      keyword: normalizedKeyword,
      requestedProviders: providers.map((entry) => entry.key).toList(),
      succeededProviders: succeededProviders,
      failedProviders: failedProviders,
      total: items.length,
      items: items,
    );
  }

  /// 执行单 Provider 搜索。
  Future<AnimeSearchResult> searchProvider({
    required String providerName,
    required String keyword,
  }) async {
    final normalizedKeyword = _normalizeNonEmptyText(keyword, 'keyword');
    final provider = registry.getProvider(providerName);
    return provider.search(normalizedKeyword);
  }

  /// 获取详情。
  Future<AnimeDetail> getDetail({
    required String providerName,
    required String animeId,
  }) {
    final normalizedAnimeId = _normalizeNonEmptyText(animeId, 'anime_id');
    return registry.getProvider(providerName).getDetail(normalizedAnimeId);
  }

  /// 获取章节列表。
  Future<AnimeChapterList> getChapters({
    required String providerName,
    required String animeId,
  }) {
    final normalizedAnimeId = _normalizeNonEmptyText(animeId, 'anime_id');
    return registry.getProvider(providerName).getChapters(normalizedAnimeId);
  }

  /// 获取播放内容。
  Future<AnimeContent> getContent({
    required String providerName,
    required String chapterId,
  }) {
    final normalizedChapterId = _normalizeNonEmptyText(chapterId, 'chapter_id');
    return registry.getProvider(providerName).getContent(normalizedChapterId);
  }

  Future<_ProviderSearchOutcome> _searchSingleProvider(
    String providerName,
    BaseProvider provider,
    String keyword,
  ) async {
    try {
      final future = provider.search(keyword);
      final result = providerTimeout == null
          ? await future
          : await future.timeout(providerTimeout!);
      return _ProviderSearchOutcome(providerName: providerName, result: result);
    } on TimeoutException {
      return _ProviderSearchOutcome(
        providerName: providerName,
        failure: ProviderSearchFailure(provider: providerName, message: '搜索超时'),
      );
    } on AniSearchException catch (error) {
      return _ProviderSearchOutcome(
        providerName: providerName,
        failure: ProviderSearchFailure(
          provider: providerName,
          message: error.message,
        ),
      );
    } on Object catch (error) {
      return _ProviderSearchOutcome(
        providerName: providerName,
        failure: ProviderSearchFailure(
          provider: providerName,
          message: '未预期异常: $error',
        ),
      );
    }
  }

  static String _normalizeNonEmptyText(String value, String fieldName) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw InvalidQueryParameterException('$fieldName 参数不能为空');
    }
    return normalized;
  }

  static String _buildAllFailedMessage(List<ProviderSearchFailure> failures) {
    if (failures.isEmpty) {
      return '全部 Provider 搜索失败';
    }
    final detail = failures
        .map((failure) => '${failure.provider}: ${failure.message}')
        .join('；');
    return '全部 Provider 搜索失败：$detail';
  }
}

class _ProviderSearchOutcome {
  const _ProviderSearchOutcome({
    required this.providerName,
    this.result,
    this.failure,
  });

  final String providerName;
  final AnimeSearchResult? result;
  final ProviderSearchFailure? failure;
}
