import 'package:dart_ani_search/dart_ani_search.dart';
import 'package:dart_ani_search/providers/search_policy.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProvider implements BaseProvider {
  const _FakeProvider({
    required this.providerName,
    this.items = const <AnimeCard>[],
    this.error,
    this.delay = Duration.zero,
  });

  @override
  final String providerName;

  final List<AnimeCard> items;
  final Object? error;
  final Duration delay;

  @override
  Future<AnimeSearchResult> search(String keyword) async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
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

  test('内置 Provider 搜索策略使用专属超时且禁用重试', () {
    for (final provider in const [
      'hmgdm',
      'yinhuadm',
      'qydm',
      'yhdmoe',
      'xgcartoon',
    ]) {
      final policy = providerSearchPolicyFor(provider);
      expect(policy.timeout, const Duration(seconds: 8));
      expect(policy.retryTimes, 0);
    }

    final slowPolicy = providerSearchPolicyFor('mxdm2');
    expect(slowPolicy.timeout, const Duration(seconds: 18));
    expect(slowPolicy.retryTimes, 0);

    final customPolicy = providerSearchPolicyFor('custom');
    expect(customPolicy.timeout, const Duration(seconds: 20));
    expect(customPolicy.retryTimes, 0);
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

  test('渐进聚合先返回快速来源并在最终快照保持注册顺序', () async {
    final client = AniSearchClient(
      registry: ProviderRegistry(
        providers: <String, BaseProvider>{
          'alpha': _FakeProvider(
            providerName: 'alpha',
            delay: const Duration(milliseconds: 80),
            items: [_card('alpha', 'a1')],
          ),
          'beta': _FakeProvider(
            providerName: 'beta',
            delay: const Duration(milliseconds: 10),
            items: [_card('beta', 'b1')],
          ),
        },
      ),
    );

    final updates = await client.searchProgress(keyword: '海贼王').toList();

    expect(updates, hasLength(2));
    expect(updates.first.completedProviders, ['beta']);
    expect(updates.first.pendingProviders, ['alpha']);
    expect(updates.first.isComplete, isFalse);
    expect(updates.first.result.items.map((item) => item.provider), ['beta']);

    final finalUpdate = updates.last;
    expect(finalUpdate.completedProviders, ['alpha', 'beta']);
    expect(finalUpdate.pendingProviders, isEmpty);
    expect(finalUpdate.isComplete, isTrue);
    expect(finalUpdate.result.items.map((item) => item.provider), [
      'alpha',
      'beta',
    ]);
  });

  test('渐进聚合记录超时来源且兼容 Future 搜索异常', () async {
    final client = AniSearchClient(
      providerTimeout: const Duration(milliseconds: 20),
      registry: ProviderRegistry(
        providers: const <String, BaseProvider>{
          'slow': _FakeProvider(
            providerName: 'slow',
            delay: Duration(milliseconds: 100),
          ),
        },
      ),
    );

    final updates = await client.searchProgress(keyword: '海贼王').toList();

    expect(updates, hasLength(1));
    expect(updates.single.isComplete, isTrue);
    expect(updates.single.result.succeededProviders, isEmpty);
    expect(updates.single.result.failedProviders.single.provider, 'slow');
    expect(updates.single.result.failedProviders.single.message, '搜索超时');

    await expectLater(
      client.search(keyword: '海贼王'),
      throwsA(isA<ProviderRequestException>()),
    );
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
