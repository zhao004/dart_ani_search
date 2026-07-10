import 'base_provider.dart';
import 'hmgdm_provider.dart';
import 'mxdm2_provider.dart';
import 'qydm_provider.dart';
import 'xgcartoon_provider.dart';
import 'yhdmoe_provider.dart';
import 'yinhuadm_provider.dart';

/// 创建默认 Provider 注册表。
Map<String, BaseProvider> buildDefaultProviders() {
  final providers = <BaseProvider>[
    HmgdmProvider(),
    YinHuaDmProvider(),
    QydmProvider(),
    YhdmoeProvider(),
    Mxdm2Provider(),
    XgCartoonProvider(),
  ];
  return <String, BaseProvider>{
    for (final provider in providers) provider.providerName: provider,
  };
}
