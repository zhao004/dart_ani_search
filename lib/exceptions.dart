/// 动漫搜索包的业务异常基类。
class AniSearchException implements Exception {
  /// 创建带业务码和中文提示的异常。
  const AniSearchException(this.message, {this.code = 500});

  /// 可展示给调用方的错误信息。
  final String message;

  /// 兼容原后端响应语义的业务码。
  final int code;

  @override
  String toString() => message;
}

/// 查询参数无效。
class InvalidQueryParameterException extends AniSearchException {
  /// 创建参数校验异常。
  const InvalidQueryParameterException(super.message) : super(code: 400);
}

/// 未找到请求的 Provider。
class ProviderNotFoundException extends AniSearchException {
  /// 创建 Provider 不存在异常。
  const ProviderNotFoundException(super.message) : super(code: 404);
}

/// 第三方站点请求失败。
class ProviderRequestException extends AniSearchException {
  /// 创建站点请求异常。
  const ProviderRequestException(super.message) : super(code: 500);
}

/// 第三方站点内容解析失败。
class ProviderParseException extends AniSearchException {
  /// 创建站点解析异常。
  const ProviderParseException(super.message) : super(code: 500);
}

/// Provider 尚未实现某项能力。
class ProviderCapabilityNotImplementedException extends AniSearchException {
  /// 创建能力未实现异常。
  const ProviderCapabilityNotImplementedException(super.message)
    : super(code: 501);
}
