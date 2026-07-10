import 'dart:convert';

import 'package:html/dom.dart';

import '../exceptions.dart';
import '../models/anime.dart';
import '../utils/http_client.dart';
import '../utils/parser.dart';
import 'base_provider.dart';
import 'search_policy.dart';

class _YhdmoeChapterLocator {
  const _YhdmoeChapterLocator({required this.animeId, required this.episodeId});

  final String animeId;
  final String episodeId;
}

class _YhdmoePlayRoute {
  const _YhdmoePlayRoute({
    required this.id,
    required this.config,
    required this.title,
    required this.sourceName,
  });

  final String id;
  final String config;
  final String title;
  final String sourceName;
}

/// 嘀哩嘀哩动漫 Provider。
class YhdmoeProvider implements BaseProvider {
  /// 创建嘀哩嘀哩动漫 Provider。
  YhdmoeProvider({AniHttpClient? httpClient})
    : httpClient = httpClient ?? AniHttpClient();

  /// HTTP 客户端。
  final AniHttpClient httpClient;

  static const String _baseUrl = 'https://yhdmoe.com';
  static final RegExp _detailPathPattern = RegExp(r'/watch/(?<animeId>\d+)');
  static final RegExp _chapterIdPattern = RegExp(
    r'^(?<animeId>\d+):(?<episodeId>[^:]+)$',
  );

  @override
  String get providerName => 'yhdmoe';

  @override
  Future<AnimeSearchResult> search(String keyword) async {
    final cleanedKeyword = normalizeText(keyword);
    if (cleanedKeyword.isEmpty) {
      throw const InvalidQueryParameterException('keyword 参数不能为空');
    }

    final searchPolicy = providerSearchPolicyFor(providerName);
    final html = await httpClient.getText(
      '$_baseUrl/search?q=${Uri.encodeQueryComponent(cleanedKeyword)}',
      referer: '$_baseUrl/',
      timeout: searchPolicy.timeout,
      retryTimes: searchPolicy.retryTimes,
    );
    final root = buildDocument(html).documentElement!;
    final cards = <String, AnimeCard>{};
    for (final link in root.querySelectorAll('a[href*="/watch/"]')) {
      final detailUrl = normalizeUrl(
        normalizeText(link.attributes['href']),
        _baseUrl,
      );
      final animeId = _extractAnimeId(detailUrl);
      final title = firstNonEmpty([
        selectText(link, '.h3'),
        selectText(link, 'h3'),
        link.attributes['title'],
        link.text,
      ]);
      if (animeId.isEmpty || title.isEmpty) {
        continue;
      }
      final image = link.querySelector('img');
      cards.putIfAbsent(
        animeId,
        () => AnimeCard(
          provider: providerName,
          animeId: animeId,
          title: title,
          cover: normalizeUrl(
            firstNonEmpty([
              image?.attributes['data-src'],
              image?.attributes['data-original'],
              image?.attributes['src'],
            ]),
            _baseUrl,
          ),
          detailUrl: detailUrl,
          categories: selectTexts(link, '.badge, .tag'),
          description: selectText(link, '.text-muted'),
        ),
      );
    }

    return AnimeSearchResult(
      provider: providerName,
      keyword: cleanedKeyword,
      total: cards.length,
      items: cards.values.toList(),
    );
  }

  @override
  Future<AnimeDetail> getDetail(String animeId) async {
    final normalizedAnimeId = _normalizeAnimeId(animeId);
    final root = await _fetchDetailRoot(normalizedAnimeId);
    final title = firstNonEmpty([
      selectText(root, 'h1'),
      _readMeta(root, 'meta[property="og:title"]'),
      _normalizePageTitle(selectText(root, 'title')),
    ]);
    if (title.isEmpty) {
      throw const ProviderParseException('yhdmoe 详情页解析失败，未找到标题');
    }

    final chapters = _extractChapters(root, normalizedAnimeId);
    return AnimeDetail(
      provider: providerName,
      animeId: normalizedAnimeId,
      title: title,
      cover: normalizeUrl(
        firstNonEmpty([
          _readMeta(root, 'meta[property="og:image"]'),
          selectAttr(root, 'img[src*="/poster"]', 'src'),
          selectAttr(root, 'img[data-src*="/poster"]', 'data-src'),
        ]),
        _baseUrl,
      ),
      description: firstNonEmpty([
        _readMeta(root, 'meta[name="description"]'),
        selectText(root, '.anime-summary'),
        selectText(root, '.card-text'),
      ]),
      latest: chapters.isEmpty ? '' : chapters.first.title,
      playUrl: chapters.isEmpty ? '' : chapters.first.playUrl,
      tags: selectTexts(root, '.badge, .tag'),
    );
  }

  @override
  Future<AnimeChapterList> getChapters(String animeId) async {
    final normalizedAnimeId = _normalizeAnimeId(animeId);
    final root = await _fetchDetailRoot(normalizedAnimeId);
    final chapters = _extractChapters(root, normalizedAnimeId);
    return AnimeChapterList(
      provider: providerName,
      animeId: normalizedAnimeId,
      groups: chapters.isEmpty
          ? const <AnimeChapterGroup>[]
          : <AnimeChapterGroup>[
              AnimeChapterGroup(
                sourceId: 'default',
                sourceName: '默认线路',
                items: chapters,
              ),
            ],
    );
  }

  @override
  Future<AnimeContent> getContent(String chapterId) async {
    final locator = _parseChapterLocator(chapterId);
    final routes = await _fetchPlayRoutes(locator);
    Object? lastError;
    for (final route in routes) {
      if (!_supportsRoute(route.config)) {
        continue;
      }
      try {
        final rawUrl = normalizeText(
          await httpClient.getText(
            '$_baseUrl/myapp/_get_raw?id=${Uri.encodeQueryComponent(route.id)}',
            referer: '$_baseUrl/watch/${locator.animeId}',
            headers: const <String, String>{
              'X-Requested-With': 'XMLHttpRequest',
            },
          ),
        );
        if (rawUrl.isEmpty || rawUrl == 'x') {
          continue;
        }
        final navigation = await _buildNavigation(locator);
        final videoType = detectVideoType(rawUrl);
        final isIframe = route.config == 'url' && videoType.isEmpty;
        return AnimeContent(
          provider: providerName,
          chapterId: _buildChapterId(locator.animeId, locator.episodeId),
          title: firstNonEmpty([route.title, locator.episodeId]),
          playUrl:
              '$_baseUrl/watch/${locator.animeId}'
              '#play_ep_${Uri.encodeComponent(locator.episodeId)}',
          sourceName: route.sourceName,
          sourceId: route.id,
          iframeUrl: isIframe ? normalizeUrl(rawUrl, _baseUrl) : '',
          videoUrl: isIframe ? '' : normalizeUrl(rawUrl, _baseUrl),
          videoType: isIframe ? '' : videoType,
          nextChapterId: navigation.nextChapterId,
          previousChapterId: navigation.previousChapterId,
        );
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw ProviderParseException(
      'yhdmoe 播放源解析失败${lastError == null ? '' : ': $lastError'}',
    );
  }

  Future<Element> _fetchDetailRoot(String animeId) async {
    final html = await httpClient.getText(
      '$_baseUrl/watch/$animeId',
      referer: '$_baseUrl/',
    );
    return buildDocument(html).documentElement!;
  }

  List<AnimeChapter> _extractChapters(Element root, String animeId) {
    final chapters = <AnimeChapter>[];
    final seenEpisodeIds = <String>{};
    for (final link in root.querySelectorAll('a.my-episode[play_ep]')) {
      final episodeId = normalizeText(link.attributes['play_ep']);
      if (episodeId.isEmpty || !seenEpisodeIds.add(episodeId)) {
        continue;
      }
      chapters.add(
        AnimeChapter(
          chapterId: _buildChapterId(animeId, episodeId),
          title: firstNonEmpty([
            link.attributes['show_name'],
            link.text,
            episodeId,
          ]),
          playUrl:
              '$_baseUrl/watch/$animeId'
              '#play_ep_${Uri.encodeComponent(episodeId)}',
        ),
      );
    }
    return chapters;
  }

  Future<List<_YhdmoePlayRoute>> _fetchPlayRoutes(
    _YhdmoeChapterLocator locator,
  ) async {
    final payload = await httpClient.getText(
      '$_baseUrl/myapp/_get_ep_plays'
      '?ep=${Uri.encodeQueryComponent(locator.episodeId)}'
      '&anime_id=${Uri.encodeQueryComponent(locator.animeId)}',
      referer: '$_baseUrl/watch/${locator.animeId}',
      headers: const <String, String>{
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
      },
    );
    final decoded = _decodeJsonObject(payload);
    final rawRoutes = decoded['result'];
    if (rawRoutes is! List) {
      throw const ProviderParseException('yhdmoe 播放接口缺少 result 数组');
    }
    final routes = <_YhdmoePlayRoute>[];
    for (final rawRoute in rawRoutes.whereType<Map>()) {
      final route = rawRoute.cast<String, Object?>();
      final id = normalizeText(route['id']);
      final config = normalizeText(route['cfg']);
      if (id.isEmpty || config.isEmpty) {
        continue;
      }
      routes.add(
        _YhdmoePlayRoute(
          id: id,
          config: config,
          title: normalizeText(route['name']),
          sourceName: normalizeText(route['src_site_tag']),
        ),
      );
    }
    if (routes.isEmpty) {
      throw const ProviderParseException('yhdmoe 当前剧集没有可用播放线路');
    }
    return routes;
  }

  Future<_ChapterNavigation> _buildNavigation(
    _YhdmoeChapterLocator locator,
  ) async {
    final chapterList = await getChapters(locator.animeId);
    if (chapterList.groups.isEmpty) {
      return const _ChapterNavigation();
    }
    final items = chapterList.groups.first.items;
    final currentId = _buildChapterId(locator.animeId, locator.episodeId);
    for (var index = 0; index < items.length; index += 1) {
      if (items[index].chapterId != currentId) {
        continue;
      }
      return _ChapterNavigation(
        previousChapterId: index > 0 ? items[index - 1].chapterId : '',
        nextChapterId: index < items.length - 1
            ? items[index + 1].chapterId
            : '',
      );
    }
    return const _ChapterNavigation();
  }

  Map<String, Object?> _decodeJsonObject(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, Object?>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.cast<String, Object?>();
      }
      throw const ProviderParseException('yhdmoe 接口响应不是 JSON 对象');
    } on FormatException catch (error) {
      throw ProviderParseException('yhdmoe 接口响应不是合法 JSON: $error');
    }
  }

  bool _supportsRoute(String config) =>
      const <String>{'m3u8', 'mp4', 'raw', 'raw_flash', 'url'}.contains(config);

  _YhdmoeChapterLocator _parseChapterLocator(String chapterId) {
    final normalized = normalizeText(chapterId);
    if (normalized.isEmpty) {
      throw const InvalidQueryParameterException('chapter_id 参数不能为空');
    }
    final match = _chapterIdPattern.firstMatch(normalized);
    if (match == null) {
      throw const InvalidQueryParameterException(
        'chapter_id 格式无效，yhdmoe 仅支持 {anime_id}:{episode_id}',
      );
    }
    return _YhdmoeChapterLocator(
      animeId: match.namedGroup('animeId')!,
      episodeId: match.namedGroup('episodeId')!,
    );
  }

  String _normalizeAnimeId(String animeId) {
    final normalized = normalizeText(animeId);
    if (normalized.isEmpty) {
      throw const InvalidQueryParameterException('anime_id 参数不能为空');
    }
    final extracted = _extractAnimeId(normalized);
    final result = extracted.isEmpty ? normalized : extracted;
    if (!RegExp(r'^\d+$').hasMatch(result)) {
      throw const InvalidQueryParameterException('anime_id 必须是数字');
    }
    return result;
  }

  String _extractAnimeId(String value) => normalizeText(
    _detailPathPattern.firstMatch(value)?.namedGroup('animeId'),
  );

  String _buildChapterId(String animeId, String episodeId) =>
      '$animeId:$episodeId';

  String _readMeta(Element root, String selector) =>
      normalizeText(root.querySelector(selector)?.attributes['content']);

  String _normalizePageTitle(String title) =>
      normalizeText(title.split('-').first);
}

class _ChapterNavigation {
  const _ChapterNavigation({
    this.nextChapterId = '',
    this.previousChapterId = '',
  });

  final String nextChapterId;
  final String previousChapterId;
}
