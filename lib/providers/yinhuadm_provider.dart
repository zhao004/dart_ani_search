import 'dart:convert';

import 'package:html/dom.dart';

import '../exceptions.dart';
import '../models/anime.dart';
import '../utils/http_client.dart';
import '../utils/parser.dart';
import 'base_provider.dart';

/// 银花动漫 Provider。
class YinHuaDmProvider implements BaseProvider {
  /// 创建银花动漫 Provider。
  YinHuaDmProvider({AniHttpClient? httpClient})
    : httpClient = httpClient ?? AniHttpClient();

  /// HTTP 客户端。
  final AniHttpClient httpClient;

  static const String _baseUrl = 'https://www.yinhuadm.cc';
  static final RegExp _playerDataPattern = RegExp(
    r'var player_aaaa=(?<payload>\{.*?\})</script>',
    dotAll: true,
  );

  @override
  String get providerName => 'yinhuadm';

  @override
  Future<AnimeSearchResult> search(String keyword) async {
    final cleanedKeyword = normalizeText(keyword);
    if (cleanedKeyword.isEmpty) {
      throw const InvalidQueryParameterException('keyword 参数不能为空');
    }

    final html = await httpClient.getText(
      '$_baseUrl/vch/${Uri.encodeComponent(cleanedKeyword)}.html',
      referer: '$_baseUrl/',
    );
    final document = buildDocument(html);
    final cards = document.querySelectorAll('.module-card-item.module-item');
    if (cards.isEmpty &&
        document.querySelector('#page') == null &&
        html.contains('module-card-item')) {
      throw const ProviderParseException('银花动漫搜索结果结构解析失败，未找到结果容器');
    }
    final items = cards.map(_parseCard).whereType<AnimeCard>().toList();
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
    final title = selectText(root, '.module-info-main h1');
    if (title.isEmpty) {
      throw const ProviderParseException('银花动漫详情页解析失败，未找到标题');
    }

    return AnimeDetail(
      provider: providerName,
      animeId: normalizedAnimeId,
      title: title,
      cover: normalizeUrl(
        firstNonEmpty([
          selectAttr(
            root,
            '.module-info-poster img[data-original]',
            'data-original',
          ),
          selectAttr(root, '.module-info-poster img', 'src'),
        ]),
        _baseUrl,
      ),
      description: selectText(root, '.module-info-introduction-content p'),
      latest: _getDetailInfoValue(root, '备注：'),
      updateTime: _getDetailInfoValue(root, '更新：'),
      year: selectText(root, '.module-info-tag-link a[href*="/w/10/year/"]'),
      area: selectText(root, '.module-info-tag-link a[href*="/w/10/area/"]'),
      playUrl: normalizeUrl(selectAttr(root, 'a.main-btn', 'href'), _baseUrl),
      director: _getDetailInfoValues(root, '导演：'),
      actors: _getDetailInfoValues(root, '主演：'),
      tags: selectTexts(root, '.module-info-tag-link a[href*="/w/10/class/"]'),
    );
  }

  @override
  Future<AnimeChapterList> getChapters(String animeId) async {
    final normalizedAnimeId = _normalizeAnimeId(animeId);
    final root = await _fetchDetailRoot(normalizedAnimeId);
    final lineTabs = root.querySelectorAll('.module-tab-item.tab-item');
    final lineLists = root.querySelectorAll('.module-list.his-tab-list');
    final groups = <AnimeChapterGroup>[];

    for (var index = 0; index < lineLists.length; index += 1) {
      final items = <AnimeChapter>[];
      for (final link in lineLists[index].querySelectorAll(
        'a.module-play-list-link[href^="/p/"]',
      )) {
        final href = normalizeText(link.attributes['href']);
        final chapterId = extractChapterIdFromPlayUrl(href);
        if (chapterId.isEmpty) {
          continue;
        }
        items.add(
          AnimeChapter(
            chapterId: chapterId,
            title: firstNonEmpty([selectText(link, 'span'), link.text]),
            playUrl: normalizeUrl(href, _baseUrl),
          ),
        );
      }
      if (items.isEmpty) {
        continue;
      }
      final sourceId = _extractLineId(items.first.chapterId);
      final tabText = index < lineTabs.length
          ? selectText(lineTabs[index], 'span')
          : '';
      groups.add(
        AnimeChapterGroup(
          sourceId: sourceId,
          sourceName: _normalizeLineName(tabText, sourceId),
          items: items,
        ),
      );
    }
    return AnimeChapterList(
      provider: providerName,
      animeId: normalizedAnimeId,
      groups: groups,
    );
  }

  @override
  Future<AnimeContent> getContent(String chapterId) async {
    final normalizedChapterId = _normalizeChapterId(chapterId);
    final playUrl = '$_baseUrl/p/$normalizedChapterId.html';
    final html = await httpClient.getText(playUrl, referer: '$_baseUrl/');
    final root = buildDocument(html).documentElement!;
    final playerData = _extractPlayerData(html);
    final pageTitle = selectText(root, 'title');
    final title = pageTitle.isNotEmpty
        ? pageTitle.split('-').first.trim()
        : normalizedChapterId;
    final rawUrl = _decodePlayerUrl(
      rawUrl: playerData['url']?.toString() ?? '',
      encryptValue: playerData['encrypt'],
    );
    final videoType = detectVideoType(rawUrl);
    final nextLink = normalizeText(playerData['link_next']);
    final previousLink = normalizeText(playerData['link_pre']);
    final sourceId = _extractLineId(normalizedChapterId);
    final sourceName = _normalizeLineName(
      firstNonEmpty([
        selectText(root, '.module-tab-value'),
        playerData['from'],
      ]),
      sourceId,
    );
    final iframeUrl = videoType.isEmpty
        ? _buildPlayerIframeUrl(
            rawUrl: rawUrl,
            sourceId: normalizeText(playerData['from']),
            nextLink: nextLink,
            title: title,
          )
        : '';
    final videoUrl = videoType.isEmpty ? '' : rawUrl;
    if (videoUrl.isEmpty && iframeUrl.isEmpty) {
      throw const ProviderParseException('银花动漫播放页解析失败，未恢复出播放内容');
    }

    return AnimeContent(
      provider: providerName,
      chapterId: normalizedChapterId,
      title: title,
      playUrl: playUrl,
      sourceName: sourceName,
      sourceId: sourceId,
      iframeUrl: iframeUrl,
      videoUrl: videoUrl,
      videoType: videoType,
      nextChapterId: extractChapterIdFromPlayUrl(nextLink),
      previousChapterId: extractChapterIdFromPlayUrl(previousLink),
    );
  }

  Future<Element> _fetchDetailRoot(String animeId) async {
    final html = await httpClient.getText(
      '$_baseUrl/v/$animeId.html',
      referer: '$_baseUrl/',
    );
    return buildDocument(html).documentElement!;
  }

  AnimeCard? _parseCard(Element node) {
    final detailPath = firstNonEmpty([
      selectAttr(node, 'a.module-card-item-poster', 'href'),
      selectAttr(node, '.module-card-item-title a', 'href'),
    ]);
    final title = selectText(node, '.module-card-item-title strong');
    if (detailPath.isEmpty || title.isEmpty) {
      return null;
    }
    final detailUrl = normalizeUrl(detailPath, _baseUrl);
    final animeId = extractAnimeIdFromDetailUrl(detailUrl);
    if (animeId.isEmpty) {
      return null;
    }
    final meta = _parseSearchMeta(
      selectTexts(node, '.module-info-item-content').firstOrNull ?? '',
    );
    final infoContents = selectTexts(node, '.module-info-item-content');
    return AnimeCard(
      provider: providerName,
      animeId: animeId,
      title: normalizeText(title),
      cover: normalizeUrl(
        firstNonEmpty([
          selectAttr(node, 'img[data-original]', 'data-original'),
          selectAttr(node, 'img', 'src'),
        ]),
        _baseUrl,
      ),
      detailUrl: detailUrl,
      latest: selectText(node, '.module-item-note'),
      year: meta.year,
      area: meta.area,
      categories: meta.categories,
      actors: infoContents.length > 1
          ? splitLooseList(infoContents[1])
          : const <String>[],
    );
  }

  String _normalizeAnimeId(String animeId) {
    final normalized = normalizeText(animeId);
    if (normalized.isEmpty) {
      throw const InvalidQueryParameterException('anime_id 参数不能为空');
    }
    return extractAnimeIdFromDetailUrl(normalized).isNotEmpty
        ? extractAnimeIdFromDetailUrl(normalized)
        : normalized;
  }

  String _normalizeChapterId(String chapterId) {
    var normalized = normalizeText(chapterId);
    if (normalized.isEmpty) {
      throw const InvalidQueryParameterException('chapter_id 参数不能为空');
    }
    if (normalized.startsWith('/p/') || normalized.contains('/p/')) {
      normalized = extractChapterIdFromPlayUrl(normalized);
    }
    if (normalized.isEmpty) {
      throw const InvalidQueryParameterException('chapter_id 参数格式不正确');
    }
    return normalized;
  }

  String _extractLineId(String chapterId) {
    final segments = chapterId.split('-');
    return segments.length < 3 ? '' : segments[1];
  }

  String _normalizeLineName(String sourceName, String sourceId) {
    final cleaned = normalizeText(sourceName);
    if (cleaned.isNotEmpty) {
      return cleaned;
    }
    return sourceId.isNotEmpty ? '线路$sourceId' : '';
  }

  _SearchMeta _parseSearchMeta(String metaText) {
    final parts = metaText
        .split('/')
        .map(normalizeText)
        .where((part) => part.isNotEmpty)
        .toList();
    final categories = <String>[];
    if (parts.length >= 3) {
      for (final part in parts.sublist(2)) {
        categories.addAll(
          part.split(',').map(normalizeText).where((item) => item.isNotEmpty),
        );
      }
    }
    return _SearchMeta(
      year: parts.isNotEmpty ? parts[0] : '',
      area: parts.length >= 2 ? parts[1] : '',
      categories: categories,
    );
  }

  String _getDetailInfoValue(Element root, String titleText) {
    for (final item in root.querySelectorAll('.module-info-item')) {
      if (selectText(item, '.module-info-item-title') ==
          normalizeText(titleText)) {
        return selectText(item, '.module-info-item-content');
      }
    }
    return '';
  }

  List<String> _getDetailInfoValues(Element root, String titleText) {
    for (final item in root.querySelectorAll('.module-info-item')) {
      if (selectText(item, '.module-info-item-title') !=
          normalizeText(titleText)) {
        continue;
      }
      final anchors = selectTexts(item, '.module-info-item-content a');
      if (anchors.isNotEmpty) {
        return anchors;
      }
      final rawText = selectText(item, '.module-info-item-content');
      return rawText
          .split('/')
          .map(normalizeText)
          .where((part) => part.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }

  Map<String, Object?> _extractPlayerData(String html) {
    final payload = normalizeText(
      _playerDataPattern.firstMatch(html)?.namedGroup('payload'),
    );
    if (payload.isEmpty) {
      throw const ProviderParseException('银花动漫播放页解析失败，未找到 player_aaaa');
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, Object?>) {
        return decoded;
      }
      throw const ProviderParseException('银花动漫播放页解析失败，player_aaaa 结构异常');
    } on FormatException catch (error) {
      throw ProviderParseException('银花动漫播放页解析失败，player_aaaa 不是合法 JSON: $error');
    }
  }

  String _decodePlayerUrl({
    required String rawUrl,
    required Object? encryptValue,
  }) {
    final normalized = normalizeText(rawUrl);
    final flag = encryptValue?.toString() ?? '0';
    if (flag == '1') {
      return Uri.decodeComponent(normalized);
    }
    if (flag == '2') {
      try {
        return Uri.decodeComponent(
          utf8.decode(base64Decode(normalized), allowMalformed: true),
        );
      } on FormatException catch (error) {
        throw ProviderParseException('银花动漫播放页 base64 解码失败: $error');
      }
    }
    return normalized;
  }

  String _buildPlayerIframeUrl({
    required String rawUrl,
    required String sourceId,
    required String nextLink,
    required String title,
  }) {
    final value = normalizeText(rawUrl);
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.isEmpty || (sourceId != 'lzm3u8' && !value.startsWith('MCZY-'))) {
      return '';
    }
    return Uri.https('player.mcue.cc', '/yinhua/', <String, String>{
      'url': value,
      'next': nextLink.isEmpty ? '' : normalizeUrl(nextLink, _baseUrl),
      'title': normalizeText(title),
    }).toString();
  }
}

class _SearchMeta {
  const _SearchMeta({
    required this.year,
    required this.area,
    required this.categories,
  });

  final String year;
  final String area;
  final List<String> categories;
}
