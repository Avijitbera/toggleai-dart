import 'constants.dart';

/// ToggleAI SDK — Type Definitions
///
/// All types match the backend SDK API response shapes exactly.
/// Aligned with: backend/src/service/sdk_config_service.ts

// ─────────────────────────────────────────────────────────────
// SDK Options
// ─────────────────────────────────────────────────────────────

/// Configuration options for [ToggleAIClient].
class ToggleAIOptions {
  /// Public client ID (e.g. "pk_live_xxx")
  final String clientId;

  /// Private secret (e.g. "sk_live_xxx")
  final String secret;

  /// Backend base URL. Defaults to the hosted ToggleAI API.
  final String baseUrl;

  /// Polling interval for background config refresh.
  /// Set to [Duration.zero] to disable polling.
  /// Default: 30 seconds.
  final Duration pollingInterval;

  /// Flag evaluation strategy:
  /// - [EvaluationMode.local]: fetch config payload, evaluate flags in-memory (fastest)
  /// - [EvaluationMode.server]: call POST /sdk/evaluate on every evaluation (real-time)
  final EvaluationMode evaluationMode;

  /// Disable local config caching. When true you MUST use the async methods
  /// that fetch directly from the server.
  final bool disableCache;

  /// Default user context merged with per-evaluation context.
  final EvaluationContext? defaultContext;

  /// Request timeout. Default: 10 seconds.
  final Duration timeout;

  /// Callback fired when the client is fully initialized.
  final void Function()? onReady;

  /// Callback fired when the config payload is refreshed.
  final void Function(ConfigPayload)? onConfigUpdate;

  /// Callback fired on error during fetch / polling.
  final void Function(ToggleAIException)? onError;

  const ToggleAIOptions({
    required this.clientId,
    required this.secret,
    this.baseUrl = API_BASE_URL,
    this.pollingInterval = const Duration(seconds: 30),
    this.evaluationMode = EvaluationMode.local,
    this.disableCache = false,
    this.defaultContext,
    this.timeout = const Duration(seconds: 10),
    this.onReady,
    this.onConfigUpdate,
    this.onError,
  });
}

/// Flag evaluation mode.
enum EvaluationMode {
  /// Evaluate flags locally from the cached payload (default, sub-ms latency).
  local,

  /// Evaluate flags via server-side POST /sdk/evaluate (real-time accuracy).
  server,
}

/// Registered SDK type sent to the server for analytics.
enum SdkType {
  js,
  react,
  node,
  python,
  go,
  ios,
  android,
  flutter;

  String get value => name;
}

// ─────────────────────────────────────────────────────────────
// Config Payload (from GET /sdk/config)
// Matches: SdkConfigPayload in sdk_config_service.ts
// ─────────────────────────────────────────────────────────────

/// The full config payload returned by GET /sdk/config.
class ConfigPayload {
  final String projectId;
  final String environmentId;
  final String environmentSlug;
  final Map<String, FlagDefinition> flags;
  final Map<String, ConfigDefinition> configs;

  /// Active experiments — SDK uses this to auto-track exposures.
  final List<ExperimentPayloadItem> experiments;

  /// Unix timestamp (seconds) when this payload was generated.
  final int generatedAt;

  const ConfigPayload({
    required this.projectId,
    required this.environmentId,
    required this.environmentSlug,
    required this.flags,
    required this.configs,
    required this.experiments,
    required this.generatedAt,
  });

  factory ConfigPayload.fromJson(Map<String, dynamic> json) {
    return ConfigPayload(
      projectId: json['projectId'] as String,
      environmentId: json['environmentId'] as String,
      environmentSlug: json['environmentSlug'] as String,
      generatedAt: (json['generatedAt'] as num).toInt(),
      flags: (json['flags'] as Map<String, dynamic>? ?? {}).map(
        (k, v) =>
            MapEntry(k, FlagDefinition.fromJson(v as Map<String, dynamic>)),
      ),
      configs: (json['configs'] as Map<String, dynamic>? ?? {}).map(
        (k, v) =>
            MapEntry(k, ConfigDefinition.fromJson(v as Map<String, dynamic>)),
      ),
      experiments: (json['experiments'] as List<dynamic>? ?? [])
          .map((e) => ExperimentPayloadItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// A single feature flag definition in the SDK payload.
/// Matches: SdkFlag in sdk_config_service.ts
class FlagDefinition {
  final String key;
  final String type;
  final bool enabled;

  /// JSON-decoded default value.
  final dynamic value;
  final int rolloutPercentage;
  final bool killSwitchEnabled;
  final List<FlagVariation> variations;
  final List<TargetingRule> targetingRules;

  /// Map of userIdentifier → override value.
  final Map<String, dynamic> userOverrides;

  const FlagDefinition({
    required this.key,
    required this.type,
    required this.enabled,
    required this.value,
    required this.rolloutPercentage,
    required this.killSwitchEnabled,
    required this.variations,
    required this.targetingRules,
    required this.userOverrides,
  });

  factory FlagDefinition.fromJson(Map<String, dynamic> json) {
    return FlagDefinition(
      key: json['key'] as String,
      type: json['type'] as String,
      enabled: json['enabled'] as bool,
      value: json['value'],
      rolloutPercentage: (json['rolloutPercentage'] as num).toInt(),
      killSwitchEnabled: json['killSwitchEnabled'] as bool? ?? false,
      variations: (json['variations'] as List<dynamic>? ?? [])
          .map((v) => FlagVariation.fromJson(v as Map<String, dynamic>))
          .toList(),
      targetingRules: (json['targetingRules'] as List<dynamic>? ?? [])
          .map((r) => TargetingRule.fromJson(r as Map<String, dynamic>))
          .toList(),
      userOverrides:
          Map<String, dynamic>.from(json['userOverrides'] as Map? ?? {}),
    );
  }
}

/// A single flag variation.
/// A single variation of a feature flag.
///
/// Matches the backend [FlagVariation] shape and the TypeScript SDK [FlagVariation] type.
/// The [id] field is the DB UUID required by [ToggleAIClient.trackConversion].
class FlagVariation {
  /// DB UUID — required for experiment conversion tracking.
  final String id;

  /// Variation key string (e.g. "variant_a", "control").
  final String key;

  /// The typed value of this variation.
  final dynamic value;

  /// Optional human-readable name.
  final String? name;

  /// Optional description.
  final String? description;

  /// Display order.
  final int sortOrder;

  const FlagVariation({
    required this.id,
    required this.key,
    required this.value,
    this.name,
    this.description,
    this.sortOrder = 0,
  });

  factory FlagVariation.fromJson(Map<String, dynamic> json) {
    return FlagVariation(
      id: json['id'] as String? ?? '',
      key: json['key'] as String,
      value: json['value'],
      name: json['name'] as String?,
      description: json['description'] as String?,
      sortOrder: json['sortOrder'] as int? ?? 0,
    );
  }
}

/// A targeting rule for a feature flag.
class TargetingRule {
  final String id;
  final String? name;
  final int priority;
  final String? segmentId;
  final List<TargetingCondition>? conditions;
  final String? variationKey;
  final int rolloutPercentage;
  final bool enabled;

  const TargetingRule({
    required this.id,
    this.name,
    required this.priority,
    this.segmentId,
    this.conditions,
    this.variationKey,
    required this.rolloutPercentage,
    required this.enabled,
  });

  factory TargetingRule.fromJson(Map<String, dynamic> json) {
    final rawConditions = json['conditions'];
    List<TargetingCondition>? conditions;
    if (rawConditions is List && rawConditions.isNotEmpty) {
      conditions = rawConditions
          .map((c) => TargetingCondition.fromJson(c as Map<String, dynamic>))
          .toList();
    }

    return TargetingRule(
      id: json['id'] as String,
      name: json['name'] as String?,
      priority: (json['priority'] as num).toInt(),
      segmentId: json['segmentId'] as String?,
      conditions: conditions,
      variationKey: json['variationKey'] as String?,
      rolloutPercentage: (json['rolloutPercentage'] as num).toInt(),
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}

/// A single targeting condition.
class TargetingCondition {
  final String attribute;
  final String op;
  final dynamic value;
  final List<dynamic>? values;

  const TargetingCondition({
    required this.attribute,
    required this.op,
    this.value,
    this.values,
  });

  factory TargetingCondition.fromJson(Map<String, dynamic> json) {
    return TargetingCondition(
      attribute: json['attribute'] as String,
      op: json['op'] as String,
      value: json['value'],
      values: json['values'] as List<dynamic>?,
    );
  }
}

/// A single remote config value.
/// Matches: SdkConfig in sdk_config_service.ts
class ConfigDefinition {
  final String key;
  final String type;
  final dynamic value;

  const ConfigDefinition(
      {required this.key, required this.type, required this.value});

  factory ConfigDefinition.fromJson(Map<String, dynamic> json) {
    return ConfigDefinition(
      key: json['key'] as String,
      type: json['type'] as String,
      value: json['value'],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Evaluation
// Matches: EvaluationContext & FlagEvaluationResult in sdk_config_service.ts
// ─────────────────────────────────────────────────────────────

/// Context sent to the evaluator for targeting and rollout.
class EvaluationContext {
  /// Unique user identifier for consistent rollout bucketing.
  final String? userId;

  /// User attributes for targeting rule evaluation.
  final Map<String, dynamic>? attributes;

  const EvaluationContext({this.userId, this.attributes});

  Map<String, dynamic> toJson() => {
        if (userId != null) 'userId': userId,
        if (attributes != null) 'attributes': attributes,
      };

  EvaluationContext merge(EvaluationContext? other) {
    if (other == null) return this;
    return EvaluationContext(
      userId: other.userId ?? userId,
      attributes: {...?attributes, ...?other.attributes},
    );
  }
}

/// Result of evaluating a single flag.
class FlagEvaluationResult {
  final String key;
  final bool enabled;
  final dynamic value;
  final String? variationKey;
  final EvaluationReason reason;

  const FlagEvaluationResult({
    required this.key,
    required this.enabled,
    required this.value,
    required this.variationKey,
    required this.reason,
  });

  factory FlagEvaluationResult.fromJson(Map<String, dynamic> json) {
    return FlagEvaluationResult(
      key: json['key'] as String,
      enabled: json['enabled'] as bool,
      value: json['value'],
      variationKey: json['variationKey'] as String?,
      reason:
          EvaluationReason.fromString(json['reason'] as String? ?? 'DEFAULT'),
    );
  }
}

/// Evaluation reason — matches backend FlagEvaluationResult.reason.
enum EvaluationReason {
  /// Flag is disabled.
  off,

  /// Kill switch is enabled.
  killed,

  /// User has a specific override.
  override,

  /// A targeting rule matched.
  targetingMatch,

  /// Rollout bucketing applied (user outside rollout).
  rollout,

  /// Default value served (flag enabled, no targeting match).
  defaultValue,

  /// Flag key was not found in the payload.
  flagNotFound,

  /// Client-side error (closed / uninitialized state).
  error;

  static EvaluationReason fromString(String value) {
    switch (value) {
      case 'OFF':
        return EvaluationReason.off;
      case 'KILLED':
        return EvaluationReason.killed;
      case 'OVERRIDE':
        return EvaluationReason.override;
      case 'TARGETING_MATCH':
        return EvaluationReason.targetingMatch;
      case 'ROLLOUT':
        return EvaluationReason.rollout;
      case 'DEFAULT':
        return EvaluationReason.defaultValue;
      case 'FLAG_NOT_FOUND':
        return EvaluationReason.flagNotFound;
      default:
        return EvaluationReason.error;
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Client State
// ─────────────────────────────────────────────────────────────

/// Lifecycle state of the [ToggleAIClient].
enum ClientState {
  /// Created but not yet initialized.
  idle,

  /// Fetching initial config payload.
  initializing,

  /// Config loaded — evaluations are available.
  ready,

  /// Failed to initialize.
  error,

  /// Client has been closed and cannot be reused.
  closed,
}

// ─────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────

/// Exception thrown by the ToggleAI SDK.
class ToggleAIException implements Exception {
  final ToggleAIErrorCode code;
  final String message;
  final int? statusCode;

  const ToggleAIException(this.code, this.message, {this.statusCode});

  @override
  String toString() => 'ToggleAIException(${code.name}): $message';
}

/// Error codes for [ToggleAIException].
enum ToggleAIErrorCode {
  notInitialized,
  invalidKey,
  networkError,
  timeout,
  rateLimited,
  forbidden,
  serverError,
  evaluationError,
  closed,
}

// ─────────────────────────────────────────────────────────────
// Rate Limit
// ─────────────────────────────────────────────────────────────

/// Rate limit info parsed from response headers.
class RateLimitInfo {
  final int limit;
  final int remaining;
  final int resetAt;
  final int? retryAfter;

  const RateLimitInfo({
    required this.limit,
    required this.remaining,
    required this.resetAt,
    this.retryAfter,
  });
}

// ─────────────────────────────────────────────────────────────
// Experiment Conversion Tracking
// Matches: POST /sdk/experiments/:experimentId/track
// ─────────────────────────────────────────────────────────────

/// Options for tracking a conversion event in an A/B experiment.
///
/// The backend endpoint is:
///   POST /sdk/experiments/:experimentId/track
///
/// The API key (clientId + secret) automatically scopes the request
/// to the correct org/project — no need to pass them explicitly.
///
/// **Note:** [variationId] is the DB UUID, NOT the `variationKey` string.
/// Use [ToggleAIClient.resolveVariationId] to convert the variationKey
/// returned by [ToggleAIClient.getEvaluation] into the correct UUID.
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
class TrackConversionOptions {
  /// Experiment ID.
  final String experimentId;

  /// The DB UUID of the variation assigned to this user.
  /// Resolve via [ToggleAIClient.resolveVariationId].
  final String variationId;

  /// The metric key to increment (e.g. 'conversion_rate', 'revenue_per_user').
  /// Must match the experiment's primaryMetric or secondaryMetrics.
  final String metricKey;

  /// Optional numeric value for the metric (e.g. revenue amount). Defaults to 1.
  final double? value;

  /// Optional user identifier for deduplication.
  final String? userId;

  const TrackConversionOptions({
    required this.experimentId,
    required this.variationId,
    required this.metricKey,
    this.value,
    this.userId,
  });

  Map<String, dynamic> toJson() => {
        'variationId': variationId,
        'metricKey': metricKey,
        if (value != null) 'value': value,
        if (userId != null) 'userIdentifier': userId,
      };
}

/// Result returned by the conversion tracking endpoint.
class TrackConversionResult {
  final bool ok;
  final String message;
  final bool flushed;

  const TrackConversionResult({
    required this.ok,
    required this.message,
    required this.flushed,
  });

  factory TrackConversionResult.fromJson(Map<String, dynamic> json) =>
      TrackConversionResult(
        ok: json['ok'] as bool? ?? true,
        message: json['message'] as String? ?? '',
        flushed: json['flushed'] as bool? ?? false,
      );
}

// ─────────────────────────────────────────────────────────────
// Auto-Experiment Types
// Matches: POST /sdk/track and POST /sdk/expose in auto_experiment_controller.ts
// ─────────────────────────────────────────────────────────────

/// An active experiment attached to a flag, included in the config payload.
/// The SDK uses this to determine when to auto-track exposures.
class ExperimentPayloadItem {
  final String experimentId;
  final String flagKey;
  final String status;
  final String? primaryMetric;
  final List<ExperimentMetric> secondaryMetrics;
  final List<ExperimentVariation> variations;

  const ExperimentPayloadItem({
    required this.experimentId,
    required this.flagKey,
    required this.status,
    this.primaryMetric,
    required this.secondaryMetrics,
    required this.variations,
  });

  factory ExperimentPayloadItem.fromJson(Map<String, dynamic> json) {
    return ExperimentPayloadItem(
      experimentId: json['experimentId'] as String,
      flagKey: json['flagKey'] as String,
      status: json['status'] as String,
      primaryMetric: json['primaryMetric'] as String?,
      secondaryMetrics: (json['secondaryMetrics'] as List<dynamic>? ?? [])
          .map((m) => ExperimentMetric.fromJson(m as Map<String, dynamic>))
          .toList(),
      variations: (json['variations'] as List<dynamic>? ?? [])
          .map((v) => ExperimentVariation.fromJson(v as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// A metric tracked by an experiment.
class ExperimentMetric {
  final String key;
  final String name;
  final String type;

  const ExperimentMetric({
    required this.key,
    required this.name,
    required this.type,
  });

  factory ExperimentMetric.fromJson(Map<String, dynamic> json) {
    return ExperimentMetric(
      key: json['key'] as String,
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? 'conversion',
    );
  }
}

/// A variation in an experiment with its traffic weight.
class ExperimentVariation {
  final String id;
  final String key;
  final double weight;

  const ExperimentVariation({
    required this.id,
    required this.key,
    required this.weight,
  });

  factory ExperimentVariation.fromJson(Map<String, dynamic> json) {
    return ExperimentVariation(
      id: json['id'] as String,
      key: json['key'] as String? ?? '',
      weight: (json['weight'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Options for tracking a generic event (auto-attributed to running experiments).
///
/// The backend endpoint is:
///   POST /sdk/track
///
/// Example:
/// ```dart
/// await client.track(TrackEventOptions(
///   metricKey: 'purchase_completed',
///   userIdentifier: 'user_42',
///   value: 29.99,
/// ));
/// ```
class TrackEventOptions {
  /// Metric key to track (e.g. 'purchase_completed', 'signup').
  final String metricKey;

  /// Unique user identifier for attribution.
  final String userIdentifier;

  /// Optional numeric value (e.g. revenue). Defaults to 1 on the server.
  final double? value;

  const TrackEventOptions({
    required this.metricKey,
    required this.userIdentifier,
    this.value,
  });

  Map<String, dynamic> toJson() => {
        'metricKey': metricKey,
        'userIdentifier': userIdentifier,
        if (value != null) 'value': value,
      };
}

/// Attribution info for a tracked event matched to an experiment.
class TrackEventAttribution {
  final String experimentId;
  final String experimentName;
  final String variationId;
  final String metricKey;

  const TrackEventAttribution({
    required this.experimentId,
    required this.experimentName,
    required this.variationId,
    required this.metricKey,
  });

  factory TrackEventAttribution.fromJson(Map<String, dynamic> json) {
    return TrackEventAttribution(
      experimentId: json['experimentId'] as String,
      experimentName: json['experimentName'] as String? ?? '',
      variationId: json['variationId'] as String,
      metricKey: json['metricKey'] as String,
    );
  }
}

/// Result returned by the event tracking endpoint.
class TrackEventResult {
  final bool ok;
  final int processed;
  final int attributed;

  const TrackEventResult({
    required this.ok,
    required this.processed,
    required this.attributed,
  });

  factory TrackEventResult.fromJson(Map<String, dynamic> json) {
    return TrackEventResult(
      ok: json['ok'] as bool? ?? true,
      processed: (json['processed'] as num?)?.toInt() ?? 0,
      attributed: (json['attributed'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Options for recording a user exposure to an experiment variation.
///
/// The backend endpoint is:
///   POST /sdk/expose
///
/// Example:
/// ```dart
/// await client.recordExposure(ExposureOptions(
///   experimentId: 'exp_xxx',
///   variationId: 'var_xxx',
///   userIdentifier: 'user_42',
/// ));
/// ```
class ExposureOptions {
  /// Experiment ID.
  final String experimentId;

  /// Variation ID (DB UUID) the user was exposed to.
  final String variationId;

  /// Unique user identifier.
  final String userIdentifier;

  const ExposureOptions({
    required this.experimentId,
    required this.variationId,
    required this.userIdentifier,
  });

  Map<String, dynamic> toJson() => {
        'experimentId': experimentId,
        'variationId': variationId,
        'userIdentifier': userIdentifier,
      };
}

/// Result returned by the exposure recording endpoint.
class ExposureResult {
  final bool ok;
  final int processed;
  final int newExposures;

  const ExposureResult({
    required this.ok,
    required this.processed,
    required this.newExposures,
  });

  factory ExposureResult.fromJson(Map<String, dynamic> json) {
    return ExposureResult(
      ok: json['ok'] as bool? ?? true,
      processed: (json['processed'] as num?)?.toInt() ?? 0,
      newExposures: (json['newExposures'] as num?)?.toInt() ?? 0,
    );
  }
}
