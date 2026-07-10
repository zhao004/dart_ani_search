import 'models/anime.dart';
import 'models/provider.dart';
import 'providers/registry.dart';
import 'query_service.dart';

/// Flutter 侧直接调用的动漫搜索客户端。
class AniSearchClient {
  /// 创建客户端，可注入注册表用于测试或扩展自定义 Provider。
  AniSearchClient({ProviderRegistry? registry, Duration? providerTimeout})
    : _service = AnimeQueryService(
        registry: registry,
        providerTimeout: providerTimeout,
      );

  final AnimeQueryService _service;

  /// 获取当前已注册 Provider 列表。
  Future<ProviderListData> listProviders() => _service.listProviders();

  /// 聚合搜索，未传 providers 时搜索全部站点。
  Future<AnimeAggregateSearchResult> search({
    required String keyword,
    List<String>? providers,
  }) => _service.searchAggregate(keyword: keyword, providerNames: providers);

  /// 渐进聚合搜索，每个 Provider 完成后立即返回当前快照。
  Stream<AnimeAggregateSearchUpdate> searchProgress({
    required String keyword,
    List<String>? providers,
  }) => _service.searchAggregateProgress(
    keyword: keyword,
    providerNames: providers,
  );

  /// 获取动漫详情。
  Future<AnimeDetail> getDetail({
    required String provider,
    required String animeId,
  }) => _service.getDetail(providerName: provider, animeId: animeId);

  /// 获取章节列表。
  Future<AnimeChapterList> getChapters({
    required String provider,
    required String animeId,
  }) => _service.getChapters(providerName: provider, animeId: animeId);

  /// 获取播放内容。
  Future<AnimeContent> getContent({
    required String provider,
    required String chapterId,
  }) => _service.getContent(providerName: provider, chapterId: chapterId);
}
