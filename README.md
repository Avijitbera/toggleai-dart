# ToggleAI Flutter/Dart SDK

The official Dart and Flutter SDK for [ToggleAI](https://toggle-ai-seven.vercel.app) — feature flags, remote config, logging, and A/B testing.

## 🔗 Quick Links

- 🌐 [Official Website](https://toggle-ai-seven.vercel.app)
- 📚 [Documentation Portal](https://toggleai-docs.vercel.app)

## Features

- ⚡ **Sub-millisecond local evaluation** — flags evaluated in-memory, zero network round trips
- 🔄 **Background polling** — automatic config refresh every 30 seconds (configurable)
- 🎯 **Targeting rules** — 14 condition operators (eq, in, regex, contains, starts_with, etc.)
- 🎰 **Consistent rollouts** — djb2 hash bucketing matches the backend exactly
- 🛡️ **Kill switch** — instantly disable any flag across all users
- 👤 **User overrides** — pin specific users to specific values
- 🧩 **Flutter widgets** — `ToggleAIProvider`, `FlagBuilder`, `ConfigBuilder`, `ToggleAIMixin`
- 🔌 **Server-side evaluation** — fall back to POST /sdk/evaluate for real-time accuracy
- 📊 **Remote Config** — typed access to JSON, string, number, and boolean configs
- 🐞 **Structured Logging** — built-in batched, buffered logging
- 🚨 **Error Monitoring** — native Flutter error capture (`FlutterError.onError`)

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  toggleai: 0.1.2
```

## Quick Start

```dart
import 'package:toggleai/dart_sdk.dart';

// 1. Create the client
final client = ToggleAIClient(
  options: ToggleAIOptions(
    clientId: 'pk_live_xxx',
    secret: 'sk_live_xxx',
  ),
);

// 2. Initialize (fetches config payload, starts polling)
await client.init();

// 3. Evaluate flags
if (client.getFlag('new-onboarding', userId: 'user_42')) {
  showNewOnboarding();
}

// 4. Read remote config
final apiTimeout = client.getConfig<int>('api_timeout_ms', defaultValue: 5000);

// 5. Logging & error monitoring
final logger = client.getLogger();
logger.info('App started');

// Capture Flutter framework errors:
FlutterError.onError = logger.captureFlutterError;
```

## Flutter Widget Integration

### Wrap your app with `ToggleAIProvider`

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final client = ToggleAIClient(
    options: ToggleAIOptions(
      clientId: 'pk_live_xxx',
      secret: 'sk_live_xxx',
      onReady: () => print('ToggleAI ready'),
      onError: (e) => print('ToggleAI error: $e'),
    ),
  );

  runApp(
    ToggleAIProvider(
      client: client,
      loadingBuilder: (_) => const CircularProgressIndicator(),
      child: const MyApp(),
    ),
  );
}
```

### Use `FlagBuilder` for reactive flag rendering

```dart
FlagBuilder(
  flagKey: 'new-checkout-ui',
  userId: 'user_42',
  attributes: {'plan': 'pro', 'country': 'US'},
  builder: (context, enabled, evaluation) {
    print('Reason: ${evaluation.reason}');
    return enabled ? const NewCheckout() : const OldCheckout();
  },
)
```

### Use `ConfigBuilder` for remote config

```dart
ConfigBuilder<String>(
  configKey: 'app_theme',
  defaultValue: 'light',
  builder: (context, theme) => Text('Theme: $theme'),
)
```

### Access the client anywhere

```dart
// In any widget below ToggleAIProvider:
final client = ToggleAIProvider.of(context);
final isDarkMode = client.getFlag('dark-mode');
```

### `ToggleAIMixin` for StatefulWidgets

```dart
class _HomeState extends State<HomeScreen> with ToggleAIMixin {
  @override
  Widget build(BuildContext context) {
    final showBanner = getFlag(context, 'promo-banner');
    return showBanner ? const PromoBanner() : const SizedBox.shrink();
  }
}
```

## Logging & Error Monitoring

The SDK includes `ToggleAILogger` for edge-native logging and error capture. It automatically batches events and flushes them to the backend in the background.

### Attached Logger
Get a pre-configured logger that shares the client's API keys:
```dart
final logger = client.getLogger();

// Log with structured context
logger.debug('Debugging query', context: {'queryId': 'q_1'});
logger.info('Task completed');
logger.warn('Rate limit approaching');
logger.error('Database connection failed', error: dbError);
logger.fatal('System out of memory');
```

### Flutter Error Capture
You can automatically catch Flutter widget and layout errors:

```dart
import 'package:flutter/widgets.dart';

void main() {
  final client = ToggleAIClient(
    options: ToggleAIOptions(clientId: '...', secret: '...'),
  );
  final logger = client.getLogger();

  FlutterError.onError = logger.captureFlutterError;
  
  runApp(MyApp());
}
```

### Batching & Flushing
Logs are queued in memory and batched. By default, they flush every 5 seconds or when 50 events are queued. You should manually flush before shutting down your app:

```dart
await logger.flush();
```

---

## A/B Testing & Experiments

The ToggleAI SDK supports robust A/B testing and experiment tracking in Flutter/Dart, allowing you to measure conversion rates, user exposure, and target metrics natively.

### 1. Auto-Exposure Tracking

When you evaluate a feature flag that has a running experiment attached to it, the SDK **automatically** sends an exposure event to the backend in the background (fire-and-forget, with session-level deduplication so it doesn't spam requests).

```dart
// Simply evaluating the flag triggers the exposure event under the hood!
final result = client.getEvaluation('new-hero-variant', 
  context: EvaluationContext(userId: 'user_123'));
```

### 2. Zero-Code Event Tracking

Track meaningful business actions globally. The backend automatically attributes these events to any running experiments whose metrics match the `metricKey`.

```dart
// Track a single event
await client.track(TrackEventOptions(
  metricKey: 'purchase_completed',
  userIdentifier: 'user_123',
  value: 49.99, // Optional revenue or metric value
));

// Track multiple events in batch (up to 100)
await client.trackBatch([
  TrackEventOptions(metricKey: 'page_view', userIdentifier: 'user_123'),
  TrackEventOptions(metricKey: 'add_to_cart', userIdentifier: 'user_123', value: 1.0),
]);
```

### 3. Explicit Experiment Conversion Tracking

If you need precision control over when a user converts for a specific A/B experiment, you can resolve the `variationId` and send a manual conversion:

```dart
// 1. Evaluate the flag
final result = client.getEvaluation('checkout-layout', 
  context: EvaluationContext(userId: 'user_123'));

// 2. Resolve the variation's database UUID
final variationId = client.resolveVariationId('checkout-layout', result.variationKey);

// 3. Track conversion when the action occurs
if (variationId != null) {
  await client.trackConversion(TrackConversionOptions(
    experimentId: 'exp_checkout_redesign',
    variationId: variationId,
    metricKey: 'checkout_conversion',
    userId: 'user_123',
    value: 1.0, // Optional value
  ));
}
```

### 4. Manual Exposure Recording

For special setups (like server-side rendering or non-standard routing), you can also manually register exposures:

```dart
await client.recordExposure(ExposureOptions(
  experimentId: 'exp_checkout_redesign',
  variationId: 'var_redesign_a',
  userIdentifier: 'user_123',
));
```

---

## API Reference

### `ToggleAIOptions`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `clientId` | `String` | required | Public client ID (`pk_live_xxx`) |
| `secret` | `String` | required | Private secret (`sk_live_xxx`) |
| `baseUrl` | `String` | hosted URL | Backend API base URL |
| `pollingInterval` | `Duration` | 30 seconds | Config refresh interval. `Duration.zero` disables polling. |
| `evaluationMode` | `EvaluationMode` | `.local` | `.local` (in-memory) or `.server` (real-time) |
| `disableCache` | `bool` | `false` | Skip initial payload fetch (use async methods only) |
| `defaultContext` | `EvaluationContext?` | `null` | Default user context for all evaluations |
| `timeout` | `Duration` | 10 seconds | HTTP request timeout |
| `onReady` | `Function?` | `null` | Called when client is fully initialized |
| `onConfigUpdate` | `Function?` | `null` | Called on every config payload refresh |
| `onError` | `Function?` | `null` | Called on fetch/polling errors |

### `ToggleAIClient`

#### Lifecycle
| Method | Description |
|--------|-------------|
| `init()` | Fetch config and start polling. Safe to call multiple times. |
| `close()` | Stop polling and release resources. |
| `refresh()` | Manually refresh the config payload. |
| `waitForReady()` | Await until client is ready. |

#### Feature Flags (Local Evaluation)
| Method | Returns | Description |
|--------|---------|-------------|
| `getFlag(key, {userId, attributes, defaultValue})` | `bool` | Boolean flag, local eval |
| `getFlagAsync(key, ...)` | `Future<bool>` | Boolean flag, server if needed |
| `getFlagValue<T>(key, ...)` | `T?` | Typed flag value, local eval |
| `getFlagValueAsync<T>(key, ...)` | `Future<T?>` | Typed flag value, server if needed |
| `getEvaluation(key, {context})` | `FlagEvaluationResult` | Full evaluation result |
| `evaluateAllFlags({context})` | `Map<String, FlagEvaluationResult>` | All flags, local eval |

#### Server-Side Evaluation
| Method | Returns | Description |
|--------|---------|-------------|
| `evaluateFlagRemote(key, {context})` | `Future<FlagEvaluationResult>` | Real-time single flag |
| `evaluateAllFlagsRemote({context})` | `Future<Map<String, FlagEvaluationResult>>` | Real-time all flags |

#### Remote Config
| Method | Returns | Description |
|--------|---------|-------------|
| `getConfig<T>(key, {defaultValue})` | `T?` | Typed config value |
| `getConfigAsync<T>(key, {defaultValue})` | `Future<T?>` | Config, server if needed |
| `getAllConfigs()` | `Map<String, dynamic>` | All configs as flat map |
| `hasConfig(key)` | `bool` | Check if config key exists |

### `ToggleAILogger`

| Method | Returns | Description |
|--------|---------|-------------|
| `client.getLogger()` | `ToggleAILogger` | Get the attached logger instance |
| `debug(msg, {context})` | `void` | Log a debug message |
| `info(msg, {context})` | `void` | Log an info message |
| `warn(msg, {error, stackTrace, context})` | `void` | Log a warning message |
| `error(msg, {error, stackTrace, context})`| `void` | Log an error message |
| `fatal(msg, {error, stackTrace, context})`| `void` | Log a fatal message |
| `captureError(error, {stackTrace, context})`| `void` | Capture an Exception/Error object |
| `captureFlutterError(details)` | `void` | Intercept `FlutterErrorDetails` |
| `setContext(context)` | `void` | Set global context for all logs |
| `flush()` | `Future<void>` | Manually flush queued logs |

### A/B Testing & Experiments

| Method | Returns | Description |
|--------|---------|-------------|
| `track(event)` | `Future<TrackEventResult>` | Track a generic event for auto-attribution |
| `trackBatch(events)` | `Future<TrackEventResult>` | Track multiple events in a single batch |
| `trackConversion(opts)` | `Future<TrackConversionResult>` | Track explicit conversion for an experiment |
| `resolveVariationId(flagKey, varKey)`| `String?` | Convert variation key string to DB variation UUID |
| `recordExposure(exposure)` | `Future<ExposureResult>` | Manually record user exposure to a variation |
| `recordExposures(exposures)` | `Future<ExposureResult>` | Manually record multiple user exposures |
| `activeExperiments` (getter) | `List<ExperimentPayloadItem>`| List all running experiments |
| `getExperimentForFlag(flagKey)`| `ExperimentPayloadItem?`| Get experiment details for a specific flag |

### Evaluation Order

The SDK evaluates flags in this exact order (matching the backend):

1. **OFF** — Flag is disabled globally
2. **KILLED** — Kill switch is enabled
3. **OVERRIDE** — User has a specific override value
4. **TARGETING_MATCH** — A targeting rule matched (evaluated by priority)
5. **ROLLOUT** — User is outside the rollout percentage (consistent hash bucketing)
6. **DEFAULT** — Flag is enabled, return default value

### Authentication

The SDK authenticates using the `Authorization: Bearer <clientId>:<secret>` header pattern defined in the backend `sdk_controller.ts`.

## License

MIT
