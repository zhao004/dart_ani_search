import 'dart:convert';

import 'package:html/dom.dart';

import '../exceptions.dart';
import '../models/anime.dart';
import '../utils/http_client.dart';
import '../utils/parser.dart';
import 'base_provider.dart';

class _HmgdmChapterLocator {
  const _HmgdmChapterLocator({required this.playId, required this.episodeId});

  final String playId;
  final String episodeId;
}

/// 哈密瓜动漫 Provider。
class HmgdmProvider implements BaseProvider {
  /// 创建哈密瓜动漫 Provider。
  HmgdmProvider({AniHttpClient? httpClient})
    : httpClient = httpClient ?? AniHttpClient();

  /// HTTP 客户端。
  final AniHttpClient httpClient;

  static const String _baseUrl = 'https://hmgdm.com';
  static final RegExp _animeIdPattern = RegExp(r'/details/(?<animeId>[^/?#]+)');
  static final RegExp _playerUrlPattern = RegExp(
    r'/player/(?<playId>[^/?#]+)/(?<episodeId>[^/?#]+)',
  );
  static final RegExp _chapterIdPattern = RegExp(
    r'^(?<playId>[^:]+):(?<episodeId>[^:]+)$',
  );
  static final RegExp _backgroundUrlPattern = RegExp(
    r'''url\(["']?(?<url>[^)"']+)''',
  );
  static final RegExp _episodesDataPattern = RegExp(
    r'const\s+episodesData\s*=\s*(?<data>\{.*?\})\s*;\s*const\s+vodID',
    dotAll: true,
  );
  static final RegExp _unquotedKeyPattern = RegExp(
    r'([{\[,]\s*)(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*:',
  );
  static final RegExp _trailingCommaPattern = RegExp(r',(\s*[\]}])');
  static final RegExp _channelNamePattern = RegExp(
    r'''const\s+channelName\s*=\s*(["'])(?<channel>.*?)\1''',
  );
  static final RegExp _playerInitPattern = RegExp(
    r'''initDplayer\(\s*(?<quote>["'])(?<videoUrl>.+?)\k<quote>\s*,\s*(?<playId>\d+)\s*,\s*(?<episodeId>\d+)\s*,\s*\d+\s*,\s*\d+\s*,\s*(?<nextQuote>["'])(?<nextPath>.*?)\k<nextQuote>\s*,\s*(?<vodQuote>["'])(?<vodIds>.*?)\k<vodQuote>\s*\)''',
    dotAll: true,
  );

  @override
  String get providerName => 'hmgdm';

  @override
  Future<AnimeSearchResult> search(String keyword) async {
    final cleanedKeyword = normalizeText(keyword);
    if (cleanedKeyword.isEmpty) {
      throw const InvalidQueryParameterException('keyword 参数不能为空');
    }

    final html = await httpClient.getText(
      '$_baseUrl/search?kw=${Uri.encodeComponent(cleanedKeyword)}',
      referer: '$_baseUrl/',
    );
    final document = buildDocument(html);
    final items = document
        .querySelectorAll('a.video')
        .map(_parseSearchCard)
        .whereType<AnimeCard>()
        .toList();
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
    final html = await _fetchDetailHtml(normalizedAnimeId);
    final document = buildDocument(html);
    final root = document.documentElement!;
    final title = selectText(root, '.details h1');
    if (title.isEmpty) {
      throw const ProviderParseException('hmgdm 详情页解析失败，未找到标题');
    }

    final fields = _extractDetailFields(root);
    final chapterGroups = _extractChapterGroups(html, root);
    var playUrl = normalizeUrl(
      selectAttr(root, 'a.play-btn', 'href'),
      _baseUrl,
    );
    if (playUrl.isEmpty &&
        chapterGroups.isNotEmpty &&
        chapterGroups.first.items.isNotEmpty) {
      playUrl = chapterGroups.first.items.first.playUrl;
    }

    return AnimeDetail(
      provider: providerName,
      animeId: normalizedAnimeId,
      title: title,
      cover: normalizeUrl(selectAttr(root, 'img.details-img', 'src'), _baseUrl),
      description: fields['description'] ?? '',
      latest: fields['latest'] ?? '',
      updateTime: fields['update_time'] ?? '',
      year: fields['year'] ?? '',
      area: fields['area'] ?? '',
      playUrl: playUrl,
      director: splitLooseList(fields['director'] ?? ''),
      actors: splitLooseList(fields['actors'] ?? ''),
      tags: _buildTags(fields['category'] ?? '', fields['language'] ?? ''),
    );
  }

  @override
  Future<AnimeChapterList> getChapters(String animeId) async {
    final normalizedAnimeId = _normalizeAnimeId(animeId);
    final html = await _fetchDetailHtml(normalizedAnimeId);
    final document = buildDocument(html);
    return AnimeChapterList(
      provider: providerName,
      animeId: normalizedAnimeId,
      groups: _extractChapterGroups(html, document.documentElement!),
    );
  }

  @override
  Future<AnimeContent> getContent(String chapterId) async {
    final locator = _parseChapterLocator(chapterId);
    final playUrl = '$_baseUrl/player/${locator.playId}/${locator.episodeId}';
    final html = await httpClient.getText(playUrl, referer: '$_baseUrl/');
    final document = buildDocument(html);
    final root = document.documentElement!;
    final playPayload = _extractPlayerPayload(html);
    final currentLineName = firstNonEmpty([
      selectAttr(
        root,
        '#episode-container .play-list.active-episode',
        'data-line',
      ),
      selectAttr(root, '#episode-container .play-list.active-episode', 'id'),
      _extractChannelName(html),
    ]);
    if (currentLineName.isEmpty) {
      throw const ProviderParseException('hmgdm 播放页解析失败，未找到当前播放线路');
    }

    final chapterGroups = _extractChapterGroups(html, root);
    final currentGroup = _findChapterGroup(chapterGroups, currentLineName);
    final currentChapterId = _buildChapterId(locator.playId, locator.episodeId);
    final sortedItems = [...currentGroup.items]..sort(_compareChapter);
    final position = _findChapterPosition(sortedItems, currentChapterId);
    final previousChapterId = position > 0
        ? sortedItems[position - 1].chapterId
        : '';
    var nextChapterId = _parseNextChapterId(playPayload.nextPath);
    if (nextChapterId.isEmpty && position < sortedItems.length - 1) {
      nextChapterId = sortedItems[position + 1].chapterId;
    }

    return AnimeContent(
      provider: providerName,
      chapterId: currentChapterId,
      title: selectText(root, 'h1'),
      playUrl: playUrl,
      sourceName: currentGroup.sourceName,
      sourceId: currentGroup.sourceId,
      videoUrl: playPayload.videoUrl,
      videoType: detectVideoType(playPayload.videoUrl),
      nextChapterId: nextChapterId,
      previousChapterId: previousChapterId,
    );
  }

  AnimeCard? _parseSearchCard(Element node) {
    final detailUrl = normalizeUrl(
      normalizeText(node.attributes['href']),
      _baseUrl,
    );
    final animeId = _extractAnimeId(detailUrl);
    final title = selectText(node, '.title p');
    if (animeId.isEmpty || title.isEmpty) {
      return null;
    }

    return AnimeCard(
      provider: providerName,
      animeId: animeId,
      title: title,
      cover: _extractCardCover(node),
      detailUrl: detailUrl,
      latest: selectText(node, '.desc > .desc'),
    );
  }

  Future<String> _fetchDetailHtml(String animeId) =>
      httpClient.getText('$_baseUrl/details/$animeId', referer: '$_baseUrl/');

  Map<String, String> _extractDetailFields(Element root) {
    final fields = <String, String>{
      'latest': '',
      'actors': '',
      'director': '',
      'year': '',
      'area': '',
      'category': '',
      'language': '',
      'update_time': '',
      'description': '',
    };
    for (final node in root.querySelectorAll('.details li.info')) {
      final labelNode = node.querySelector('span');
      if (labelNode == null) {
        continue;
      }
      final labelText = normalizeText(labelNode.text);
      final label = labelText.replaceAll(RegExp(r'[：:]$'), '');
      final value = normalizeText(
        normalizeText(node.text).replaceFirst(labelText, ''),
      );
      switch (label) {
        case '状态':
          fields['latest'] = value;
        case '主演':
          fields['actors'] = value;
        case '导演':
          fields['director'] = value;
        case '年份':
          fields['year'] = value;
        case '地区':
          fields['area'] = value;
        case '类型':
          fields['category'] = value;
        case '语言':
          fields['language'] = value;
        case '更新':
          fields['update_time'] = value;
        case '简介':
          fields['description'] = value;
      }
    }

    if ((fields['description'] ?? '').isEmpty) {
      final descriptionNode = root.querySelector('.details li.desc2');
      if (descriptionNode != null) {
        final labelText = normalizeText(
          descriptionNode.querySelector('span')?.text,
        );
        fields['description'] = normalizeText(
          normalizeText(descriptionNode.text).replaceFirst(labelText, ''),
        );
      }
    }
    return fields;
  }

  List<AnimeChapterGroup> _extractChapterGroups(String html, Element root) {
    final playlistNode = root.querySelector('#playlist');
    if (playlistNode != null &&
        playlistNode.querySelector('li.episode') != null) {
      final lineNames = _extractLineNames(root);
      final groups = <AnimeChapterGroup>[];
      for (final lineName in lineNames) {
        final items = <AnimeChapter>[];
        for (final chapterNode in playlistNode.querySelectorAll('li.episode')) {
          final classes = chapterNode.classes;
          if (!classes.contains(lineName) &&
              !classes.contains('line-$lineName')) {
            continue;
          }
          final link = chapterNode.querySelector('a[href^="/player/"]');
          if (link == null) {
            continue;
          }
          final href = normalizeText(link.attributes['href']);
          final locator = _extractPlayerLocatorFromUrl(href);
          if (locator == null) {
            continue;
          }
          items.add(
            AnimeChapter(
              chapterId: _buildChapterId(locator.playId, locator.episodeId),
              title: normalizeText(link.text),
              playUrl: normalizeUrl(href, _baseUrl),
            ),
          );
        }
        if (items.isNotEmpty) {
          groups.add(
            AnimeChapterGroup(
              sourceId: lineName,
              sourceName: lineName,
              items: items,
            ),
          );
        }
      }
      if (groups.isNotEmpty) {
        return groups;
      }
    }

    final episodeMap = _extractEpisodeMap(html);
    return episodeMap.entries
        .map((entry) {
          final items = entry.value
              .map((episode) {
                final path = normalizeUrl(
                  episode['path']?.toString() ?? '',
                  _baseUrl,
                );
                final title = normalizeText(episode['name']);
                final locator = _extractPlayerLocatorFromUrl(path);
                if (locator == null || title.isEmpty) {
                  return null;
                }
                return AnimeChapter(
                  chapterId: _buildChapterId(locator.playId, locator.episodeId),
                  title: title,
                  playUrl: path,
                );
              })
              .whereType<AnimeChapter>()
              .toList();
          if (items.isEmpty) {
            return null;
          }
          return AnimeChapterGroup(
            sourceId: entry.key,
            sourceName: entry.key,
            items: items,
          );
        })
        .whereType<AnimeChapterGroup>()
        .toList();
  }

  List<String> _extractLineNames(Element root) => root
      .querySelectorAll('#episode-container .play-list')
      .map((node) => firstNonEmpty([node.attributes['data-line'], node.text]))
      .where((value) => value.isNotEmpty)
      .toList();

  Map<String, List<Map<String, Object?>>> _extractEpisodeMap(String html) {
    final match = _episodesDataPattern.firstMatch(html);
    final rawData = match?.namedGroup('data');
    if (rawData == null || rawData.isEmpty) {
      return const <String, List<Map<String, Object?>>>{};
    }
    final normalizedJson = rawData
        .replaceAllMapped(
          _unquotedKeyPattern,
          (match) => '${match.group(1)}"${match.group(2)}":',
        )
        .replaceAllMapped(_trailingCommaPattern, (match) => match.group(1)!);
    try {
      final decoded = jsonDecode(normalizedJson);
      if (decoded is! Map) {
        throw const ProviderParseException('hmgdm 章节数据解析失败，episodesData 结构异常');
      }
      final result = <String, List<Map<String, Object?>>>{};
      for (final entry in decoded.entries) {
        final key = normalizeText(entry.key);
        final value = entry.value;
        if (key.isEmpty || value is! List) {
          continue;
        }
        result[key] = value
            .whereType<Map>()
            .map((item) => item.cast<String, Object?>())
            .toList();
      }
      return result;
    } on FormatException catch (error) {
      throw ProviderParseException(
        'hmgdm 章节数据解析失败，episodesData 不是合法 JSON: $error',
      );
    }
  }

  String _extractChannelName(String html) => normalizeText(
    _channelNamePattern.firstMatch(html)?.namedGroup('channel'),
  );

  String _extractCardCover(Element node) {
    final imageBox = node.querySelector('.img-box');
    if (imageBox == null) {
      return '';
    }
    final dataUrl = normalizeText(imageBox.attributes['data']);
    if (dataUrl.isNotEmpty) {
      return normalizeUrl(dataUrl, _baseUrl);
    }
    final styleValue = normalizeText(imageBox.attributes['style']);
    final match = _backgroundUrlPattern.firstMatch(styleValue);
    return normalizeUrl(match?.namedGroup('url') ?? '', _baseUrl);
  }

  _HmgdmPlayPayload _extractPlayerPayload(String html) {
    final match = _playerInitPattern.firstMatch(html);
    if (match == null) {
      throw const ProviderParseException('hmgdm 播放页解析失败，未找到 initDplayer');
    }
    final videoUrl = normalizeUrl(match.namedGroup('videoUrl') ?? '', _baseUrl);
    if (videoUrl.isEmpty) {
      throw const ProviderParseException('hmgdm 播放页解析失败，未找到真实播放地址');
    }
    return _HmgdmPlayPayload(
      videoUrl: videoUrl,
      nextPath: normalizeText(match.namedGroup('nextPath')),
    );
  }

  String _normalizeAnimeId(String animeId) {
    final normalized = normalizeText(animeId);
    if (normalized.isEmpty) {
      throw const InvalidQueryParameterException('anime_id 参数不能为空');
    }
    final extracted = _extractAnimeId(normalized);
    return extracted.isNotEmpty ? extracted : normalized;
  }

  _HmgdmChapterLocator _parseChapterLocator(String chapterId) {
    final normalized = normalizeText(chapterId);
    if (normalized.isEmpty) {
      throw const InvalidQueryParameterException('chapter_id 参数不能为空');
    }
    final locator = _extractPlayerLocatorFromUrl(normalized);
    if (locator != null) {
      return locator;
    }
    final match = _chapterIdPattern.firstMatch(normalized);
    if (match == null) {
      throw const InvalidQueryParameterException(
        'chapter_id 格式无效，hmgdm 仅支持 {play_id}:{episode_id} 或 /player/{play_id}/{episode_id}',
      );
    }
    final playId = normalizeText(match.namedGroup('playId'));
    final episodeId = normalizeText(match.namedGroup('episodeId'));
    if (playId.isEmpty || episodeId.isEmpty) {
      throw const InvalidQueryParameterException('chapter_id 参数不能为空');
    }
    return _HmgdmChapterLocator(playId: playId, episodeId: episodeId);
  }

  String _extractAnimeId(String value) =>
      normalizeText(_animeIdPattern.firstMatch(value)?.namedGroup('animeId'));

  _HmgdmChapterLocator? _extractPlayerLocatorFromUrl(String value) {
    final match = _playerUrlPattern.firstMatch(value);
    if (match == null) {
      return null;
    }
    return _HmgdmChapterLocator(
      playId: normalizeText(match.namedGroup('playId')),
      episodeId: normalizeText(match.namedGroup('episodeId')),
    );
  }

  String _buildChapterId(String playId, String episodeId) =>
      '${normalizeText(playId)}:${normalizeText(episodeId)}';

  String _parseNextChapterId(String nextPath) {
    final locator = _extractPlayerLocatorFromUrl(nextPath);
    return locator == null
        ? ''
        : _buildChapterId(locator.playId, locator.episodeId);
  }

  int _compareChapter(AnimeChapter left, AnimeChapter right) {
    final leftKey = _chapterSortKey(left);
    final rightKey = _chapterSortKey(right);
    final episodeCompare = leftKey.episodeOrder.compareTo(
      rightKey.episodeOrder,
    );
    return episodeCompare != 0
        ? episodeCompare
        : leftKey.title.compareTo(rightKey.title);
  }

  _ChapterSortKey _chapterSortKey(AnimeChapter chapter) {
    final locator = _parseChapterLocator(chapter.chapterId);
    return _ChapterSortKey(
      episodeOrder: int.tryParse(locator.episodeId) ?? 1000000000,
      title: chapter.title,
    );
  }

  AnimeChapterGroup _findChapterGroup(
    List<AnimeChapterGroup> groups,
    String sourceId,
  ) {
    for (final group in groups) {
      if (group.sourceId == sourceId) {
        return group;
      }
    }
    throw const ProviderParseException('hmgdm 播放页解析失败，未找到当前播放线路的章节列表');
  }

  int _findChapterPosition(List<AnimeChapter> chapters, String chapterId) {
    for (var index = 0; index < chapters.length; index += 1) {
      if (chapters[index].chapterId == chapterId) {
        return index;
      }
    }
    throw const ProviderParseException('hmgdm 播放页解析失败，未找到当前章节在列表中的位置');
  }

  List<String> _buildTags(String category, String language) {
    final tags = <String>[];
    for (final value in [category, language]) {
      final normalized = normalizeText(value);
      if (normalized.isNotEmpty && !tags.contains(normalized)) {
        tags.add(normalized);
      }
    }
    return tags;
  }
}

class _HmgdmPlayPayload {
  const _HmgdmPlayPayload({required this.videoUrl, required this.nextPath});

  final String videoUrl;
  final String nextPath;
}

class _ChapterSortKey {
  const _ChapterSortKey({required this.episodeOrder, required this.title});

  final int episodeOrder;
  final String title;
}
