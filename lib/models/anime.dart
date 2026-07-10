/// 搜索结果中的动漫卡片。
class AnimeCard {
  /// 创建搜索结果卡片。
  const AnimeCard({
    required this.provider,
    required this.animeId,
    required this.title,
    this.cover = '',
    required this.detailUrl,
    this.latest = '',
    this.year = '',
    this.area = '',
    this.categories = const <String>[],
    this.actors = const <String>[],
    this.description = '',
  });

  /// 来源 Provider。
  final String provider;

  /// 动漫唯一标识。
  final String animeId;

  /// 动漫标题。
  final String title;

  /// 封面地址。
  final String cover;

  /// 详情页地址。
  final String detailUrl;

  /// 更新状态或备注。
  final String latest;

  /// 首播年份。
  final String year;

  /// 地区。
  final String area;

  /// 番剧类型或分类标签。
  final List<String> categories;

  /// 演员或声优列表。
  final List<String> actors;

  /// 补充描述。
  final String description;

  /// 从 JSON 创建模型，便于调用方缓存结果。
  factory AnimeCard.fromJson(Map<String, Object?> json) => AnimeCard(
    provider: json['provider'] as String? ?? '',
    animeId: json['anime_id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    detailUrl: json['detail_url'] as String? ?? '',
    latest: json['latest'] as String? ?? '',
    year: json['year'] as String? ?? '',
    area: json['area'] as String? ?? '',
    categories: _stringList(json['categories']),
    actors: _stringList(json['actors']),
    description: json['description'] as String? ?? '',
  );

  /// 转为兼容原后端字段命名的 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'anime_id': animeId,
    'title': title,
    'cover': cover,
    'detail_url': detailUrl,
    'latest': latest,
    'year': year,
    'area': area,
    'categories': categories,
    'actors': actors,
    'description': description,
  };
}

/// 单 Provider 搜索结果。
class AnimeSearchResult {
  /// 创建搜索结果。
  const AnimeSearchResult({
    required this.provider,
    required this.keyword,
    required this.total,
    this.items = const <AnimeCard>[],
  });

  /// 来源 Provider。
  final String provider;

  /// 搜索关键词。
  final String keyword;

  /// 结果总数。
  final int total;

  /// 搜索结果列表。
  final List<AnimeCard> items;

  /// 从 JSON 创建模型。
  factory AnimeSearchResult.fromJson(Map<String, Object?> json) =>
      AnimeSearchResult(
        provider: json['provider'] as String? ?? '',
        keyword: json['keyword'] as String? ?? '',
        total: json['total'] as int? ?? 0,
        items: _modelList(json['items'], AnimeCard.fromJson),
      );

  /// 转为 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'keyword': keyword,
    'total': total,
    'items': items.map((item) => item.toJson()).toList(),
  };
}

/// 聚合搜索中的单个 Provider 失败信息。
class ProviderSearchFailure {
  /// 创建失败信息。
  const ProviderSearchFailure({required this.provider, required this.message});

  /// 失败 Provider 名称。
  final String provider;

  /// 失败原因。
  final String message;

  /// 从 JSON 创建模型。
  factory ProviderSearchFailure.fromJson(Map<String, Object?> json) =>
      ProviderSearchFailure(
        provider: json['provider'] as String? ?? '',
        message: json['message'] as String? ?? '',
      );

  /// 转为 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'message': message,
  };
}

/// 多站点并发聚合搜索结果。
class AnimeAggregateSearchResult {
  /// 创建聚合搜索结果。
  const AnimeAggregateSearchResult({
    required this.keyword,
    this.requestedProviders = const <String>[],
    this.succeededProviders = const <String>[],
    this.failedProviders = const <ProviderSearchFailure>[],
    required this.total,
    this.items = const <AnimeCard>[],
  });

  /// 搜索关键词。
  final String keyword;

  /// 本次执行的 Provider 列表。
  final List<String> requestedProviders;

  /// 搜索成功的 Provider 列表。
  final List<String> succeededProviders;

  /// 搜索失败的 Provider 明细。
  final List<ProviderSearchFailure> failedProviders;

  /// 聚合结果总数。
  final int total;

  /// 聚合搜索结果列表。
  final List<AnimeCard> items;

  /// 转为 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'keyword': keyword,
    'requested_providers': requestedProviders,
    'succeeded_providers': succeededProviders,
    'failed_providers': failedProviders
        .map((failure) => failure.toJson())
        .toList(),
    'total': total,
    'items': items.map((item) => item.toJson()).toList(),
  };
}

/// 聚合搜索的渐进快照，每个 Provider 完成时都会生成新实例。
class AnimeAggregateSearchUpdate {
  /// 创建渐进搜索快照。
  const AnimeAggregateSearchUpdate({
    required this.result,
    this.completedProviders = const <String>[],
    this.pendingProviders = const <String>[],
    required this.isComplete,
  });

  /// 当前已聚合的结果。
  final AnimeAggregateSearchResult result;

  /// 已完成搜索的 Provider，顺序与请求顺序一致。
  final List<String> completedProviders;

  /// 尚未完成搜索的 Provider，顺序与请求顺序一致。
  final List<String> pendingProviders;

  /// 所有 Provider 是否均已结束。
  final bool isComplete;

  /// 已完成 Provider 数量。
  int get completedCount => completedProviders.length;

  /// 本次请求 Provider 总数。
  int get totalProviders => completedProviders.length + pendingProviders.length;

  /// 完成进度，空 Provider 列表按完成处理。
  double get progress {
    final total = totalProviders;
    return total == 0 ? 1 : completedCount / total;
  }
}

/// 动漫详情模型。
class AnimeDetail {
  /// 创建详情模型。
  const AnimeDetail({
    required this.provider,
    required this.animeId,
    this.title = '',
    this.cover = '',
    this.description = '',
    this.latest = '',
    this.updateTime = '',
    this.year = '',
    this.area = '',
    this.playUrl = '',
    this.director = const <String>[],
    this.actors = const <String>[],
    this.tags = const <String>[],
  });

  /// 来源 Provider。
  final String provider;

  /// 动漫唯一标识。
  final String animeId;

  /// 动漫标题。
  final String title;

  /// 封面地址。
  final String cover;

  /// 详情简介。
  final String description;

  /// 更新状态或备注。
  final String latest;

  /// 更新时间。
  final String updateTime;

  /// 年份。
  final String year;

  /// 地区。
  final String area;

  /// 首个可播放地址。
  final String playUrl;

  /// 导演列表。
  final List<String> director;

  /// 主演列表。
  final List<String> actors;

  /// 分类标签。
  final List<String> tags;

  /// 转为 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'anime_id': animeId,
    'title': title,
    'cover': cover,
    'description': description,
    'latest': latest,
    'update_time': updateTime,
    'year': year,
    'area': area,
    'play_url': playUrl,
    'director': director,
    'actors': actors,
    'tags': tags,
  };
}

/// 章节信息模型。
class AnimeChapter {
  /// 创建章节。
  const AnimeChapter({
    required this.chapterId,
    required this.title,
    this.playUrl = '',
  });

  /// 章节唯一标识。
  final String chapterId;

  /// 章节标题。
  final String title;

  /// 章节播放地址。
  final String playUrl;

  /// 转为 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'chapter_id': chapterId,
    'title': title,
    'play_url': playUrl,
  };
}

/// 按线路分组后的章节列表。
class AnimeChapterGroup {
  /// 创建章节分组。
  const AnimeChapterGroup({
    required this.sourceId,
    required this.sourceName,
    this.items = const <AnimeChapter>[],
  });

  /// 线路唯一标识。
  final String sourceId;

  /// 线路名称。
  final String sourceName;

  /// 当前线路下的章节列表。
  final List<AnimeChapter> items;

  /// 转为 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'source_id': sourceId,
    'source_name': sourceName,
    'items': items.map((item) => item.toJson()).toList(),
  };
}

/// 章节列表模型。
class AnimeChapterList {
  /// 创建章节列表。
  const AnimeChapterList({
    required this.provider,
    required this.animeId,
    this.groups = const <AnimeChapterGroup>[],
  });

  /// 来源 Provider。
  final String provider;

  /// 动漫唯一标识。
  final String animeId;

  /// 按线路分组的章节列表。
  final List<AnimeChapterGroup> groups;

  /// 转为 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'anime_id': animeId,
    'groups': groups.map((group) => group.toJson()).toList(),
  };
}

/// 章节播放内容模型。
class AnimeContent {
  /// 创建播放内容。
  const AnimeContent({
    required this.provider,
    required this.chapterId,
    this.title = '',
    this.playUrl = '',
    this.sourceName = '',
    this.sourceId = '',
    this.iframeUrl = '',
    this.videoUrl = '',
    this.videoType = '',
    this.nextChapterId = '',
    this.previousChapterId = '',
  });

  /// 来源 Provider。
  final String provider;

  /// 章节唯一标识。
  final String chapterId;

  /// 章节标题。
  final String title;

  /// 播放页地址。
  final String playUrl;

  /// 当前线路名称。
  final String sourceName;

  /// 当前线路标识。
  final String sourceId;

  /// 播放器 iframe 地址。
  final String iframeUrl;

  /// 当前线路的可播放视频直链。
  final String videoUrl;

  /// 视频类型，例如 m3u8 或 mp4。
  final String videoType;

  /// 下一章节 ID。
  final String nextChapterId;

  /// 上一章节 ID。
  final String previousChapterId;

  /// 转为 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'chapter_id': chapterId,
    'title': title,
    'play_url': playUrl,
    'source_name': sourceName,
    'source_id': sourceId,
    'iframe_url': iframeUrl,
    'video_url': videoUrl,
    'video_type': videoType,
    'next_chapter_id': nextChapterId,
    'previous_chapter_id': previousChapterId,
  };
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  return value
      .map((item) => item.toString())
      .where((item) => item.isNotEmpty)
      .toList();
}

List<T> _modelList<T>(
  Object? value,
  T Function(Map<String, Object?> json) mapper,
) {
  if (value is! List) {
    return <T>[];
  }
  return value
      .whereType<Map>()
      .map((item) => mapper(item.cast<String, Object?>()))
      .toList();
}
