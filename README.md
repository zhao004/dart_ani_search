# dart_ani_search

`dart_ani_search` 是一个 Flutter/Dart 本地动漫聚合搜索与解析包，用于从多个动漫站点获取搜索结果、作品详情、章节列表和播放内容。包内默认注册 6 个动漫源站，并提供统一模型与异常类型，方便上层应用按 Provider 单独查询或做聚合搜索。

> 注意：第三方站点页面结构和访问策略可能随时变化。本包会对请求失败、解析失败、参数错误做明确异常包装，但调用方仍应在产品侧提供降级、重试和错误提示。

## 功能特性

- 多源聚合搜索：默认并发搜索全部 Provider，并返回成功源站、失败源站和聚合结果。
- 单源精确查询：支持按 Provider 获取搜索、详情、章节列表和章节内容。
- 统一数据模型：`AnimeCard`、`AnimeDetail`、`AnimeChapterList`、`AnimeContent` 均可直接用于 UI 或缓存。
- 清晰异常语义：参数错误、源站不存在、请求失败、解析失败会映射为独立异常类型。
- 可扩展注册表：可通过 `ProviderRegistry` 注入自定义 Provider，用于测试或新增站点。
- 源站可用性探测：提供 `tool/check_providers.dart`，可验证默认源站搜索、详情和章节链路。

## 默认源站

当前默认注册表包含 6 个已通过真实链路探测的源站：

| Provider | 类型 | 地址 | 覆盖能力 |
| --- | --- | --- | --- |
| `hmgdm` | 动漫站 | <https://hmgdm.com> | 搜索、详情、章节、视频直链 |
| `yinhuadm` | 动漫站 | <https://www.yinhuadm.cc> | 搜索、详情、章节、视频或 iframe |
| `qydm` | 动漫站 | <https://www.qydm.cc> | 搜索、详情、章节、播放器 iframe |
| `yhdmoe` | 动漫站 | <https://yhdmoe.com> | 搜索、详情、章节、视频直链 |
| `mxdm2` | 动漫站 | <https://www.mxdm2.com> | 搜索、详情、章节、视频直链 |
| `xgcartoon` | 动漫站 | <https://cn.xgcartoon.com> | 搜索、详情、章节、播放器 iframe |

## 安装与环境

```yaml
dependencies:
  dart_ani_search:
    path: .
```

环境要求：

- Dart SDK：`^3.11.5`
- Flutter：`>=1.17.0`
- 网络环境需能访问目标第三方站点

## 使用示例

```dart
import 'package:dart_ani_search/dart_ani_search.dart';

Future<void> main() async {
  final client = AniSearchClient();

  final providers = await client.listProviders();
  print(providers.toJson());

  final searchResult = await client.search(keyword: '海贼王');
  print('成功源站: ${searchResult.succeededProviders}');
  print('失败源站: ${searchResult.failedProviders.map((item) => item.toJson())}');
  print('结果数量: ${searchResult.total}');

  final first = searchResult.items.first;
  final detail = await client.getDetail(
    provider: first.provider,
    animeId: first.animeId,
  );

  final chapters = await client.getChapters(
    provider: first.provider,
    animeId: first.animeId,
  );

  final firstChapter = chapters.groups.first.items.first;
  final content = await client.getContent(
    provider: first.provider,
    chapterId: firstChapter.chapterId,
  );

  print(detail.title);
  print(content.toJson());
}
```

## 自定义 Provider

```dart
final registry = ProviderRegistry(
  providers: <String, BaseProvider>{
    'custom': CustomProvider(),
  },
);

final client = AniSearchClient(registry: registry);
final result = await client.search(keyword: '海贼王', providers: ['custom']);
```

自定义 Provider 需要实现：

- `search(String keyword)`
- `getDetail(String animeId)`
- `getChapters(String animeId)`
- `getContent(String chapterId)`

实现时建议复用包内模型和异常类型，确保上层调用能获得一致的错误语义。

## 源站可用性验证

运行默认源站真实链路探测：

```bash
dart run tool/check_providers.dart
```

指定关键词：

```bash
dart run tool/check_providers.dart 海贼王
```

探测脚本会逐个 Provider 验证：

1. 搜索结果不为空
2. 第一条结果可打开详情
3. 详情标题可解析
4. 章节列表不为空
5. 至少一个代表章节可返回视频直链或播放器 iframe

任一默认源站失败时，脚本会以非零退出码结束，便于在 CI 或发布前检查源站状态。

## 开发验证

修改代码后至少运行：

```bash
dart analyze
flutter test
dart run tool/check_providers.dart
```

建议在提交前执行格式化：

```bash
dart format lib tool test
```

## 项目结构

```text
lib/
  ani_search_client.dart      # 对外客户端
  query_service.dart          # 聚合调度与输入校验
  exceptions.dart             # 业务异常
  models/                     # 统一模型
  providers/                  # Provider 注册表与站点实现
  utils/                      # HTTP 与 HTML 解析工具
tool/
  check_providers.dart        # 默认源站真实链路探测脚本
test/
  dart_ani_search_test.dart   # 注册表、聚合和模型测试
```

## 维护说明

- 第三方站点可能出现 403、跳转校验、结构改版或临时不可用。
- 新增源站前应先用真实关键词验证搜索、详情、章节和播放内容链路。
- 无法稳定访问、无法解析章节或无法返回播放内容的源站不应放入默认注册表。
- 涉及密钥、代理或私有服务时，请使用环境变量，不要硬编码到源码中。
