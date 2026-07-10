import 'dart:async';

import 'exceptions.dart';
import 'models/anime.dart';
import 'models/provider.dart';
import 'providers/base_provider.dart';
import 'providers/registry.dart';
import 'providers/search_policy.dart';

/// 统一封装查询类接口的调度逻辑。
class AnimeQueryService {
  /// 创建查询服务。
  AnimeQueryService({ProviderRegistry? registry, this.providerTimeout})
    : registry = registry ?? ProviderRegistry();

  /// Provider 注册表。
  final ProviderRegistry registry;

  /// 测试或调用方显式指定的统一超时；为空时使用 Provider 专属策略。
  final Duration? providerTimeout;

  /// 返回 Provider 列表。
  Future<ProviderListData> listProviders() async => registry.listProviders();

  /// 执行聚合搜索。
  Future<AnimeAggregateSearchResult> searchAggregate({
    required String keyword,
    Iterable<String>? providerNames,
  }) async {
    AnimeAggregateSearchUpdate? finalUpdate;
    await for (final update in searchAggregateProgress(
      keyword: keyword,
      providerNames: providerNames,
    )) {
      finalUpdate = update;
    }

    if (finalUpdate == null) {
      throw const ProviderRequestException('聚合搜索未返回任何结果');
    }
    final result = finalUpdate.result;
    if (result.succeededProviders.isEmpty) {
      throw ProviderRequestException(
        _buildAllFailedMessage(result.failedProviders),
      );
    }
    return result;
  }

  /// 渐进执行聚合搜索，每个 Provider 结束后立即发送一次有序快照。
  Stream<AnimeAggregateSearchUpdate> searchAggregateProgress({
    required String keyword,
    Iterable<String>? providerNames,
  }) {
    late final StreamController<AnimeAggregateSearchUpdate> controller;
    var cancelled = false;
    controller = StreamController<AnimeAggregateSearchUpdate>(
      onListen: () {
        unawaited(
          _runAggregateProgress(
            keyword: keyword,
            providerNames: providerNames,
            controller: controller,
            isCancelled: () => cancelled,
          ),
        );
      },
      onCancel: () {
        cancelled = true;
      },
    );
    return controller.stream;
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
      final timeout =
          providerTimeout ?? providerSearchPolicyFor(providerName).timeout;
      final result = await future.timeout(timeout);
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

  Future<void> _runAggregateProgress({
    required String keyword,
    required Iterable<String>? providerNames,
    required StreamController<AnimeAggregateSearchUpdate> controller,
    required bool Function() isCancelled,
  }) async {
    try {
      final normalizedKeyword = _normalizeNonEmptyText(keyword, 'keyword');
      final providers = registry.getProviders(providerNames);
      if (providers.isEmpty) {
        throw const ProviderRequestException('没有可用的 Provider 可执行聚合搜索');
      }

      final pendingSearches = <String, Future<_ProviderSearchOutcome>>{
        for (final entry in providers)
          entry.key: _searchSingleProvider(
            entry.key,
            entry.value,
            normalizedKeyword,
          ),
      };
      final outcomes = <String, _ProviderSearchOutcome>{};

      while (pendingSearches.isNotEmpty) {
        final outcome = await Future.any(pendingSearches.values);
        pendingSearches.remove(outcome.providerName);
        outcomes[outcome.providerName] = outcome;
        if (isCancelled()) {
          return;
        }
        controller.add(
          _buildAggregateUpdate(
            keyword: normalizedKeyword,
            providers: providers,
            outcomes: outcomes,
          ),
        );
      }
    } on Object catch (error, stackTrace) {
      if (!isCancelled() && !controller.isClosed) {
        controller.addError(error, stackTrace);
      }
    } finally {
      if (!controller.isClosed) {
        await controller.close();
      }
    }
  }

  AnimeAggregateSearchUpdate _buildAggregateUpdate({
    required String keyword,
    required List<MapEntry<String, BaseProvider>> providers,
    required Map<String, _ProviderSearchOutcome> outcomes,
  }) {
    final requestedProviders = <String>[];
    final completedProviders = <String>[];
    final pendingProviders = <String>[];
    final succeededProviders = <String>[];
    final failedProviders = <ProviderSearchFailure>[];
    final items = <AnimeCard>[];

    for (final entry in providers) {
      final providerName = entry.key;
      requestedProviders.add(providerName);
      final outcome = outcomes[providerName];
      if (outcome == null) {
        pendingProviders.add(providerName);
        continue;
      }
      completedProviders.add(providerName);
      final failure = outcome.failure;
      if (failure != null) {
        failedProviders.add(failure);
        continue;
      }
      succeededProviders.add(providerName);
      items.addAll(outcome.result!.items);
    }

    return AnimeAggregateSearchUpdate(
      result: AnimeAggregateSearchResult(
        keyword: keyword,
        requestedProviders: List<String>.unmodifiable(requestedProviders),
        succeededProviders: List<String>.unmodifiable(succeededProviders),
        failedProviders: List<ProviderSearchFailure>.unmodifiable(
          failedProviders,
        ),
        total: items.length,
        items: List<AnimeCard>.unmodifiable(items),
      ),
      completedProviders: List<String>.unmodifiable(completedProviders),
      pendingProviders: List<String>.unmodifiable(pendingProviders),
      isComplete: pendingProviders.isEmpty,
    );
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
