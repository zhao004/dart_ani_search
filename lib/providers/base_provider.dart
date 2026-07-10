import '../models/anime.dart';

/// 第三方动漫站点 Provider 基类。
abstract class BaseProvider {
  /// Provider 唯一名称。
  String get providerName;

  /// 搜索动漫。
  Future<AnimeSearchResult> search(String keyword);

  /// 获取动漫详情。
  Future<AnimeDetail> getDetail(String animeId);

  /// 获取章节列表。
  Future<AnimeChapterList> getChapters(String animeId);

  /// 获取播放内容。
  Future<AnimeContent> getContent(String chapterId);
}
