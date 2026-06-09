/// ToggleAI SDK — Local Flag Evaluator
///
/// Evaluates flags entirely in-memory from the cached config payload.
/// Zero network calls per evaluation — sub-millisecond latency.
///
/// Evaluation order (matches backend sdk_config_service.ts exactly):
///   1. Flag disabled → OFF
///   2. Kill switch enabled → KILLED
///   3. User override exists → OVERRIDE
///   4. Targeting rules (by priority) → TARGETING_MATCH
///   5. Rollout percentage check → ROLLOUT (outside) or DEFAULT (inside)
///   6. Default → DEFAULT

import 'types.dart';

// ─────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────

/// Evaluate a single flag for the given user context.
FlagEvaluationResult evaluateFlag(
  FlagDefinition flag,
  EvaluationContext context,
) {
  // 1. Flag disabled
  if (!flag.enabled) {
    return _result(flag.key, false, flag.value, null, EvaluationReason.off);
  }

  // 2. Kill switch
  if (flag.killSwitchEnabled) {
    return _result(flag.key, false, flag.value, null, EvaluationReason.killed);
  }

  // 3. User override
  final userId = context.userId;
  if (userId != null && flag.userOverrides.containsKey(userId)) {
    return _result(
      flag.key,
      true,
      flag.userOverrides[userId],
      null,
      EvaluationReason.override,
    );
  }

  // 4. Targeting rules (evaluated in ascending priority order)
  for (final rule in flag.targetingRules) {
    if (!rule.enabled) continue;

    final matches = _evaluateConditions(rule.conditions, context);
    if (!matches) continue;

    // Check rule-level rollout
    if (rule.rolloutPercentage < 100 && userId != null) {
      final bucket = hashBucket(userId, '${flag.key}${rule.id}');
      if (bucket >= rule.rolloutPercentage) continue;
    }

    // Resolve variation value
    dynamic value = flag.value;
    String? variationKey;

    if (rule.variationKey != null) {
      final variation = flag.variations
          .cast<FlagVariation?>()
          .firstWhere(
            (v) => v?.key == rule.variationKey,
            orElse: () => null,
          );
      if (variation != null) {
        value = variation.value;
        variationKey = rule.variationKey;
      }
    }

    return _result(
      flag.key,
      true,
      value,
      variationKey,
      EvaluationReason.targetingMatch,
    );
  }

  // 5. Rollout percentage
  if (flag.rolloutPercentage < 100) {
    if (userId == null) {
      // No user ID → can't do consistent rollout → serve default
      return _result(flag.key, true, flag.value, null, EvaluationReason.defaultValue);
    }

    final bucket = hashBucket(userId, flag.key);
    if (bucket >= flag.rolloutPercentage) {
      // Outside rollout → flag is "off" for this user
      return _result(flag.key, false, flag.value, null, EvaluationReason.rollout);
    }
  }

  // 6. Default — flag is enabled, serve default value
  return _result(flag.key, true, flag.value, null, EvaluationReason.defaultValue);
}

/// Evaluate all flags for the given user context.
Map<String, FlagEvaluationResult> evaluateAllFlags(
  Map<String, FlagDefinition> flags,
  EvaluationContext context,
) {
  return flags.map((key, flag) => MapEntry(key, evaluateFlag(flag, context)));
}

// ─────────────────────────────────────────────────────────────
// Condition Evaluation
// Matches: sdk_config_service.ts evaluateCondition() exactly
// ─────────────────────────────────────────────────────────────

/// Evaluate all conditions in a rule (AND logic).
/// Null/empty conditions = always match.
bool _evaluateConditions(
  List<TargetingCondition>? conditions,
  EvaluationContext context,
) {
  if (conditions == null || conditions.isEmpty) return true;
  return conditions.every((c) => _evaluateCondition(c, context));
}

/// Evaluate a single targeting condition against the user context.
bool _evaluateCondition(TargetingCondition condition, EvaluationContext context) {
  final attrValue = context.attributes?[condition.attribute];
  final op = condition.op;
  final value = condition.value;
  final values = condition.values;

  switch (op) {
    case 'eq':
      return attrValue == value;
    case 'neq':
      return attrValue != value;
    case 'gt':
      return attrValue is num && value is num && attrValue > value;
    case 'gte':
      return attrValue is num && value is num && attrValue >= value;
    case 'lt':
      return attrValue is num && value is num && attrValue < value;
    case 'lte':
      return attrValue is num && value is num && attrValue <= value;
    case 'in':
      return values != null &&
          values.any((v) => v.toString() == attrValue?.toString());
    case 'not_in':
      return values != null &&
          !values.any((v) => v.toString() == attrValue?.toString());
    case 'contains':
      return attrValue is String && value is String && attrValue.contains(value);
    case 'not_contains':
      return attrValue is String && value is String && !attrValue.contains(value);
    case 'starts_with':
      return attrValue is String && value is String && attrValue.startsWith(value);
    case 'ends_with':
      return attrValue is String && value is String && attrValue.endsWith(value);
    case 'exists':
      return attrValue != null;
    case 'not_exists':
      return attrValue == null;
    case 'regex':
      try {
        return attrValue is String &&
            value is String &&
            RegExp(value).hasMatch(attrValue);
      } catch (_) {
        return false;
      }
    default:
      return false;
  }
}

// ─────────────────────────────────────────────────────────────
// Hash-Based Bucketing
// Matches: sdk_config_service.ts hashBucket() exactly (djb2)
// ─────────────────────────────────────────────────────────────

/// Deterministic hash bucketing for consistent rollouts.
/// Same userId + seed always produces the same bucket (0–99).
///
/// Uses the djb2 hash algorithm — must match the backend exactly.
int hashBucket(String userId, String seed) {
  final str = '$userId:$seed';
  var hash = 5381;

  for (final codeUnit in str.codeUnits) {
    hash = (((hash << 5) + hash) + codeUnit) & 0xFFFFFFFF;
    // Convert to 32-bit signed integer (mirrors JS `hash & hash`)
    if (hash >= 0x80000000) {
      hash -= 0x100000000;
    }
  }

  return hash.abs() % 100;
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

FlagEvaluationResult _result(
  String key,
  bool enabled,
  dynamic value,
  String? variationKey,
  EvaluationReason reason,
) {
  return FlagEvaluationResult(
    key: key,
    enabled: enabled,
    value: value,
    variationKey: variationKey,
    reason: reason,
  );
}
