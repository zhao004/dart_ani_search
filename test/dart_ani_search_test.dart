import 'package:dart_ani_search/dart_ani_search.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProvider implements BaseProvider {
  const _FakeProvider({
    required this.providerName,
    this.items = const <AnimeCard>[],
    this.error,
  });

  @override
  final String providerName;

  final List<AnimeCard> items;
  final Object? error;

  @override
  Future<AnimeSearchResult> search(String keyword) async {
    final thrown = error;
    if (thrown != null) {
      throw thrown;
    }
    return AnimeSearchResult(
      provider: providerName,
      keyword: keyword,
      total: items.length,
      items: items,
    );
  }

  @override
  Future<AnimeDetail> getDetail(String animeId) async =>
      AnimeDetail(provider: providerName, animeId: animeId, title: '测试详情');

  @override
  Future<AnimeChapterList> getChapters(String animeId) async =>
      AnimeChapterList(provider: providerName, animeId: animeId);

  @override
  Future<AnimeContent> getContent(String chapterId) async =>
      AnimeContent(provider: providerName, chapterId: chapterId);
}

AnimeCard _card(String provider, String id) => AnimeCard(
  provider: provider,
  animeId: id,
  title: '海贼王',
  detailUrl: 'https://example.com/$id',
);

void main() {
  test('默认注册表仅包含六个动漫源', () {
    final registry = ProviderRegistry();

    expect(registry.listProviderNames(), [
      'hmgdm',
      'yinhuadm',
      'qydm',
      'yhdmoe',
      'mxdm2',
      'xgcartoon',
    ]);
  });

  test('Provider 注册表保持顺序并支持逗号参数去重', () {
    final registry = ProviderRegistry(
      providers: const <String, BaseProvider>{
        'alpha': _FakeProvider(providerName: 'alpha'),
        'beta': _FakeProvider(providerName: 'beta'),
        'gamma': _FakeProvider(providerName: 'gamma'),
      },
    );

    expect(registry.resolveProviderNames(['gamma,beta', 'beta']), [
      'beta',
      'gamma',
    ]);
    expect(registry.listProviders().toJson(), {
      'total': 3,
      'providers': ['alpha', 'beta', 'gamma'],
    });
  });

  test('聚合搜索返回成功结果并记录部分失败', () async {
    final client = AniSearchClient(
      registry: ProviderRegistry(
        providers: <String, BaseProvider>{
          'alpha': _FakeProvider(
            providerName: 'alpha',
            items: [_card('alpha', 'a1')],
          ),
          'beta': const _FakeProvider(
            providerName: 'beta',
            error: ProviderRequestException('请求超时'),
          ),
        },
      ),
    );

    final result = await client.search(keyword: '  海贼王  ');

    expect(result.keyword, '海贼王');
    expect(result.requestedProviders, ['alpha', 'beta']);
    expect(result.succeededProviders, ['alpha']);
    expect(result.failedProviders.single.provider, 'beta');
    expect(result.failedProviders.single.message, '请求超时');
    expect(result.total, 1);
  });

  test('未知 Provider 会抛出明确异常', () {
    final client = AniSearchClient(
      registry: ProviderRegistry(
        providers: const <String, BaseProvider>{
          'alpha': _FakeProvider(providerName: 'alpha'),
        },
      ),
    );

    expect(
      () => client.search(keyword: '海贼王', providers: ['missing']),
      throwsA(isA<ProviderNotFoundException>()),
    );
  });

  test('模型 JSON 字段保持兼容后端命名', () {
    final card = _card('alpha', 'a1');

    expect(card.toJson(), containsPair('anime_id', 'a1'));
    expect(card.toJson(), containsPair('detail_url', 'https://example.com/a1'));
  });
}
