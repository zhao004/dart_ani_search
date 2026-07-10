import 'dart:convert';

import 'package:html/dom.dart';

import '../exceptions.dart';
import '../models/anime.dart';
import '../utils/http_client.dart';
import '../utils/parser.dart';
import 'base_provider.dart';
import 'search_policy.dart';

class _Mxdm2ChapterLocator {
  const _Mxdm2ChapterLocator({
    required this.animeId,
    required this.sourceId,
    required this.episodeIndex,
  });

  final String animeId;
  final String sourceId;
  final int episodeIndex;
}

/// MX 动漫 Provider，使用站内联想接口搜索并解析苹果 CMS 播放配置。
class Mxdm2Provider implements BaseProvider {
  /// 创建 MX 动漫 Provider。
  Mxdm2Provider({AniHttpClient? httpClient})
    : httpClient = httpClient ?? AniHttpClient();

  /// HTTP 客户端。
  final AniHttpClient httpClient;

  static const String _baseUrl = 'https://www.mxdm2.com';
  static final RegExp _detailIdPattern = RegExp(
    r'/index\.php/vod/detail/id/(?<animeId>\d+)\.html',
  );
  static final RegExp _chapterPathPattern = RegExp(
    r'/index\.php/vod/play/id/(?<animeId>\d+)/sid/(?<sourceId>\d+)/nid/(?<episodeIndex>\d+)\.html',
  );
  static final RegExp _chapterIdPattern = RegExp(
    r'^(?<animeId>\d+):(?<sourceId>\d+):(?<episodeIndex>\d+)$',
  );
  static final RegExp _playerDataPattern = RegExp(
    r'var\s+player_aaaa\s*=\s*(?<payload>\{.*?\})\s*</script>',
    dotAll: true,
  );

  @override
  String get providerName => 'mxdm2';

  @override
  Future<AnimeSearchResult> search(String keyword) async {
    final cleanedKeyword = normalizeText(keyword);
    if (cleanedKeyword.isEmpty) {
      throw const InvalidQueryParameterException('keyword 参数不能为空');
    }

    final searchPolicy = providerSearchPolicyFor(providerName);
    final payload = await httpClient.getText(
      '$_baseUrl/index.php/ajax/suggest'
      '?mid=1&wd=${Uri.encodeQueryComponent(cleanedKeyword)}&limit=20',
      referer: '$_baseUrl/',
      headers: const <String, String>{
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
      },
      timeout: searchPolicy.timeout,
      retryTimes: searchPolicy.retryTimes,
    );
    final decoded = _decodeJsonObject(payload, 'mxdm2 搜索接口');
    final rawItems = decoded['list'];
    if (rawItems is! List) {
      throw const ProviderParseException('mxdm2 搜索接口缺少 list 数组');
    }

    final items = <AnimeCard>[];
    for (final rawItem in rawItems.whereType<Map>()) {
      final item = rawItem.cast<String, Object?>();
      final animeId = normalizeText(item['id']);
      final title = normalizeText(item['name']);
      if (animeId.isEmpty || title.isEmpty) {
        continue;
      }
      items.add(
        AnimeCard(
          provider: providerName,
          animeId: animeId,
          title: title,
          cover: normalizeUrl(normalizeText(item['pic']), _baseUrl),
          detailUrl: _buildDetailUrl(animeId),
        ),
      );
    }

    return AnimeSearchResult(
      provider: providerName,
      keyword: cleanedKeyword,
      total: items.length,
      items: items,
    );
  }

  @override
  Future<AnimeDetail> getDetail(String animeId) async {
    final normalizedAnimeId = _normalizeAnimeId(animeId);
    final root = await _fetchDetailRoot(normalizedAnimeId);
    final title = firstNonEmpty([
      selectText(root, 'h1'),
      _readMeta(root, 'meta[property="og:title"]'),
    ]);
    if (title.isEmpty) {
      throw const ProviderParseException('mxdm2 详情页解析失败，未找到标题');
    }

    final groups = _extractChapterGroups(root, normalizedAnimeId);
    final firstPlayUrl = groups.isNotEmpty && groups.first.items.isNotEmpty
        ? groups.first.items.first.playUrl
        : '';

    return AnimeDetail(
      provider: providerName,
      animeId: normalizedAnimeId,
      title: title,
      cover: normalizeUrl(
        firstNonEmpty([
          _readMeta(root, 'meta[property="og:image"]'),
          selectAttr(root, '.module-info-poster img', 'data-original'),
          selectAttr(root, '.module-info-poster img', 'src'),
        ]),
        _baseUrl,
      ),
      description: firstNonEmpty([
        _readMeta(root, 'meta[property="og:description"]'),
        _readMeta(root, 'meta[name="description"]'),
        selectText(root, '.module-info-introduction-content'),
      ]),
      latest: firstNonEmpty([
        selectText(root, '.module-info-item-content'),
        selectText(root, '.module-item-note'),
      ]),
      playUrl: firstPlayUrl,
      tags: selectTexts(root, '.module-info-tag-link a'),
    );
  }

  @override
  Future<AnimeChapterList> getChapters(String animeId) async {
    final normalizedAnimeId = _normalizeAnimeId(animeId);
    final root = await _fetchDetailRoot(normalizedAnimeId);
    return AnimeChapterList(
      provider: providerName,
      animeId: normalizedAnimeId,
      groups: _extractChapterGroups(root, normalizedAnimeId),
    );
  }

  @override
  Future<AnimeContent> getContent(String chapterId) async {
    final locator = _parseChapterLocator(chapterId);
    final normalizedChapterId = _buildChapterId(
      locator.animeId,
      locator.sourceId,
      locator.episodeIndex,
    );
    final playUrl = _buildPlayUrl(locator);
    final html = await httpClient.getText(
      playUrl,
      referer: _buildDetailUrl(locator.animeId),
    );
    final root = buildDocument(html).documentElement!;
    final playerData = _parsePlayerData(html);
    final videoUrl = _decodePlayerUrl(
      normalizeText(playerData['url']),
      normalizeText(playerData['encrypt']),
    );
    if (videoUrl.isEmpty) {
      throw const ProviderParseException('mxdm2 播放页解析失败，未恢复出播放地址');
    }

    return AnimeContent(
      provider: providerName,
      chapterId: normalizedChapterId,
      title: firstNonEmpty([
        selectText(root, 'h1'),
        _normalizePageTitle(selectText(root, 'title')),
        normalizedChapterId,
      ]),
      playUrl: playUrl,
      sourceName: firstNonEmpty([playerData['from'], '线路${locator.sourceId}']),
      sourceId: locator.sourceId,
      videoUrl: videoUrl,
      videoType: detectVideoType(videoUrl),
      nextChapterId: _extractChapterId(normalizeText(playerData['link_next'])),
      previousChapterId: _extractChapterId(
        normalizeText(playerData['link_pre']),
      ),
    );
  }

  Future<Element> _fetchDetailRoot(String animeId) async {
    final html = await httpClient.getText(
      _buildDetailUrl(animeId),
      referer: '$_baseUrl/',
    );
    return buildDocument(html).documentElement!;
  }

  List<AnimeChapterGroup> _extractChapterGroups(Element root, String animeId) {
    final groupItems = <String, List<AnimeChapter>>{};
    final seenChapterIds = <String>{};
    for (final link in root.querySelectorAll(
      'a[href*="/index.php/vod/play/id/"]',
    )) {
      final href = normalizeText(link.attributes['href']);
      final match = _chapterPathPattern.firstMatch(href);
      if (match == null || match.namedGroup('animeId') != animeId) {
        continue;
      }
      final sourceId = match.namedGroup('sourceId')!;
      final episodeIndex = int.parse(match.namedGroup('episodeIndex')!);
      final currentChapterId = _buildChapterId(animeId, sourceId, episodeIndex);
      if (!seenChapterIds.add(currentChapterId)) {
        continue;
      }
      groupItems
          .putIfAbsent(sourceId, () => <AnimeChapter>[])
          .add(
            AnimeChapter(
              chapterId: currentChapterId,
              title: firstNonEmpty([link.text, '第$episodeIndex集']),
              playUrl: normalizeUrl(href, _baseUrl),
            ),
          );
    }

    return groupItems.entries
        .map(
          (entry) => AnimeChapterGroup(
            sourceId: entry.key,
            sourceName: '线路${entry.key}',
            items: entry.value,
          ),
        )
        .toList();
  }

  Map<String, Object?> _parsePlayerData(String html) {
    final payload = normalizeText(
      _playerDataPattern.firstMatch(html)?.namedGroup('payload'),
    );
    if (payload.isEmpty) {
      throw const ProviderParseException('mxdm2 播放页缺少 player_aaaa 配置');
    }
    return _decodeJsonObject(payload, 'mxdm2 播放页 player_aaaa');
  }

  Map<String, Object?> _decodeJsonObject(String payload, String sourceName) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, Object?>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.cast<String, Object?>();
      }
      throw ProviderParseException('$sourceName 不是 JSON 对象');
    } on FormatException catch (error) {
      throw ProviderParseException('$sourceName 不是合法 JSON: $error');
    }
  }

  String _decodePlayerUrl(String rawUrl, String encryptMode) {
    if (rawUrl.isEmpty) {
      return '';
    }
    if (encryptMode == '1') {
      return normalizeUrl(Uri.decodeComponent(rawUrl), _baseUrl);
    }
    if (encryptMode == '2') {
      try {
        final decoded = utf8.decode(base64Decode(rawUrl), allowMalformed: true);
        return normalizeUrl(Uri.decodeComponent(decoded), _baseUrl);
      } on FormatException catch (error) {
        throw ProviderParseException('mxdm2 播放地址 base64 解码失败: $error');
      }
    }
    return normalizeUrl(rawUrl, _baseUrl);
  }

  _Mxdm2ChapterLocator _parseChapterLocator(String chapterId) {
    final normalized = normalizeText(chapterId);
    if (normalized.isEmpty) {
      throw const InvalidQueryParameterException('chapter_id 参数不能为空');
    }
    final extracted = _extractChapterId(normalized);
    final match = _chapterIdPattern.firstMatch(
      extracted.isEmpty ? normalized : extracted,
    );
    if (match == null) {
      throw const InvalidQueryParameterException(
        'chapter_id 格式无效，mxdm2 仅支持 {anime_id}:{source_id}:{episode_index}',
      );
    }
    final episodeIndex = int.parse(match.namedGroup('episodeIndex')!);
    if (episodeIndex <= 0) {
      throw const InvalidQueryParameterException('chapter_id 中的集数必须大于 0');
    }
    return _Mxdm2ChapterLocator(
      animeId: match.namedGroup('animeId')!,
      sourceId: match.namedGroup('sourceId')!,
      episodeIndex: episodeIndex,
    );
  }

  String _normalizeAnimeId(String animeId) {
    final normalized = normalizeText(animeId);
    if (normalized.isEmpty) {
      throw const InvalidQueryParameterException('anime_id 参数不能为空');
    }
    final extracted = _detailIdPattern
        .firstMatch(normalized)
        ?.namedGroup('animeId');
    final result = normalizeText(extracted ?? normalized);
    if (!RegExp(r'^\d+$').hasMatch(result)) {
      throw const InvalidQueryParameterException('anime_id 必须是数字');
    }
    return result;
  }

  String _extractChapterId(String value) {
    final directMatch = _chapterIdPattern.firstMatch(normalizeText(value));
    if (directMatch != null) {
      return _buildChapterId(
        directMatch.namedGroup('animeId')!,
        directMatch.namedGroup('sourceId')!,
        int.parse(directMatch.namedGroup('episodeIndex')!),
      );
    }
    final pathMatch = _chapterPathPattern.firstMatch(normalizeText(value));
    if (pathMatch == null) {
      return '';
    }
    return _buildChapterId(
      pathMatch.namedGroup('animeId')!,
      pathMatch.namedGroup('sourceId')!,
      int.parse(pathMatch.namedGroup('episodeIndex')!),
    );
  }

  String _buildDetailUrl(String animeId) =>
      '$_baseUrl/index.php/vod/detail/id/$animeId.html';

  String _buildPlayUrl(_Mxdm2ChapterLocator locator) =>
      '$_baseUrl/index.php/vod/play/id/${locator.animeId}'
      '/sid/${locator.sourceId}/nid/${locator.episodeIndex}.html';

  String _buildChapterId(String animeId, String sourceId, int episodeIndex) =>
      '$animeId:$sourceId:$episodeIndex';

  String _readMeta(Element root, String selector) =>
      normalizeText(root.querySelector(selector)?.attributes['content']);

  String _normalizePageTitle(String title) =>
      normalizeText(title.split('-').first);
}
