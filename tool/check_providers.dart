import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ani_search/models/anime.dart';
import 'package:dart_ani_search/providers/base_provider.dart';
import 'package:dart_ani_search/providers/providers.dart';

const String _defaultKeyword = '海贼王';
const Duration _defaultTimeout = Duration(seconds: 30);

Future<void> main(List<String> args) async {
  final keyword = _normalizeKeyword(args);
  final providers = buildDefaultProviders();
  if (providers.isEmpty) {
    stderr.writeln('没有可测试的默认源站。');
    exitCode = 1;
    return;
  }

  final results = <Map<String, Object?>>[];
  for (final entry in providers.entries) {
    results.add(await _checkProvider(entry.key, entry.value, keyword));
  }

  stdout.writeln(const JsonEncoder.withIndent('  ').convert(results));
  final usableCount = results.where((item) => item['usable'] == true).length;
  if (usableCount < providers.length) {
    stderr.writeln('可用源站 $usableCount/${providers.length}，请检查失败源站。');
    exitCode = 1;
  }
}

String _normalizeKeyword(List<String> args) {
  if (args.isEmpty) {
    return _defaultKeyword;
  }
  final keyword = args.join(' ').trim();
  if (keyword.isEmpty) {
    throw ArgumentError('搜索关键词不能为空。');
  }
  return keyword;
}

Future<Map<String, Object?>> _checkProvider(
  String name,
  BaseProvider provider,
  String keyword,
) async {
  final startedAt = DateTime.now();
  try {
    final searchResult = await provider
        .search(keyword)
        .timeout(_defaultTimeout);
    if (searchResult.items.isEmpty) {
      return _failure(name, startedAt, '搜索结果为空');
    }

    final candidates = _selectSearchCandidates(searchResult.items, keyword);
    String lastReason = '没有可测试的搜索结果';
    AnimeCard? lastItem;
    for (final item in candidates) {
      lastItem = item;
      try {
        final detail = await provider
            .getDetail(item.animeId)
            .timeout(_defaultTimeout);
        if (detail.title.trim().isEmpty) {
          lastReason = '${item.title}: 详情标题为空';
          continue;
        }

        final chapters = await provider
            .getChapters(item.animeId)
            .timeout(_defaultTimeout);
        final chapterCount = chapters.groups.fold<int>(
          0,
          (total, group) => total + group.items.length,
        );
        if (chapterCount <= 0) {
          lastReason = '${item.title}: 章节列表为空';
          continue;
        }

        final contentProbe = await _probePlayableContent(provider, chapters);
        if (contentProbe.content == null || contentProbe.chapter == null) {
          lastReason = '${item.title}: ${contentProbe.error}';
          continue;
        }
        final content = contentProbe.content!;
        final testedChapter = contentProbe.chapter!;

        return <String, Object?>{
          'provider': name,
          'usable': true,
          'keyword': keyword,
          'search_total': searchResult.total,
          'tested_title': item.title,
          'anime_id': item.animeId,
          'detail_title': detail.title,
          'chapter_groups': chapters.groups.length,
          'chapter_total': chapterCount,
          'tested_chapter_id': testedChapter.chapterId,
          'tested_chapter_title': testedChapter.title,
          'content_source': content.sourceName,
          'video_type': content.videoType,
          'has_video_url': content.videoUrl.trim().isNotEmpty,
          'has_iframe_url': content.iframeUrl.trim().isNotEmpty,
          'elapsed_ms': _elapsedMs(startedAt),
        };
      } on Object catch (error) {
        lastReason = '${item.title}: $error';
      }
    }
    return _failure(
      name,
      startedAt,
      '搜索结果均无法完成播放链路: $lastReason',
      searchResult,
      lastItem,
    );
  } on TimeoutException {
    return _failure(name, startedAt, '请求超时');
  } on Object catch (error) {
    return _failure(name, startedAt, error.toString());
  }
}

List<AnimeCard> _selectSearchCandidates(List<AnimeCard> items, String keyword) {
  const maxCandidates = 24;
  final normalizedKeyword = _normalizeComparable(keyword);
  final candidates = [...items];
  candidates.sort((left, right) {
    final leftScore = _searchCandidateScore(left.title, normalizedKeyword);
    final rightScore = _searchCandidateScore(right.title, normalizedKeyword);
    return rightScore.compareTo(leftScore);
  });
  return candidates.take(maxCandidates).toList();
}

int _searchCandidateScore(String title, String normalizedKeyword) {
  final normalizedTitle = _normalizeComparable(title);
  if (normalizedTitle == normalizedKeyword) {
    return 3;
  }
  if (normalizedTitle.contains(normalizedKeyword)) {
    return 2;
  }
  if (normalizedKeyword.contains(normalizedTitle)) {
    return 1;
  }
  return 0;
}

String _normalizeComparable(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s\-—_：:（）()【】\[\]]+'), '');

Future<_ContentProbe> _probePlayableContent(
  BaseProvider provider,
  AnimeChapterList chapters,
) async {
  final candidates = _selectContentCandidates(chapters);
  Object? lastError;
  for (final chapter in candidates) {
    try {
      final content = await provider
          .getContent(chapter.chapterId)
          .timeout(_defaultTimeout);
      if (content.playUrl.trim().isEmpty) {
        lastError = StateError('播放页地址为空');
        continue;
      }
      if (content.videoUrl.trim().isEmpty && content.iframeUrl.trim().isEmpty) {
        lastError = StateError('视频直链和 iframe 地址均为空');
        continue;
      }
      return _ContentProbe(chapter: chapter, content: content);
    } on Object catch (error) {
      lastError = error;
    }
  }
  return _ContentProbe(
    error: candidates.isEmpty
        ? '没有可测试章节'
        : (lastError?.toString() ?? '所有候选章节均不可播放'),
  );
}

List<AnimeChapter> _selectContentCandidates(AnimeChapterList chapters) {
  const maxCandidates = 8;
  final candidates = <AnimeChapter>[];
  final seenChapterIds = <String>{};

  void addCandidate(AnimeChapter chapter) {
    if (candidates.length >= maxCandidates ||
        !seenChapterIds.add(chapter.chapterId)) {
      return;
    }
    candidates.add(chapter);
  }

  for (final group in chapters.groups) {
    if (group.items.isEmpty) {
      continue;
    }
    addCandidate(group.items.first);
    addCandidate(group.items[group.items.length ~/ 2]);
    addCandidate(group.items.last);
    if (candidates.length >= maxCandidates) {
      break;
    }
  }
  return candidates;
}

Map<String, Object?> _failure(
  String name,
  DateTime startedAt,
  String reason, [
  AnimeSearchResult? searchResult,
  AnimeCard? firstItem,
]) => <String, Object?>{
  'provider': name,
  'usable': false,
  'reason': reason,
  if (searchResult != null) 'search_total': searchResult.total,
  if (firstItem != null) 'candidate_title': firstItem.title,
  if (firstItem != null) 'anime_id': firstItem.animeId,
  'elapsed_ms': _elapsedMs(startedAt),
};

int _elapsedMs(DateTime startedAt) =>
    DateTime.now().difference(startedAt).inMilliseconds;

class _ContentProbe {
  const _ContentProbe({this.chapter, this.content, this.error = ''});

  final AnimeChapter? chapter;
  final AnimeContent? content;
  final String error;
}
