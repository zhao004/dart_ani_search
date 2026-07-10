import 'package:html/dom.dart';

import '../exceptions.dart';
import '../models/anime.dart';
import '../utils/http_client.dart';
import '../utils/parser.dart';
import 'base_provider.dart';

/// 西瓜卡通 Provider。
class XgCartoonProvider implements BaseProvider {
  /// 创建西瓜卡通 Provider。
  XgCartoonProvider({AniHttpClient? httpClient})
    : httpClient = httpClient ?? AniHttpClient();

  /// HTTP 客户端。
  final AniHttpClient httpClient;

  static const String _baseUrl = 'https://cn.xgcartoon.com';
  static final RegExp _detailPathPattern = RegExp(
    r'^/detail/(?<animeId>[^/?#]+)$',
  );

  @override
  String get providerName => 'xgcartoon';

  @override
  Future<AnimeSearchResult> search(String keyword) async {
    final cleanedKeyword = normalizeText(keyword);
    if (cleanedKeyword.isEmpty) {
      throw const InvalidQueryParameterException('keyword 参数不能为空');
    }

    final html = await httpClient.getText(
      '$_baseUrl/search?q=${Uri.encodeQueryComponent(cleanedKeyword)}',
      referer: '$_baseUrl/',
    );
    final root = buildDocument(html).documentElement!;
    final cards = <String, AnimeCard>{};
    for (final link in root.querySelectorAll(
      'a.topic-list-item[href^="/detail/"]',
    )) {
      final path = _normalizePath(link.attributes['href']);
      final animeId = _detailPathPattern
          .firstMatch(path)
          ?.namedGroup('animeId');
      final title = firstNonEmpty([
        selectText(link, '.h3'),
        selectText(link, 'h3'),
        link.attributes['title'],
      ]);
      if (animeId == null || animeId.isEmpty || title.isEmpty) {
        continue;
      }
      cards.putIfAbsent(
        animeId,
        () => AnimeCard(
          provider: providerName,
          animeId: animeId,
          title: title,
          cover: normalizeUrl(
            firstNonEmpty([
              selectAttr(link, 'amp-img', 'src'),
              selectAttr(link, 'img', 'src'),
            ]),
            _baseUrl,
          ),
          detailUrl: normalizeUrl(path, _baseUrl),
          categories: selectTexts(link, '.tag'),
          description: selectText(link, '.topic-list-item--author'),
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
      throw const ProviderParseException('xgcartoon 详情页解析失败，未找到标题');
    }

    final chapters = _extractChapters(root, normalizedAnimeId);
    return AnimeDetail(
      provider: providerName,
      animeId: normalizedAnimeId,
      title: title,
      cover: normalizeUrl(
        firstNonEmpty([
          _readMeta(root, 'meta[property="og:image"]'),
          selectAttr(root, 'amp-img[src*="/cover/"]', 'src'),
          selectAttr(root, 'img[src*="/cover/"]', 'src'),
        ]),
        _baseUrl,
      ),
      description: firstNonEmpty([
        _readMeta(root, 'meta[name="description"]'),
        _readMeta(root, 'meta[property="og:description"]'),
        selectText(root, '.topic-intro'),
        selectText(root, '.detail-intro'),
      ]),
      latest: chapters.isEmpty ? '' : chapters.first.title,
      playUrl: chapters.isEmpty ? '' : chapters.first.playUrl,
      tags: selectTexts(root, '.tag'),
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
    final normalizedChapterId = _normalizeChapterId(chapterId);
    final playUrl = normalizeUrl(normalizedChapterId, _baseUrl);
    final html = await httpClient.getText(playUrl, referer: '$_baseUrl/');
    final root = buildDocument(html).documentElement!;
    final iframeUrl = normalizeUrl(
      selectAttr(root, 'iframe[src]', 'src'),
      _baseUrl,
    );
    if (iframeUrl.isEmpty) {
      throw const ProviderParseException('xgcartoon 播放页解析失败，未找到 iframe');
    }

    final locator = _parseChapterUri(normalizedChapterId);
    final navigation = await _buildNavigation(
      locator.cartoonId,
      normalizedChapterId,
    );
    return AnimeContent(
      provider: providerName,
      chapterId: normalizedChapterId,
      title: firstNonEmpty([
        selectText(root, 'h1'),
        _normalizePageTitle(selectText(root, 'title')),
        locator.chapterId,
      ]),
      playUrl: playUrl,
      sourceName: Uri.tryParse(iframeUrl)?.host ?? '默认线路',
      sourceId: locator.chapterId,
      iframeUrl: iframeUrl,
      nextChapterId: navigation.nextChapterId,
      previousChapterId: navigation.previousChapterId,
    );
  }

  Future<Element> _fetchDetailRoot(String animeId) async {
    final html = await httpClient.getText(
      '$_baseUrl/detail/$animeId',
      referer: '$_baseUrl/',
    );
    return buildDocument(html).documentElement!;
  }

  List<AnimeChapter> _extractChapters(Element root, String animeId) {
    final chapters = <AnimeChapter>[];
    final seenChapterIds = <String>{};
    for (final link in root.querySelectorAll('a[href^="/user/page_direct?"]')) {
      final rawHref = normalizeText(link.attributes['href']);
      final normalizedChapterId = _normalizeChapterId(rawHref);
      final locator = _parseChapterUri(normalizedChapterId);
      if (locator.cartoonId != animeId ||
          !seenChapterIds.add(normalizedChapterId)) {
        continue;
      }
      chapters.add(
        AnimeChapter(
          chapterId: normalizedChapterId,
          title: firstNonEmpty([link.text, locator.chapterId]),
          playUrl: normalizeUrl(normalizedChapterId, _baseUrl),
        ),
      );
    }
    return chapters;
  }

  Future<_ChapterNavigation> _buildNavigation(
    String animeId,
    String chapterId,
  ) async {
    final chapterList = await getChapters(animeId);
    if (chapterList.groups.isEmpty) {
      return const _ChapterNavigation();
    }
    final items = chapterList.groups.first.items;
    for (var index = 0; index < items.length; index += 1) {
      if (items[index].chapterId != chapterId) {
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
    final uri = Uri.tryParse(normalized);
    final resolved = uri != null && uri.hasScheme
        ? uri
        : Uri.parse(_baseUrl).resolve(normalized);
    if (resolved.path != '/user/page_direct') {
      throw const InvalidQueryParameterException(
        'chapter_id 格式无效，xgcartoon 仅支持 /user/page_direct 查询地址',
      );
    }
    final cartoonId = normalizeText(resolved.queryParameters['cartoon_id']);
    final rawChapterId = normalizeText(resolved.queryParameters['chapter_id']);
    if (cartoonId.isEmpty || rawChapterId.isEmpty) {
      throw const InvalidQueryParameterException(
        'chapter_id 缺少 cartoon_id 或 chapter_id',
      );
    }
    return Uri(
      path: resolved.path,
      queryParameters: <String, String>{
        'cartoon_id': cartoonId,
        'chapter_id': rawChapterId,
      },
    ).toString();
  }

  _XgChapterLocator _parseChapterUri(String chapterId) {
    final uri = Uri.parse(normalizeUrl(chapterId, _baseUrl));
    return _XgChapterLocator(
      cartoonId: uri.queryParameters['cartoon_id']!,
      chapterId: uri.queryParameters['chapter_id']!,
    );
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

class _XgChapterLocator {
  const _XgChapterLocator({required this.cartoonId, required this.chapterId});

  final String cartoonId;
  final String chapterId;
}

class _ChapterNavigation {
  const _ChapterNavigation({
    this.nextChapterId = '',
    this.previousChapterId = '',
  });

  final String nextChapterId;
  final String previousChapterId;
}
