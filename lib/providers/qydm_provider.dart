import 'package:html/dom.dart';

import '../exceptions.dart';
import '../models/anime.dart';
import '../utils/http_client.dart';
import '../utils/parser.dart';
import 'base_provider.dart';
import 'search_policy.dart';

class _QydmPlaybackData {
  const _QydmPlaybackData({
    required this.sourceName,
    required this.videoId,
    required this.nextChapterId,
    required this.previousChapterId,
  });

  final String sourceName;
  final String videoId;
  final String nextChapterId;
  final String previousChapterId;
}

/// 奇艺动漫网 Provider。
class QydmProvider implements BaseProvider {
  /// 创建奇艺动漫网 Provider。
  QydmProvider({AniHttpClient? httpClient})
    : httpClient = httpClient ?? AniHttpClient();

  /// HTTP 客户端。
  final AniHttpClient httpClient;

  static const String _baseUrl = 'https://www.qydm.cc';
  static final RegExp _detailPathPattern = RegExp(r'^/v/(?<animeId>[^/?#]+)/$');
  static final RegExp _chapterPathPattern = RegExp(
    r'^/v/(?<animeId>[^/?#]+)/(?<episode>[^/?#]+)\.html$',
  );
  static final RegExp _packedScriptPattern = RegExp(
    r"""eval\(function\(p,a,c,k,e,d\).*?\}\('(?<payload>(?:\\.|[^'])*)',\s*(?<radix>\d+),\s*\d+,\s*'(?<keys>(?:\\.|[^'])*)'\.split\('\|'\)""",
    dotAll: true,
  );
  static final RegExp _playbackVariablePattern = RegExp(
    r"""var\s+(?<name>ps|pv|NextWebPage|PrevWebPage)\s*=\s*['"](?<value>.*?)['"]\s*;""",
  );

  @override
  String get providerName => 'qydm';

  @override
  Future<AnimeSearchResult> search(String keyword) async {
    final cleanedKeyword = normalizeText(keyword);
    if (cleanedKeyword.isEmpty) {
      throw const InvalidQueryParameterException('keyword 参数不能为空');
    }

    final searchPolicy = providerSearchPolicyFor(providerName);
    final html = await httpClient.postText(
      '$_baseUrl/search-',
      data: <String, String>{'wd': cleanedKeyword},
      referer: '$_baseUrl/',
      timeout: searchPolicy.timeout,
      retryTimes: searchPolicy.retryTimes,
    );
    final root = buildDocument(html).documentElement!;
    final cards = <String, AnimeCard>{};
    for (final link in root.querySelectorAll('a[href^="/v/"]')) {
      final path = _normalizePath(link.attributes['href']);
      final match = _detailPathPattern.firstMatch(path);
      if (match == null) {
        continue;
      }
      final animeId = match.namedGroup('animeId')!;
      final title = firstNonEmpty([
        link.attributes['title'],
        selectAttr(link, 'img', 'alt'),
        selectText(link, '.title'),
        selectText(link, 'h3'),
        link.text,
      ]);
      if (title.isEmpty ||
          (!title.contains(cleanedKeyword) &&
              !cleanedKeyword.contains(title) &&
              cards.containsKey(animeId))) {
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
              image?.attributes['data-original'],
              image?.attributes['data-src'],
              image?.attributes['src'],
            ]),
            _baseUrl,
          ),
          detailUrl: normalizeUrl(path, _baseUrl),
          latest: firstNonEmpty([
            selectText(link, '.continu'),
            selectText(link, '.status'),
          ]),
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
      selectText(root, '.anime_icon1 h1'),
      selectText(root, '.vod-info h1'),
      selectText(root, 'h1'),
      _readMeta(root, 'meta[property="og:title"]'),
    ]);
    if (title.isEmpty) {
      throw const ProviderParseException('qydm 详情页解析失败，未找到标题');
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
          selectAttr(root, '.anime_icon1 img', 'src'),
          selectAttr(root, '.vod-n-img img', 'src'),
        ]),
        _baseUrl,
      ),
      description: firstNonEmpty([
        selectText(root, '.vod_content'),
        selectText(root, '.info-content'),
        _readMeta(root, 'meta[name="description"]'),
      ]),
      latest: firstNonEmpty([
        selectText(root, '.continu'),
        selectText(root, '.info-update'),
      ]),
      playUrl: firstPlayUrl,
      tags: selectTexts(root, 'a[href*="/type/"]'),
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
    final normalizedChapterId = _normalizeChapterId(chapterId);
    final playUrl = normalizeUrl(normalizedChapterId, _baseUrl);
    final html = await httpClient.getText(playUrl, referer: '$_baseUrl/');
    final root = buildDocument(html).documentElement!;
    final playback = _extractPlaybackData(html);
    if (playback.videoId.isEmpty) {
      throw const ProviderParseException('qydm 播放页解析失败，未找到视频标识');
    }
    final iframeUrl = Uri.https('p1.qydm.cc', '/dp/', <String, String>{
      'url': playback.videoId,
    }).toString();

    return AnimeContent(
      provider: providerName,
      chapterId: normalizedChapterId,
      title: firstNonEmpty([
        selectText(root, '.d-playinfo h2'),
        _normalizePageTitle(selectText(root, 'title')),
        normalizedChapterId,
      ]),
      playUrl: playUrl,
      sourceName: playback.sourceName,
      sourceId: playback.sourceName,
      iframeUrl: iframeUrl,
      nextChapterId: playback.nextChapterId,
      previousChapterId: playback.previousChapterId,
    );
  }

  Future<Element> _fetchDetailRoot(String animeId) async {
    final html = await httpClient.getText(
      '$_baseUrl/v/$animeId/',
      referer: '$_baseUrl/',
    );
    return buildDocument(html).documentElement!;
  }

  List<AnimeChapterGroup> _extractChapterGroups(Element root, String animeId) {
    final groups = <AnimeChapterGroup>[];
    final seenPaths = <String>{};
    for (final container in root.querySelectorAll(r'[id$="-pl-list"]')) {
      final items = _extractChapterItems(container, animeId, seenPaths);
      if (items.isEmpty) {
        continue;
      }
      final containerId = normalizeText(container.id);
      final sourceId = containerId.endsWith('-pl-list')
          ? containerId.substring(0, containerId.length - '-pl-list'.length)
          : 'line${groups.length + 1}';
      final heading = container.parent?.querySelector('h2');
      groups.add(
        AnimeChapterGroup(
          sourceId: sourceId,
          sourceName: firstNonEmpty([
            heading?.attributes['title'],
            heading?.text,
            '线路${groups.length + 1}',
          ]),
          items: items,
        ),
      );
    }

    if (groups.isNotEmpty) {
      return groups;
    }
    final fallbackItems = _extractChapterItems(root, animeId, seenPaths);
    if (fallbackItems.isEmpty) {
      return const <AnimeChapterGroup>[];
    }
    return <AnimeChapterGroup>[
      AnimeChapterGroup(
        sourceId: 'default',
        sourceName: '默认线路',
        items: fallbackItems,
      ),
    ];
  }

  List<AnimeChapter> _extractChapterItems(
    Element container,
    String animeId,
    Set<String> seenPaths,
  ) {
    final items = <AnimeChapter>[];
    for (final link in container.querySelectorAll('a[href]')) {
      final path = _normalizePath(link.attributes['href']);
      final match = _chapterPathPattern.firstMatch(path);
      if (match == null ||
          match.namedGroup('animeId') != animeId ||
          !seenPaths.add(path)) {
        continue;
      }
      items.add(
        AnimeChapter(
          chapterId: path,
          title: firstNonEmpty([
            link.attributes['title'],
            link.text,
            match.namedGroup('episode'),
          ]),
          playUrl: normalizeUrl(path, _baseUrl),
        ),
      );
    }
    return items;
  }

  _QydmPlaybackData _extractPlaybackData(String html) {
    for (final match in _packedScriptPattern.allMatches(html)) {
      final decodedScript = _decodePackedScript(
        match.namedGroup('payload') ?? '',
        match.namedGroup('keys') ?? '',
        int.tryParse(match.namedGroup('radix') ?? '') ?? 36,
      );
      final values = <String, String>{};
      for (final variableMatch in _playbackVariablePattern.allMatches(
        decodedScript,
      )) {
        values[variableMatch.namedGroup('name')!] = normalizeText(
          variableMatch.namedGroup('value'),
        );
      }
      final videoId = values['pv'] ?? '';
      if (videoId.isEmpty) {
        continue;
      }
      return _QydmPlaybackData(
        sourceName: values['ps'] ?? '',
        videoId: videoId,
        nextChapterId: _normalizeNavigationPath(values['NextWebPage']),
        previousChapterId: _normalizeNavigationPath(values['PrevWebPage']),
      );
    }
    throw const ProviderParseException('qydm 播放页缺少可识别的播放配置');
  }

  String _decodePackedScript(String rawPayload, String rawKeys, int radix) {
    var payload = _unescapeJavaScriptString(rawPayload);
    final keys = _unescapeJavaScriptString(rawKeys).split('|');
    payload = payload.replaceAllMapped(RegExp(r'\b[0-9a-z]+\b'), (match) {
      final token = match.group(0)!;
      final index = int.tryParse(token, radix: radix);
      if (index == null || index < 0 || index >= keys.length) {
        return token;
      }
      final replacement = keys[index];
      return replacement.isEmpty ? token : replacement;
    });
    return payload;
  }

  String _unescapeJavaScriptString(String value) => value
      .replaceAll(r"\'", "'")
      .replaceAll(r'\"', '"')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\r')
      .replaceAll(r'\\', '\\');

  String _normalizeAnimeId(String animeId) {
    final normalized = normalizeText(animeId);
    if (normalized.isEmpty) {
      throw const InvalidQueryParameterException('anime_id 参数不能为空');
    }
    final path = _normalizePath(normalized);
    final extracted = _detailPathPattern
        .firstMatch(path)
        ?.namedGroup('animeId');
    final result = normalizeText(extracted ?? normalized);
    if (result.contains('/') || result.contains('?')) {
      throw const InvalidQueryParameterException('anime_id 格式无效');
    }
    return result;
  }

  String _normalizeChapterId(String chapterId) {
    final normalized = normalizeText(chapterId);
    if (normalized.isEmpty) {
      throw const InvalidQueryParameterException('chapter_id 参数不能为空');
    }
    final path = _normalizePath(normalized);
    if (!_chapterPathPattern.hasMatch(path)) {
      throw const InvalidQueryParameterException(
        'chapter_id 格式无效，qydm 仅支持 /v/{anime_id}/{episode}.html',
      );
    }
    return path;
  }

  String _normalizeNavigationPath(String? value) {
    final normalized = normalizeText(value);
    if (normalized.isEmpty || normalized == '0') {
      return '';
    }
    final path = _normalizePath(normalized);
    return _chapterPathPattern.hasMatch(path) ? path : '';
  }

  String _normalizePath(Object? value) {
    final normalized = normalizeText(value);
    if (normalized.isEmpty) {
      return '';
    }
    final uri = Uri.tryParse(normalized);
    if (uri != null && uri.hasScheme) {
      return uri.path;
    }
    return normalized.startsWith('/') ? normalized : '/$normalized';
  }

  String _readMeta(Element root, String selector) =>
      normalizeText(root.querySelector(selector)?.attributes['content']);

  String _normalizePageTitle(String title) =>
      normalizeText(title.split('-').first);
}
