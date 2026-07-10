import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../exceptions.dart';

/// 轻量 HTTP 客户端，统一封装请求头、超时、重试与错误映射。
class AniHttpClient {
  /// 创建 HTTP 客户端，可注入测试客户端避免真实网络请求。
  AniHttpClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.retryTimes = 2,
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// 默认超时时间。
  final Duration timeout;

  /// 默认重试次数。
  final int retryTimes;

  /// 默认浏览器请求头，减少第三方站点拒绝普通客户端的概率。
  static const Map<String, String> defaultHeaders = <String, String>{
    HttpHeaders.userAgentHeader:
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36',
    HttpHeaders.acceptHeader:
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    HttpHeaders.acceptLanguageHeader: 'zh-CN,zh;q=0.9',
  };

  /// 发起 GET 请求并返回 UTF-8 文本。
  Future<String> getText(
    String url, {
    Map<String, String>? headers,
    String? referer,
    Duration? timeout,
    int? retryTimes,
  }) => _requestText(
    method: 'GET',
    url: url,
    headers: headers,
    referer: referer,
    timeout: timeout,
    retryTimes: retryTimes,
  );

  /// 发起 POST 请求并返回 UTF-8 文本。
  Future<String> postText(
    String url, {
    Map<String, String>? data,
    Object? rawBody,
    Map<String, String>? headers,
    String? referer,
    Duration? timeout,
    int? retryTimes,
  }) {
    if (data != null && rawBody != null) {
      throw ArgumentError('data 与 rawBody 不能同时传入');
    }
    Object? body = rawBody;
    final mergedHeaders = <String, String>{...?headers};
    if (data != null) {
      body = data.entries
          .map(
            (entry) =>
                '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
          )
          .join('&');
      mergedHeaders[HttpHeaders.contentTypeHeader] =
          'application/x-www-form-urlencoded; charset=UTF-8';
    }
    return _requestText(
      method: 'POST',
      url: url,
      headers: mergedHeaders,
      referer: referer,
      timeout: timeout,
      retryTimes: retryTimes,
      body: body,
    );
  }

  Future<String> _requestText({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? referer,
    Duration? timeout,
    int? retryTimes,
    Object? body,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw ProviderRequestException('请求地址无效: $url');
    }

    final mergedHeaders = <String, String>{...defaultHeaders, ...?headers};
    if (referer != null && referer.trim().isNotEmpty) {
      mergedHeaders[HttpHeaders.refererHeader] = referer.trim();
    }

    final attempts = (retryTimes ?? this.retryTimes) + 1;
    Object? lastError;
    for (var index = 0; index < attempts; index += 1) {
      try {
        final requestTimeout = timeout ?? this.timeout;
        final response = method == 'POST'
            ? await _client
                  .post(uri, headers: mergedHeaders, body: body)
                  .timeout(requestTimeout)
            : await _client
                  .get(uri, headers: mergedHeaders)
                  .timeout(requestTimeout);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw ProviderRequestException(
            '站点请求失败，HTTP 状态码: ${response.statusCode}',
          );
        }
        return utf8.decode(response.bodyBytes, allowMalformed: true);
      } on TimeoutException catch (error) {
        lastError = error;
      } on SocketException catch (error) {
        lastError = error;
      } on http.ClientException catch (error) {
        lastError = error;
      } on ProviderRequestException {
        rethrow;
      }
    }

    throw ProviderRequestException('站点请求失败: $lastError');
  }
}
