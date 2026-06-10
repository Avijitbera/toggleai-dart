/// ToggleAI Flutter SDK
///
/// A Flutter/Dart SDK for feature flags, remote config, logging and A/B testing.
///
/// Quick start:
/// ```dart
/// import 'package:toggleai/toggleai.dart';
///
/// final client = ToggleAIClient(
///   options: ToggleAIOptions(
///     clientId: 'pk_live_xxx',
///     secret: 'sk_live_xxx',
///   ),
/// );
///
/// await client.init();
///
/// // Check a feature flag
/// if (client.getFlag('new-onboarding', userId: 'user_42')) {
///   showNewOnboarding();
/// }
///
/// // Read remote config
/// final apiTimeout = client.getConfig<int>('api_timeout_ms', defaultValue: 5000);
///
/// // Logging + error monitoring
/// final logger = client.getLogger();
/// logger.info('App started');
///
/// // Capture Flutter framework errors:
/// FlutterError.onError = logger.captureFlutterError;
/// ```
///
/// Flutter widget usage:
/// ```dart
/// runApp(
///   ToggleAIProvider(
///     client: client,
///     child: const MyApp(),
///   ),
/// );
///
/// // In any descendant widget:
/// FlagBuilder(
///   flagKey: 'premium-ui',
///   builder: (ctx, enabled, _) => enabled ? PremiumUI() : StandardUI(),
/// );
/// ```
library;

// Core
export 'src/types.dart';
export 'src/client.dart';
export 'src/evaluator.dart' show hashBucket;

// Logging
export 'src/logger.dart';

// Flutter widgets
export 'src/flutter_widget.dart';
