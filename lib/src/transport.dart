/// ToggleAI SDK — HTTP Transport
///
/// Handles all communication with the ToggleAI API.
///
/// Features:
///   - Automatic Bearer auth header construction (clientId:secret)
///   - Request timeout support
///   - Rate limit header parsing
///   - Structured error mapping aligned with sdk_controller.ts
///
/// Auth format matches backend: sdk_controller.ts authenticateSDK()
///   -> Authorization: Bearer <clientId>:<secret>

library;

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'types.dart';

// ─────────────────────────────────────────────────────────────
// Transport Response
// ─────────────────────────────────────────────────────────────

class TransportResponse<T> {
  final T data;
  final int statusCode;
  final RateLimitInfo? rateLimit;

  const TransportResponse({
    required this.data,
    required this.statusCode,
    this.rateLimit,
  });
}

// ─────────────────────────────────────────────────────────────
// Transport
// ─────────────────────────────────────────────────────────────

class Transport {
  final String _baseUrl;
  final String _authHeader;
  final String _clientId;
  final String _secret;
  final Duration _timeout;
  final http.Client _client;

  Transport({
    required String baseUrl,
    required String clientId,
    required String secret,
    required Duration timeout,
    http.Client? client,
  })  : _baseUrl = baseUrl.replaceAll(RegExp(r'/$'), ''),
        _authHeader = 'Bearer $clientId:$secret',
        _clientId = clientId,
        _secret = secret,
        _timeout = timeout,
        _client = client ?? http.Client();

  /// Perform a GET request to the SDK API.
  Future<TransportResponse<T>> get<T>(
    String path,
    T Function(Map<String, dynamic>) fromJson,
  ) async {
    return _request('GET', path, fromJson, null);
  }

  /// Perform a POST request to the SDK API.
  Future<TransportResponse<T>> post<T>(
    String path,
    T Function(Map<String, dynamic>) fromJson, [
    Map<String, dynamic>? body,
  ]) async {
    return _request('POST', path, fromJson, body);
  }

  /// Core request method with timeout, auth, and structured error handling.
  Future<TransportResponse<T>> _request<T>(
    String method,
    String path,
    T Function(Map<String, dynamic>) fromJson,
    Map<String, dynamic>? body,
  ) async {
    final uri = Uri.parse('$_baseUrl$path');

    final headers = <String, String>{
      'Authorization': _authHeader,
      'X-Client-ID': _clientId,
      'X-Client-Secret': _secret,
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'X-SDK-Type': 'flutter',
    };

    try {
      late http.Response response;

      final request = http.Request(method, uri);
      request.headers.addAll(headers);

      if (body != null) {
        request.body = jsonEncode(body);
      }

      final streamedResponse = await _client
          .send(request)
          .timeout(_timeout, onTimeout: () {
        throw ToggleAIException(
          ToggleAIErrorCode.timeout,
          'Request to $path timed out after ${_timeout.inMilliseconds}ms',
        );
      });

      response = await http.Response.fromStream(streamedResponse);

      final rateLimit = _parseRateLimitHeaders(response.headers);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        Map<String, dynamic> errorBody = {};
        try {
          errorBody = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {}
        throw _mapHttpError(response.statusCode, errorBody);
      }

      final jsonBody = jsonDecode(response.body) as Map<String, dynamic>;
      final data = fromJson(jsonBody);

      return TransportResponse(
        data: data,
        statusCode: response.statusCode,
        rateLimit: rateLimit,
      );
    } on ToggleAIException {
      rethrow;
    } on TimeoutException {
      throw ToggleAIException(
        ToggleAIErrorCode.timeout,
        'Request to $path timed out after ${_timeout.inMilliseconds}ms',
      );
    } catch (e) {
      throw ToggleAIException(
        ToggleAIErrorCode.networkError,
        'Network error while calling $path: $e',
      );
    }
  }

  /// Parse rate limit info from response headers.
  /// Header names match backend: X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset
  RateLimitInfo? _parseRateLimitHeaders(Map<String, String> headers) {
    final limitStr = headers['x-ratelimit-limit'];
    if (limitStr == null) return null;

    return RateLimitInfo(
      limit: int.tryParse(limitStr) ?? 0,
      remaining: int.tryParse(headers['x-ratelimit-remaining'] ?? '') ?? 0,
      resetAt: int.tryParse(headers['x-ratelimit-reset'] ?? '') ?? 0,
      retryAfter: int.tryParse(headers['retry-after'] ?? ''),
    );
  }

  /// Map HTTP error responses to [ToggleAIException].
  /// Status codes match backend: sdk_controller.ts handleError()
  ToggleAIException _mapHttpError(int status, Map<String, dynamic> body) {
    final message = (body['error'] as String?) ?? 'HTTP $status';

    switch (status) {
      case 401:
        return ToggleAIException(ToggleAIErrorCode.invalidKey, message, statusCode: status);
      case 403:
        return ToggleAIException(ToggleAIErrorCode.forbidden, message, statusCode: status);
      case 410:
        return ToggleAIException(
          ToggleAIErrorCode.invalidKey,
          'API key revoked: $message',
          statusCode: status,
        );
      case 422:
        return ToggleAIException(ToggleAIErrorCode.evaluationError, message, statusCode: status);
      case 429:
        return ToggleAIException(ToggleAIErrorCode.rateLimited, message, statusCode: status);
      default:
        return ToggleAIException(ToggleAIErrorCode.serverError, message, statusCode: status);
    }
  }

  /// Close the underlying HTTP client and release resources.
  void close() {
    _client.close();
  }

  /// Raw POST — sends a pre-encoded JSON body and returns the response.
  /// Used by [ToggleAILogger] for batch log ingest where the response
  /// body does not need to be decoded.
  Future<http.Response> rawPost(Uri uri, String jsonBody) async {
    final request = http.Request('POST', uri);
    request.headers.addAll({
      'Authorization': _authHeader,
      'X-Client-ID': _clientId,
      'X-Client-Secret': _secret,
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'X-SDK-Type': 'flutter',
    });
    request.body = jsonBody;

    final streamedResponse = await _client
        .send(request)
        .timeout(_timeout, onTimeout: () {
      throw ToggleAIException(
        ToggleAIErrorCode.timeout,
        'Log ingest timed out after ${_timeout.inMilliseconds}ms',
      );
    });

    return http.Response.fromStream(streamedResponse);
  }
}

