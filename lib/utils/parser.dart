import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// 构建 HTML 文档，统一隔离解析库调用。
Document buildDocument(String html) => html_parser.parse(html);

/// 清洗文本中的连续空白和不可见字符。
String normalizeText(Object? value) {
  final text = (value ?? '').toString();
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 返回第一个非空字符串，用于复用站点页面的多个候选字段。
String firstNonEmpty(Iterable<Object?> values) {
  for (final value in values) {
    final normalized = normalizeText(value);
    if (normalized.isNotEmpty) {
      return normalized;
    }
  }
  return '';
}

/// 读取 CSS 选择器匹配到的文本。
String selectText(Element node, String selector, {String defaultValue = ''}) {
  final element = node.querySelector(selector);
  if (element == null) {
    return defaultValue;
  }
  return normalizeText(element.text);
}

/// 读取 CSS 选择器匹配到的属性。
String selectAttr(
  Element node,
  String selector,
  String attr, {
  String defaultValue = '',
}) {
  final element = node.querySelector(selector);
  if (element == null) {
    return defaultValue;
  }
  return normalizeText(element.attributes[attr]);
}

/// 读取 CSS 选择器匹配到的多个文本。
List<String> selectTexts(Element node, String selector) => node
    .querySelectorAll(selector)
    .map((element) => normalizeText(element.text))
    .where((text) => text.isNotEmpty)
    .toList();

/// 从详情页地址中提取数字 ID，兼容 `/v/123.html`、`/show/123.html` 等路径。
String extractAnimeIdFromDetailUrl(String value) {
  final normalized = normalizeText(value);
  final patterns = <RegExp>[
    RegExp(r'/v/(?<id>[^/?#]+)\.html'),
    RegExp(r'/show/(?<id>[^/?#]+)\.html'),
    RegExp(r'/voddetail/(?<id>[^/?#]+)/?'),
    RegExp(r'/details/(?<id>[^/?#]+)'),
    RegExp(r'/detail/(?<id>[^/?#]+)'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(normalized);
    final id = match?.namedGroup('id');
    if (id != null && id.isNotEmpty) {
      return id;
    }
  }
  return '';
}

/// 从播放页地址中提取章节 ID。
String extractChapterIdFromPlayUrl(String value) {
  final normalized = normalizeText(value);
  final patterns = <RegExp>[
    RegExp(r'/p/(?<id>[^/?#]+)\.html'),
    RegExp(r'/vodplay/(?<id>[^/?#]+)\.html'),
    RegExp(r'/player/(?<play>[^/?#]+)/(?<episode>[^/?#]+)'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(normalized);
    if (match == null) {
      continue;
    }
    final id = match.namedGroup('id');
    if (id != null && id.isNotEmpty) {
      return id;
    }
    final play = match.namedGroup('play');
    final episode = match.namedGroup('episode');
    if (play != null && episode != null) {
      return '$play:$episode';
    }
  }
  return '';
}

/// 合并站点根地址和相对 URL，保留完整外部地址。
String normalizeUrl(String rawUrl, String baseUrl) {
  final value = normalizeText(rawUrl);
  if (value.isEmpty) {
    return '';
  }
  if (value.startsWith('//')) {
    return 'https:$value';
  }
  final parsed = Uri.tryParse(value);
  if (parsed != null && parsed.hasScheme) {
    return value;
  }
  return Uri.parse(baseUrl).resolve(value).toString();
}

/// 根据播放地址粗略识别视频类型。
String detectVideoType(String videoUrl) {
  final lower = normalizeText(videoUrl).toLowerCase();
  if (lower.contains('.m3u8')) {
    return 'm3u8';
  }
  if (lower.contains('.mp4')) {
    return 'mp4';
  }
  return '';
}

/// 按斜杠和逗号拆分人员或标签列表。
List<String> splitLooseList(String value) {
  final normalized = normalizeText(value);
  if (normalized.isEmpty) {
    return const <String>[];
  }
  final items = <String>[];
  for (final slashPart in normalized.split('/')) {
    for (final commaPart in slashPart.split(',')) {
      final item = normalizeText(commaPart);
      if (item.isNotEmpty) {
        items.add(item);
      }
    }
  }
  return items;
}
