/// ToggleAI SDK — Logger
///
/// Edge-native logging and error monitoring for Flutter and Dart apps.
///
/// Features:
///   - Structured log ingestion (debug → fatal levels)
///   - Automatic error class + stack trace extraction
///   - In-memory queue with configurable batch flush (interval + size)
///   - Flutter-native error capture (FlutterError.onError)
///   - Isolate-safe: no shared state beyond the singleton instance
///
/// Backend endpoints:
///   POST /sdk/logs/ingest        — single event
///   POST /sdk/logs/ingest/batch  — up to 500 events
///
/// Example:
/// ```dart
/// final logger = ToggleAILogger(
///   options: LoggerOptions(
///     clientId: 'pk_live_xxx',
///     secret:   'sk_live_xxx',
///   ),
/// );
///
/// logger.info('Server started', context: {'port': 3000});
/// logger.error('Payment failed', error: PaymentException('Declined'));
///
/// await logger.flush(); // call before app shutdown
/// ```

library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'transport.dart';
import 'types.dart';

// ─────────────────────────────────────────────────────────────
// Log Levels
// ─────────────────────────────────────────────────────────────

/// Log severity levels — matches the backend LogLevel enum exactly.
enum LogLevel {
  debug,
  info,
  warn,
  error,
  fatal;

  String get value {
    switch (this) {
      case LogLevel.debug:
        return 'debug';
      case LogLevel.info:
        return 'info';
      case LogLevel.warn:
        return 'warn';
      case LogLevel.error:
        return 'error';
      case LogLevel.fatal:
        return 'fatal';
    }
  }

  int get rank {
    switch (this) {
      case LogLevel.debug:
        return 0;
      case LogLevel.info:
        return 1;
      case LogLevel.warn:
        return 2;
      case LogLevel.error:
        return 3;
      case LogLevel.fatal:
        return 4;
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Logger Options
// ─────────────────────────────────────────────────────────────

class LoggerOptions {
  /// Public client ID (e.g. 'pk_live_xxx')
  final String clientId;

  /// Private secret (e.g. 'sk_live_xxx')
  final String secret;

  /// ToggleAI API base URL.
  /// Default: 'https://api.toggleai.app'
  final String baseUrl;

  /// Default context merged into every log event.
  /// Useful for app version, device info, environment, etc.
  final Map<String, dynamic> defaultContext;

  /// Minimum level to send to the backend.
  /// Events below this level are silently dropped.
  /// Default: [LogLevel.debug]
  final LogLevel minLevel;

  /// Maximum events to buffer before auto-flushing.
  /// Default: 50
  final int batchSize;

  /// Auto-flush interval.
  /// Set to [Duration.zero] to disable automatic flushing.
  /// Default: 5 seconds
  final Duration flushInterval;

  /// Tags to attach to every event (e.g. ['production', 'v2.3.1']).
  final List<String> tags;

  /// Request timeout.
  /// Default: 10 seconds
  final Duration timeout;

  /// Called when a flush fails.
  /// Default: prints to stderr.
  final void Function(Object error)? onFlushError;

  /// Optional HTTP client (for testing / custom config).
  final http.Client? httpClient;

  const LoggerOptions({
    required this.clientId,
    required this.secret,
    this.baseUrl = 'https://api.toggleai.app',
    this.defaultContext = const {},
    this.minLevel = LogLevel.debug,
    this.batchSize = 50,
    this.flushInterval = const Duration(seconds: 5),
    this.tags = const [],
    this.timeout = const Duration(seconds: 10),
    this.onFlushError,
    this.httpClient,
  });
}

// ─────────────────────────────────────────────────────────────
// Log Event (wire format)
// ─────────────────────────────────────────────────────────────

class LogEvent {
  final LogLevel level;
  final String message;
  final String? stackTrace;
  final Map<String, dynamic>? context;
  final String? userId;
  final String? userEmail;
  final List<String>? tags;
  final String? traceId;
  final String? spanId;
  final String? requestId;
  final double? durationMs;
  final DateTime? timestamp;

  const LogEvent({
    required this.level,
    required this.message,
    this.stackTrace,
    this.context,
    this.userId,
    this.userEmail,
    this.tags,
    this.traceId,
    this.spanId,
    this.requestId,
    this.durationMs,
    this.timestamp,
  });

  Map<String, dynamic> toJson() {
    return {
      'level': level.value,
      'message': message,
      if (stackTrace != null) 'stackTrace': stackTrace,
      if (context != null && context!.isNotEmpty) 'context': context,
      if (userId != null) 'userId': userId,
      if (userEmail != null) 'userEmail': userEmail,
      if (tags != null && tags!.isNotEmpty) 'tags': tags,
      if (traceId != null) 'traceId': traceId,
      if (spanId != null) 'spanId': spanId,
      if (requestId != null) 'requestId': requestId,
      if (durationMs != null) 'durationMs': durationMs,
      if (timestamp != null) 'timestamp': timestamp!.toUtc().toIso8601String(),
    };
  }
}

// ─────────────────────────────────────────────────────────────
// Logger
// ─────────────────────────────────────────────────────────────

class ToggleAILogger {
  final LoggerOptions _options;
  final Transport _transport;

  final List<LogEvent> _queue = [];
  Timer? _flushTimer;
  bool _flushing = false;
  bool _closed = false;

  /// Default context — mutable via [setContext].
  final Map<String, dynamic> _defaultContext;

  String? _appVersion;
  String? _appBuildNumber;
  String? _deviceModel;
  String? _deviceBrand;
  String? _deviceOsVersion;
  String? _devicePlatform;

  ToggleAILogger({
    required LoggerOptions options,
  })  : _options = options,
        _defaultContext = Map<String, dynamic>.from(options.defaultContext),
        _transport = Transport(
          baseUrl: options.baseUrl,
          clientId: options.clientId,
          secret: options.secret,
          timeout: options.timeout,
          client: options.httpClient,
        ) {
    _loadDetails();
    if (options.flushInterval != Duration.zero) {
      _startFlushTimer();
    }
  }

  // ─── Public logging methods ────────────────────────────────

  /// Log a debug message.
  void debug(String message, {Map<String, dynamic>? context}) {
    _enqueue(LogLevel.debug, message, context: context);
  }

  /// Log an info message.
  void info(String message, {Map<String, dynamic>? context}) {
    _enqueue(LogLevel.info, message, context: context);
  }

  /// Log a warning.
  void warn(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) {
    _enqueueError(LogLevel.warn, message, error, stackTrace, context);
  }

  /// Log an error.
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) {
    _enqueueError(LogLevel.error, message, error, stackTrace, context);
  }

  /// Log a fatal error (highest severity).
  void fatal(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) {
    _enqueueError(LogLevel.fatal, message, error, stackTrace, context);
  }

  /// Log at a dynamic level.
  void log(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) {
    _enqueueError(level, message, error, stackTrace, context);
  }

  /// Capture a caught exception with full context.
  ///
  /// Automatically extracts error class name from the exception type.
  ///
  /// ```dart
  /// try {
  ///   await riskyOperation();
  /// } catch (e, stack) {
  ///   logger.captureError(e, stackTrace: stack, context: {'userId': 'u_42'});
  /// }
  /// ```
  void captureError(
    Object error, {
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
    LogLevel level = LogLevel.error,
  }) {
    final enriched = <String, dynamic>{
      'errorClass': error.runtimeType.toString(),
      ...?context,
    };
    final message = error is Exception
        ? error.toString().replaceFirst('Exception: ', '')
        : error.toString();
    _enqueueError(level, message, error, stackTrace, enriched);
  }

  /// Capture Flutter framework errors.
  ///
  /// Attach to [FlutterError.onError] to automatically capture widget errors:
  /// ```dart
  /// FlutterError.onError = (details) {
  ///   logger.captureFlutterError(details);
  /// };
  /// ```
  void captureFlutterError(dynamic details) {
    // details is FlutterErrorDetails but we avoid the flutter import
    // to keep this file usable in pure Dart packages.
    try {
      final message = details.exceptionAsString?.call() ?? details.toString();
      final stack = details.stack?.toString();
      _enqueue(
        LogLevel.fatal,
        message,
        stackTrace: stack,
        context: {
          'errorClass': 'FlutterError',
          'source': 'FlutterError.onError',
          'library': details.library ?? 'unknown',
        },
      );
    } catch (_) {
      _enqueue(LogLevel.fatal, 'Uncaught Flutter error (details not parseable)');
    }
  }

  /// Set a default context value for all subsequent events.
  ///
  /// ```dart
  /// logger.setContext({'userId': 'u_42', 'plan': 'pro'});
  /// ```
  void setContext(Map<String, dynamic> context) {
    _defaultContext.addAll(context);
  }

  /// Remove a key from the default context.
  void clearContext(String key) {
    _defaultContext.remove(key);
  }

  /// Clear all default context values.
  void resetContext() {
    _defaultContext.clear();
  }

  // ─── Flush ────────────────────────────────────────────────

  /// Flush all queued events to the backend.
  ///
  /// Always call this before shutting down:
  /// ```dart
  /// await logger.flush();
  /// ```
  Future<void> flush() async {
    if (_flushing || _queue.isEmpty) return;

    _flushing = true;
    final batch = _queue.take(_options.batchSize).toList();
    _queue.removeRange(0, batch.length);

    try {
      await _sendBatch(batch);
    } catch (e) {
      // Re-queue failed batch so events aren't lost
      _queue.insertAll(0, batch);
      final onError = _options.onFlushError ?? _defaultFlushErrorHandler;
      onError(e);
    } finally {
      _flushing = false;
    }

    // If there are more events pending, flush again
    if (_queue.length >= _options.batchSize) {
      await flush();
    }
  }

  /// Flush and stop the logger.
  /// After [close], do not use this logger instance again.
  Future<void> close() async {
    _stopFlushTimer();
    await flush();
    _transport.close();
    _closed = true;
  }

  /// Number of events waiting in the buffer.
  int get queueSize => _queue.length;

  // ─── Internals ─────────────────────────────────────────────

  void _enqueue(
    LogLevel level,
    String message, {
    String? stackTrace,
    Map<String, dynamic>? context,
  }) {
    if (_closed) return;
    if (level.rank < _options.minLevel.rank) return;

    final merged = {..._defaultContext, ...?context};

    // Enrich with device and app details for warning/error/fatal logs
    if (level == LogLevel.warn || level == LogLevel.error || level == LogLevel.fatal) {
      if (_appVersion != null) merged['appVersion'] = _appVersion;
      if (_appBuildNumber != null) merged['appBuildNumber'] = _appBuildNumber;
      if (_deviceModel != null) merged['deviceModel'] = _deviceModel;
      if (_deviceBrand != null) merged['deviceBrand'] = _deviceBrand;
      if (_deviceOsVersion != null) merged['deviceOsVersion'] = _deviceOsVersion;
      if (_devicePlatform != null) merged['devicePlatform'] = _devicePlatform;
    }

    final userId = merged.remove('userId') as String?;
    final userEmail = merged.remove('userEmail') as String?;

    final event = LogEvent(
      level: level,
      message: message.length > 4000 ? message.substring(0, 4000) : message,
      stackTrace: stackTrace,
      context: merged.isNotEmpty ? merged : null,
      userId: userId,
      userEmail: userEmail,
      tags: _options.tags.isNotEmpty ? _options.tags : null,
      timestamp: DateTime.now().toUtc(),
    );

    _queue.add(event);

    // Auto-flush when batch size reached
    if (_queue.length >= _options.batchSize) {
      flush().catchError((e) {
        final onError = _options.onFlushError ?? _defaultFlushErrorHandler;
        onError(e);
      });
    }
  }

  void _enqueueError(
    LogLevel level,
    String message,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  ) {
    final stackStr = stackTrace?.toString() ?? StackTrace.current.toString();
    _enqueue(level, message, stackTrace: stackStr, context: context);
  }

  Future<void> _sendBatch(List<LogEvent> events) async {
    final body = {'events': events.map((e) => e.toJson()).toList()};
    final encoded = jsonEncode(body);

    final uri = Uri.parse('${_options.baseUrl}/sdk/logs/ingest/batch');
    final response = await _transport.rawPost(uri, encoded);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ToggleAIException(
        ToggleAIErrorCode.serverError,
        'Log ingest failed: HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
  }

  void _startFlushTimer() {
    _flushTimer = Timer.periodic(_options.flushInterval, (_) {
      flush().catchError((e) {
        final onError = _options.onFlushError ?? _defaultFlushErrorHandler;
        onError(e);
      });
    });
  }

  void _stopFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  static void _defaultFlushErrorHandler(Object error) {
    // ignore: avoid_print
    print('[ToggleAI] Log flush error: $error');
  }

  void _loadDetails() {
    try {
      if (kIsWeb) {
        _devicePlatform = 'web';
        _deviceModel = 'Browser';
        _deviceBrand = 'Web';
        _deviceOsVersion = 'Unknown';
      } else {
        if (defaultTargetPlatform == TargetPlatform.android) {
          _devicePlatform = 'android';
        } else if (defaultTargetPlatform == TargetPlatform.iOS) {
          _devicePlatform = 'ios';
        } else if (defaultTargetPlatform == TargetPlatform.macOS) {
          _devicePlatform = 'macos';
        } else if (defaultTargetPlatform == TargetPlatform.windows) {
          _devicePlatform = 'windows';
        } else if (defaultTargetPlatform == TargetPlatform.linux) {
          _devicePlatform = 'linux';
        } else {
          _devicePlatform = 'unknown';
        }
      }

      PackageInfo.fromPlatform().then((info) {
        _appVersion = info.version;
        _appBuildNumber = info.buildNumber;
      }).catchError((_) {});

      if (!kIsWeb) {
        final deviceInfo = DeviceInfoPlugin();
        if (defaultTargetPlatform == TargetPlatform.android) {
          deviceInfo.androidInfo.then((info) {
            _deviceModel = info.model;
            _deviceBrand = info.brand;
            _deviceOsVersion = 'Android ${info.version.release}';
          }).catchError((_) {});
        } else if (defaultTargetPlatform == TargetPlatform.iOS) {
          deviceInfo.iosInfo.then((info) {
            _deviceModel = info.utsname.machine;
            _deviceBrand = 'Apple';
            _deviceOsVersion = 'iOS ${info.systemVersion}';
          }).catchError((_) {});
        } else if (defaultTargetPlatform == TargetPlatform.macOS) {
          deviceInfo.macOsInfo.then((info) {
            _deviceModel = info.model;
            _deviceBrand = 'Apple';
            _deviceOsVersion = info.osRelease;
          }).catchError((_) {});
        }
      }
    } catch (_) {
      // Graceful fallback
    }
  }
}
