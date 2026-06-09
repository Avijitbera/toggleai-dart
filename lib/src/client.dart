/// ToggleAI SDK — Main Client
///
/// The primary entry point for the ToggleAI SDK.
///
/// Features:
///   - Local flag evaluation (no network per eval — sub-ms latency)
///   - Server-side evaluation mode (POST /sdk/evaluate for real-time accuracy)
///   - Background polling for config updates (configurable interval)
///   - Type-safe getters for flags and configs
///   - Event callbacks (onReady, onConfigUpdate, onError)
///   - Graceful lifecycle management (init → ready → close)
///
/// Backend endpoints used:
///   GET  /sdk/config              — Fetch full config payload
///   POST /sdk/evaluate            — Server-side evaluate all flags
///   POST /sdk/evaluate/:flagKey   — Server-side evaluate single flag
///   POST /sdk/connect             — Register SDK connection
///
/// Example:
/// ```dart
/// final client = ToggleAIClient(
///   options: ToggleAIOptions(
///     clientId: 'pk_live_xxx',
///     secret: 'sk_live_xxx',
///   ),
/// );
///
/// await client.init();
///
/// if (client.getFlag('dark-mode', userId: 'user_42')) {
///   enableDarkMode();
/// }
///
/// final timeout = client.getConfig<int>('api_timeout_ms', defaultValue: 5000);
/// ```

library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'evaluator.dart' as evaluator;
import 'logger.dart';
import 'transport.dart';
import 'types.dart';

// ─────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────

const String _sdkVersion = '0.1.0';

// ─────────────────────────────────────────────────────────────
// Client
// ─────────────────────────────────────────────────────────────

class ToggleAIClient with WidgetsBindingObserver {
  final ToggleAIOptions _options;
  late final Transport _transport;

  ConfigPayload? _payload;
  ClientState _state = ClientState.idle;
  Timer? _pollTimer;
  Completer<void>? _initCompleter;
  ToggleAIException? _lastError;
  ToggleAILogger? _logger;

  /// Dedup set: tracks 'experimentId:userIdentifier' combos already exposed this session.
  final Set<String> _pendingExposures = {};

  /// Map flagKey → ExperimentPayloadItem for fast lookup during evaluation.
  final Map<String, ExperimentPayloadItem> _experimentMap = {};

  /// Metrics queue: Map flagKey → _MetricEntry
  final Map<String, _MetricEntry> _metricsQueue = {};
  Timer? _metricsTimer;

  ToggleAIClient({
    required ToggleAIOptions options,
    http.Client? httpClient,
  }) : _options = options {
    assert(options.clientId.isNotEmpty, 'ToggleAIClient: clientId is required');
    assert(options.secret.isNotEmpty, 'ToggleAIClient: secret is required');

    _transport = Transport(
      baseUrl: options.baseUrl,
      clientId: options.clientId,
      secret: options.secret,
      timeout: options.timeout,
      client: httpClient,
    );
  }

  // ─── Lifecycle ──────────────────────────────────────────────

  /// Initialize the client: fetch the config payload and start polling.
  /// Safe to call multiple times — subsequent calls await the same future.
  ///
  /// Fetches GET /sdk/config and caches the payload locally.
  /// If polling is enabled, starts background refresh automatically.
  Future<void> init() async {
    if (_state == ClientState.ready) return;
    if (_state == ClientState.closed) {
      throw const ToggleAIException(
        ToggleAIErrorCode.closed,
        'Client has been closed. Create a new instance.',
      );
    }
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    final completer = Completer<void>();
    _initCompleter = completer;

    _doInit().then((_) {
      if (!completer.isCompleted) completer.complete();
    }).catchError((Object error, StackTrace stack) {
      if (!completer.isCompleted) completer.completeError(error, stack);
    });

    return completer.future;
  }

  Future<void> _doInit() async {
    _state = ClientState.initializing;

    try {
      if (!_options.disableCache) {
        await _fetchConfig();
      }

      _state = ClientState.ready;
      _options.onReady?.call();

      // Register App Lifecycle observer
      WidgetsBinding.instance.addObserver(this);

      // Start polling if enabled
      if (!_options.disableCache && _options.pollingInterval != Duration.zero) {
        _startPolling();
      }

      // Register SDK connection — fire-and-forget
      unawaited(_registerConnection().catchError((_) {}));
    } on ToggleAIException catch (e) {
      _state = ClientState.error;
      _lastError = e;
      _options.onError?.call(e);
      rethrow;
    } catch (e) {
      _state = ClientState.error;
      final err = ToggleAIException(ToggleAIErrorCode.networkError, e.toString());
      _lastError = err;
      _options.onError?.call(err);
      rethrow;
    }
  }

  /// Shut down the client: stop polling and release resources.
  /// Also closes the attached logger if one was created.
  /// After calling [close], the client cannot be reused. Create a new instance.
  void close() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    _stopMetricsTimer();
    // Flush pending metrics (fire-and-forget)
    unawaited(_flushMetrics().catchError((_) {}));
    _transport.close();
    _state = ClientState.closed;
    _payload = null;
    _initCompleter = null;
    // Close logger (fire-and-forget flush)
    _logger?.close().catchError((_) {});
    _logger = null;
  }

  /// Manually refresh the config payload outside the poll cycle.
  /// Calls GET /sdk/config and updates the local cache.
  Future<void> refresh() async {
    _ensureNotClosed();
    await _fetchConfig();
  }

  /// Get the current client state.
  ClientState get state => _state;

  /// Returns true when the client is fully initialized (config loaded).
  bool get isReady => _state == ClientState.ready;

  /// Wait until the client reaches [ClientState.ready].
  Future<void> waitForReady() async {
    if (_state == ClientState.ready) return;
    if (_initCompleter != null) return _initCompleter!.future;
    throw const ToggleAIException(
      ToggleAIErrorCode.notInitialized,
      'Call client.init() first.',
    );
  }

  // ─── Feature Flags (Local Evaluation) ───────────────────────

  /// Get a boolean flag value using local in-memory evaluation.
  ///
  /// No network call required — uses the cached config payload.
  /// For real-time server-side evaluation, use [evaluateFlagRemote].
  ///
  /// ```dart
  /// if (client.getFlag('dark-mode', userId: 'user_42')) {
  ///   enableDarkMode();
  /// }
  /// ```
  bool getFlag(
    String key, {
    String? userId,
    Map<String, dynamic>? attributes,
    bool defaultValue = false,
  }) {
    final res = getEvaluation(
      key,
      context: EvaluationContext(userId: userId, attributes: attributes),
    );
    if (res.reason == EvaluationReason.flagNotFound ||
        res.reason == EvaluationReason.error) {
      return defaultValue;
    }
    final v = res.value;
    return v == true || v == 1 || v == 'true';
  }

  /// Get a boolean flag value, fetching from server if cache is disabled or
  /// evaluation mode is [EvaluationMode.server].
  Future<bool> getFlagAsync(
    String key, {
    String? userId,
    Map<String, dynamic>? attributes,
    bool defaultValue = false,
  }) async {
    final ctx = EvaluationContext(userId: userId, attributes: attributes);

    if (_shouldUsServer) {
      final res = await evaluateFlagRemote(key, context: ctx);
      if (res.reason == EvaluationReason.flagNotFound ||
          res.reason == EvaluationReason.error) {
        return defaultValue;
      }
      final v = res.value;
      return v == true || v == 1 || v == 'true';
    }

    return getFlag(key, userId: userId, attributes: attributes, defaultValue: defaultValue);
  }

  /// Get a typed flag value (for string/number/JSON flags) using local evaluation.
  ///
  /// ```dart
  /// final theme = client.getFlagValue<String>('theme', userId: 'user_42', defaultValue: 'light');
  /// ```
  T? getFlagValue<T>(
    String key, {
    String? userId,
    Map<String, dynamic>? attributes,
    T? defaultValue,
  }) {
    final res = getEvaluation(
      key,
      context: EvaluationContext(userId: userId, attributes: attributes),
    );
    if (res.reason == EvaluationReason.flagNotFound ||
        res.reason == EvaluationReason.error) {
      return defaultValue;
    }
    if (res.value is T) return res.value as T;
    return defaultValue;
  }

  /// Get a typed flag value async.
  Future<T?> getFlagValueAsync<T>(
    String key, {
    String? userId,
    Map<String, dynamic>? attributes,
    T? defaultValue,
  }) async {
    final ctx = EvaluationContext(userId: userId, attributes: attributes);

    if (_shouldUsServer) {
      final res = await evaluateFlagRemote(key, context: ctx);
      if (res.reason == EvaluationReason.flagNotFound ||
          res.reason == EvaluationReason.error) {
        return defaultValue;
      }
      if (res.value is T) return res.value as T;
      return defaultValue;
    }

    return getFlagValue<T>(key, userId: userId, attributes: attributes, defaultValue: defaultValue);
  }

  /// Get the full evaluation result for a flag (includes reason, variationKey, etc.).
  /// Uses local in-memory evaluation from the cached config payload.
  FlagEvaluationResult getEvaluation(
    String key, {
    EvaluationContext? context,
  }) {
    if (_payload == null) {
      return FlagEvaluationResult(
        key: key,
        enabled: false,
        value: null,
        variationKey: null,
        reason: _state == ClientState.closed
            ? EvaluationReason.error
            : EvaluationReason.flagNotFound,
      );
    }

    final flag = _payload!.flags[key];
    if (flag == null) {
      return FlagEvaluationResult(
        key: key,
        enabled: false,
        value: null,
        variationKey: null,
        reason: EvaluationReason.flagNotFound,
      );
    }

    final mergedContext = _mergeContext(context);
    final result = evaluator.evaluateFlag(flag, mergedContext);

    // Queue metric for local evaluation
    _queueMetric(key, result.enabled);

    // Auto-exposure: if this flag has a running experiment, record exposure
    _maybeAutoExpose(key, result, mergedContext);

    return result;
  }

  /// Evaluate a single flag locally from the cached config payload.
  /// Identical to [getEvaluation] (added to align with TS SDK naming).
  FlagEvaluationResult evaluateFlag(
    String key, {
    EvaluationContext? context,
  }) => getEvaluation(key, context: context);

  /// Evaluate all flags at once for the given context. Uses local evaluation.
  Map<String, FlagEvaluationResult> evaluateAllFlags({EvaluationContext? context}) {
    if (_payload == null) return {};
    final mergedContext = _mergeContext(context);
    return evaluator.evaluateAllFlags(_payload!.flags, mergedContext);
  }

  // ─── Feature Flags (Server-Side Evaluation) ─────────────────

  /// Server-side evaluation of a single flag.
  /// Calls POST /sdk/evaluate/:flagKey on the backend.
  Future<FlagEvaluationResult> evaluateFlagRemote(
    String key, {
    EvaluationContext? context,
  }) async {
    _ensureNotClosed();
    final mergedContext = _mergeContext(context);
    final body = mergedContext.toJson();

    final response = await _transport.post<FlagEvaluationResult>(
      '/sdk/evaluate/${Uri.encodeComponent(key)}',
      FlagEvaluationResult.fromJson,
      body.isEmpty ? null : body,
    );

    return response.data;
  }

  /// Server-side evaluation for all flags at once.
  /// Calls POST /sdk/evaluate on the backend.
  Future<Map<String, FlagEvaluationResult>> evaluateAllFlagsRemote({
    EvaluationContext? context,
  }) async {
    _ensureNotClosed();
    final mergedContext = _mergeContext(context);
    final body = mergedContext.toJson();

    final response = await _transport.post<Map<String, FlagEvaluationResult>>(
      '/sdk/evaluate',
      (json) {
        final evaluations = json['evaluations'] as Map<String, dynamic>? ?? {};
        return evaluations.map(
          (k, v) => MapEntry(k, FlagEvaluationResult.fromJson(v as Map<String, dynamic>)),
        );
      },
      body.isEmpty ? null : body,
    );

    return response.data;
  }

  // ─── Experiment Conversion Tracking ─────────────────────────

  /// Track a conversion event for an A/B experiment.
  ///
  /// Call this after a user performs the action being measured
  /// (e.g. purchase, sign-up, button click). The backend atomically
  /// increments Redis counters and periodically flushes them to the DB.
  ///
  /// The API key automatically scopes the request to the correct
  /// org/project — you only need experimentId.
  ///
  /// **Note:** Use [resolveVariationId] to convert the `variationKey`
  /// returned by [getEvaluation] into the DB UUID required here.
  ///
  /// Example:
  /// ```dart
  /// final result = client.getEvaluation('checkout-flow',
  ///   context: EvaluationContext(userId: 'user_42'));
  ///
  /// final variationId = client.resolveVariationId(
  ///   'checkout-flow', result.variationKey);
  ///
  /// if (variationId != null) {
  ///   await client.trackConversion(TrackConversionOptions(
  ///     experimentId: 'exp_xxx',
  ///     variationId: variationId,
  ///     metricKey: 'conversion_rate',
  ///     userId: 'user_42',
  ///   ));
  /// }
  /// ```
  Future<TrackConversionResult> trackConversion(
    TrackConversionOptions opts,
  ) async {
    _ensureNotClosed();

    final path =
        '/sdk/experiments/${Uri.encodeComponent(opts.experimentId)}/track';

    final response = await _transport.post<TrackConversionResult>(
      path,
      TrackConversionResult.fromJson,
      opts.toJson(),
    );

    return response.data;
  }

  /// Resolve a `variationKey` string (from [getEvaluation]) to the DB UUID
  /// (`variationId`) required by [trackConversion].
  ///
  /// Returns `null` if the flag or variation key is not found in the
  /// cached config payload.
  ///
  /// Example:
  /// ```dart
  /// final result = client.getEvaluation('checkout-flow',
  ///   context: EvaluationContext(userId: 'user_42'));
  ///
  /// final variationId = client.resolveVariationId(
  ///   'checkout-flow', result.variationKey);
  /// ```
  String? resolveVariationId(String flagKey, String? variationKey) {
    if (variationKey == null) return null;
    final flag = _payload?.flags[flagKey];
    if (flag == null) return null;
    try {
      return flag.variations
          .firstWhere((v) => v.key == variationKey)
          .id;
    } catch (_) {
      return null;
    }
  }

  // ─── Auto-Experiment: Event Tracking ───────────────────────

  /// Track a generic event. The backend auto-attributes it to any
  /// running experiments whose primary/secondary metrics match the
  /// metricKey.
  ///
  /// This is the "zero-code" experiment tracking path — you don't
  /// need to know which experiment is running, just fire meaningful
  /// business events and the backend handles attribution.
  ///
  /// Calls POST /sdk/track
  ///
  /// Example:
  /// ```dart
  /// await client.track(TrackEventOptions(
  ///   metricKey: 'purchase_completed',
  ///   userIdentifier: 'user_42',
  ///   value: 29.99,
  /// ));
  /// ```
  Future<TrackEventResult> track(TrackEventOptions event) async {
    _ensureNotClosed();

    final response = await _transport.post<TrackEventResult>(
      '/sdk/track',
      TrackEventResult.fromJson,
      event.toJson(),
    );
    return response.data;
  }

  /// Track multiple events in a single request (up to 100).
  /// The backend auto-attributes each to matching running experiments.
  ///
  /// Calls POST /sdk/track
  ///
  /// Example:
  /// ```dart
  /// await client.trackBatch([
  ///   TrackEventOptions(metricKey: 'page_view', userIdentifier: 'user_42'),
  ///   TrackEventOptions(metricKey: 'add_to_cart', userIdentifier: 'user_42', value: 2),
  /// ]);
  /// ```
  Future<TrackEventResult> trackBatch(List<TrackEventOptions> events) async {
    _ensureNotClosed();

    final response = await _transport.post<TrackEventResult>(
      '/sdk/track',
      TrackEventResult.fromJson,
      {'events': events.map((e) => e.toJson()).toList()},
    );
    return response.data;
  }

  // ─── Auto-Experiment: Exposure Recording ────────────────────

  /// Manually record that a user was exposed to a specific experiment variation.
  ///
  /// In most cases you don't need this — the SDK auto-records exposures when
  /// evaluating flags with active experiments (see [getEvaluation]). Use this
  /// only for advanced use cases where you need explicit control.
  ///
  /// Calls POST /sdk/expose
  ///
  /// Example:
  /// ```dart
  /// await client.recordExposure(ExposureOptions(
  ///   experimentId: 'exp_xxx',
  ///   variationId: 'var_xxx',
  ///   userIdentifier: 'user_42',
  /// ));
  /// ```
  Future<ExposureResult> recordExposure(ExposureOptions exposure) async {
    _ensureNotClosed();

    final response = await _transport.post<ExposureResult>(
      '/sdk/expose',
      ExposureResult.fromJson,
      {'exposures': [exposure.toJson()]},
    );
    return response.data;
  }

  /// Record multiple exposures in a single request (up to 50).
  ///
  /// Example:
  /// ```dart
  /// await client.recordExposures([
  ///   ExposureOptions(experimentId: 'exp_1', variationId: 'var_a', userIdentifier: 'user_42'),
  ///   ExposureOptions(experimentId: 'exp_2', variationId: 'var_b', userIdentifier: 'user_42'),
  /// ]);
  /// ```
  Future<ExposureResult> recordExposures(List<ExposureOptions> exposures) async {
    _ensureNotClosed();

    final response = await _transport.post<ExposureResult>(
      '/sdk/expose',
      ExposureResult.fromJson,
      {'exposures': exposures.map((e) => e.toJson()).toList()},
    );
    return response.data;
  }

  /// Get the list of active experiments from the cached config payload.
  /// Returns an empty list if no experiments are running.
  List<ExperimentPayloadItem> get activeExperiments =>
      _payload?.experiments ?? [];

  /// Get the experiment linked to a specific flag key, if any.
  /// Returns null if no running experiment is attached to this flag.
  ExperimentPayloadItem? getExperimentForFlag(String flagKey) =>
      _experimentMap[flagKey];

  // ─── Remote Config ───────────────────────────────────────────

  /// Get a typed config value from the cached payload.
  ///
  /// ```dart
  /// final timeout = client.getConfig<int>('api_timeout_ms', defaultValue: 5000);
  /// ```
  T? getConfig<T>(String key, {T? defaultValue}) {
    if (_payload == null) return defaultValue;
    final config = _payload!.configs[key];
    if (config == null) return defaultValue;
    if (config.value is T) return config.value as T;
    return defaultValue;
  }

  /// Get a typed config value async. Fetches from server if cache is disabled.
  Future<T?> getConfigAsync<T>(String key, {T? defaultValue}) async {
    if (_shouldUsServer) {
      final response = await _transport.get<ConfigPayload>(
        '/sdk/config',
        ConfigPayload.fromJson,
      );
      final config = response.data.configs[key];
      if (config == null) return defaultValue;
      if (config.value is T) return config.value as T;
      return defaultValue;
    }
    return getConfig<T>(key, defaultValue: defaultValue);
  }

  /// Get all config values as a flat map.
  Map<String, dynamic> getAllConfigs() {
    if (_payload == null) return {};
    return _payload!.configs.map((key, config) => MapEntry(key, config.value));
  }

  /// Check if a config key exists in the cached payload.
  bool hasConfig(String key) => _payload?.configs.containsKey(key) ?? false;

  // ─── Raw Payload Access ──────────────────────────────────────

  /// Get the raw config payload (for advanced use cases / debugging).
  ConfigPayload? get rawPayload => _payload;

  /// Get the raw flag definition (for inspection/debugging).
  FlagDefinition? getFlagDefinition(String key) => _payload?.flags[key];

  /// Get all available flag keys.
  List<String> get flagKeys => _payload?.flags.keys.toList() ?? [];

  /// Get all available config keys.
  List<String> get configKeys => _payload?.configs.keys.toList() ?? [];

  /// Get environment metadata from the cached payload.
  ({String id, String slug})? get environment {
    if (_payload == null) return null;
    return (id: _payload!.environmentId, slug: _payload!.environmentSlug);
  }

  /// Returns the last error that occurred, if any.
  ToggleAIException? get lastError => _lastError;

  // ─── Logger ──────────────────────────────────────────────────

  /// Get (or lazily create) the logger attached to this client.
  ///
  /// The logger shares the same API key credentials and sends events
  /// to the same ToggleAI project.
  ///
  /// ```dart
  /// final logger = client.getLogger();
  /// logger.info('User signed in', context: {'userId': 'u_42'});
  ///
  /// try {
  ///   await riskyOperation();
  /// } catch (e, stack) {
  ///   logger.captureError(e, stackTrace: stack, context: {'userId': 'u_42'});
  /// }
  ///
  /// // Attach to Flutter error handler:
  /// FlutterError.onError = logger.captureFlutterError;
  /// ```
  ToggleAILogger getLogger({LoggerOptions? overrides}) {
    _logger ??= ToggleAILogger(
      options: overrides ??
          LoggerOptions(
            clientId: _options.clientId,
            secret: _options.secret,
            baseUrl: _options.baseUrl,
            timeout: _options.timeout,
          ),
    );
    return _logger!;
  }

  // ─── Internals ───────────────────────────────────────────────

  bool get _shouldUsServer =>
      _options.disableCache ||
      _options.pollingInterval == Duration.zero ||
      _options.evaluationMode == EvaluationMode.server;

  Future<void> _fetchConfig() async {
    final response = await _transport.get<ConfigPayload>(
      '/sdk/config',
      ConfigPayload.fromJson,
    );
    _payload = response.data;
    _rebuildExperimentMap();
    _options.onConfigUpdate?.call(_payload!);
  }

  /// Rebuild the flagKey → experiment lookup map from the config payload.
  /// Called after every config fetch/poll.
  void _rebuildExperimentMap() {
    _experimentMap.clear();
    if (_payload?.experiments == null) return;
    for (final exp in _payload!.experiments) {
      _experimentMap[exp.flagKey] = exp;
    }
  }

  /// Auto-exposure: fire-and-forget POST /sdk/expose when a flag evaluation
  /// resolves to a variation that is part of an active experiment.
  ///
  /// Deduplicates by experimentId+userIdentifier within the session to avoid
  /// spamming the backend on repeated evaluations.
  void _maybeAutoExpose(
    String flagKey,
    FlagEvaluationResult result,
    EvaluationContext context,
  ) {
    if (!result.enabled || result.variationKey == null || context.userId == null) return;

    final experiment = _experimentMap[flagKey];
    if (experiment == null) return;

    // Resolve the variation ID from the flag's variation list
    final variationId = resolveVariationId(flagKey, result.variationKey);
    if (variationId == null) return;

    // Dedup within session
    final dedupKey = '${experiment.experimentId}:${context.userId}';
    if (_pendingExposures.contains(dedupKey)) return;
    _pendingExposures.add(dedupKey);

    // Fire-and-forget — don't block the evaluation
    unawaited(
      _transport.post<Map<String, dynamic>>(
        '/sdk/expose',
        (json) => json,
        {
          'exposures': [
            {
              'experimentId': experiment.experimentId,
              'variationId': variationId,
              'userIdentifier': context.userId,
            },
          ],
        },
      ).then((_) {
        // Exposure recorded successfully
      }).catchError((_) {
        // Remove from dedup on failure so it can be retried
        _pendingExposures.remove(dedupKey);
      }),
    );
  }

  EvaluationContext _mergeContext(EvaluationContext? context) {
    final base = _options.defaultContext ?? const EvaluationContext();
    return base.merge(context);
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(_options.pollingInterval, (_) async {
      try {
        await _fetchConfig();
      } on ToggleAIException catch (e) {
        _options.onError?.call(e);
      } catch (e) {
        _options.onError?.call(
          ToggleAIException(ToggleAIErrorCode.networkError, e.toString()),
        );
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _registerConnection() async {
    String? hostname;
    try {
      if (kIsWeb) {
        hostname = Uri.base.host;
      } else {
        final packageInfo = await PackageInfo.fromPlatform();
        hostname = packageInfo.packageName;
      }
    } catch (_) {
      // Fallback if platform APIs fail
    }

    await _transport.post<Map<String, dynamic>>(
      '/sdk/connect',
      (json) => json,
      {
        'sdkType': SdkType.flutter.value,
        'sdkVersion': _sdkVersion,
        if (hostname != null && hostname.isNotEmpty) 'hostname': hostname,
      },
    );
  }

  void _ensureNotClosed() {
    if (_state == ClientState.closed) {
      throw const ToggleAIException(
        ToggleAIErrorCode.closed,
        'Client has been closed. Create a new instance.',
      );
    }
  }

  // ─── Metrics Ingest ──────────────────────────────────────────

  void _queueMetric(String flagKey, bool enabled) {
    final entry = _metricsQueue.putIfAbsent(flagKey, () => _MetricEntry());
    entry.totalEvaluations++;
    if (enabled) {
      entry.trueCount++;
    } else {
      entry.falseCount++;
    }
    entry.cacheHits++; // evaluated locally
    _ensureMetricsFlushTimer();
  }

  void _ensureMetricsFlushTimer() {
    if (_metricsTimer != null) return;

    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) {
      return;
    }

    _metricsTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      try {
        await _flushMetrics();
      } catch (_) {}
    });
  }

  void _stopMetricsTimer() {
    _metricsTimer?.cancel();
    _metricsTimer = null;
  }

  Future<void> _flushMetrics() async {
    if (_metricsQueue.isEmpty) return;

    final evaluations = <Map<String, dynamic>>[];
    final tempQueue = Map<String, _MetricEntry>.from(_metricsQueue);
    _metricsQueue.clear();

    tempQueue.forEach((flagKey, m) {
      evaluations.add({
        'flagKey': flagKey,
        'totalEvaluations': m.totalEvaluations,
        'trueCount': m.trueCount,
        'falseCount': m.falseCount,
        'cacheHits': m.cacheHits,
      });
    });

    try {
      await _transport.post<Map<String, dynamic>>(
        '/sdk/metrics',
        (json) => json,
        {'evaluations': evaluations},
      );
    } catch (e) {
      // Restore metrics queue on error
      for (final item in evaluations) {
        final flagKey = item['flagKey'] as String;
        final entry = _metricsQueue.putIfAbsent(flagKey, () => _MetricEntry());
        entry.totalEvaluations += item['totalEvaluations'] as int;
        entry.trueCount += item['trueCount'] as int;
        entry.falseCount += item['falseCount'] as int;
        entry.cacheHits += item['cacheHits'] as int;
      }
      rethrow;
    }
  }

  // ─── Lifecycle Observer ──────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_metricsQueue.isNotEmpty) {
        _ensureMetricsFlushTimer();
      }
    } else if (state == AppLifecycleState.paused ||
               state == AppLifecycleState.inactive ||
               state == AppLifecycleState.detached) {
      _stopMetricsTimer();
      unawaited(_flushMetrics().catchError((_) {}));
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Metrics Queue Helpers
// ─────────────────────────────────────────────────────────────

class _MetricEntry {
  int totalEvaluations = 0;
  int trueCount = 0;
  int falseCount = 0;
  int cacheHits = 0;
}
