/// ToggleAI SDK — Flutter Widget Integration
///
/// Provides React-Context-style access to the [ToggleAIClient] throughout
/// a Flutter widget tree.
///
/// Usage:
/// ```dart
/// // Wrap your app (or a subtree) with ToggleAIProvider
/// void main() async {
///   final client = ToggleAIClient(
///     options: ToggleAIOptions(
///       clientId: 'pk_live_xxx',
///       secret: 'sk_live_xxx',
///     ),
///   );
///
///   runApp(
///     ToggleAIProvider(
///       client: client,
///       child: const MyApp(),
///     ),
///   );
/// }
///
/// // Access the client anywhere in the tree
/// class MyWidget extends StatelessWidget {
///   @override
///   Widget build(BuildContext context) {
///     final client = ToggleAIProvider.of(context);
///     final isDark = client.getFlag('dark-mode');
///     return Text(isDark ? 'Dark' : 'Light');
///   }
/// }
///
/// // Or use FlagBuilder for reactive flag rendering
/// FlagBuilder(
///   flagKey: 'new-checkout',
///   userId: 'user_42',
///   builder: (context, enabled, _) {
///     return enabled ? NewCheckout() : OldCheckout();
///   },
/// );
/// ```

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'client.dart';
import 'types.dart';

// ─────────────────────────────────────────────────────────────
// ToggleAIProvider
// ─────────────────────────────────────────────────────────────

/// Provides a [ToggleAIClient] to the widget tree via [InheritedWidget].
///
/// Initializes the client on mount and closes it on dispose.
/// Rebuilds the tree when the config payload is updated (polling cycle).
class ToggleAIProvider extends StatefulWidget {
  const ToggleAIProvider({
    super.key,
    required this.client,
    required this.child,
    this.loadingBuilder,
    this.errorBuilder,
  });

  /// The ToggleAI client to provide to the widget tree.
  final ToggleAIClient client;

  /// The widget to render once the client is ready.
  final Widget child;

  /// Optional widget to display while the client is initializing.
  final WidgetBuilder? loadingBuilder;

  /// Optional widget to display if initialization fails.
  final Widget Function(BuildContext context, ToggleAIException error)? errorBuilder;

  /// Get the nearest [ToggleAIClient] from the widget tree.
  ///
  /// Throws if no [ToggleAIProvider] is found in the ancestor chain.
  static ToggleAIClient of(BuildContext context) {
    final inherited =
        context.dependOnInheritedWidgetOfExactType<_ToggleAIInherited>();
    if (inherited == null) {
      throw FlutterError(
        'ToggleAIProvider.of() called with a context that does not contain a ToggleAIProvider.\n'
        'Make sure to wrap your app (or subtree) with a ToggleAIProvider widget.',
      );
    }
    return inherited.client;
  }

  /// Get the nearest [ToggleAIClient] without registering for updates.
  static ToggleAIClient? maybeOf(BuildContext context) {
    return context
        .getInheritedWidgetOfExactType<_ToggleAIInherited>()
        ?.client;
  }

  @override
  State<ToggleAIProvider> createState() => _ToggleAIProviderState();
}

class _ToggleAIProviderState extends State<ToggleAIProvider> {
  ClientState _clientState = ClientState.idle;
  ToggleAIException? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    widget.client.init().then((_) {
      if (mounted) {
        setState(() => _clientState = ClientState.ready);
      }
    }).catchError((Object e) {
      if (mounted) {
        setState(() {
          _clientState = ClientState.error;
          _error = e is ToggleAIException
              ? e
              : ToggleAIException(ToggleAIErrorCode.networkError, e.toString());
        });
      }
    });

    // Poll the client state periodically to catch payload updates from polling
    _startStateSync();
  }

  void _startStateSync() {
    Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final newState = widget.client.state;
      if (newState != _clientState) {
        setState(() => _clientState = newState);
      }
      if (newState == ClientState.closed) {
        timer.cancel();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_clientState == ClientState.error && _error != null) {
      if (widget.errorBuilder != null) {
        return widget.errorBuilder!(context, _error!);
      }
      return const SizedBox.shrink();
    }

    if (_clientState == ClientState.initializing ||
        _clientState == ClientState.idle) {
      if (widget.loadingBuilder != null) {
        return widget.loadingBuilder!(context);
      }
      return const SizedBox.shrink();
    }

    return _ToggleAIInherited(
      client: widget.client,
      version: widget.client.rawPayload?.generatedAt ?? 0,
      child: widget.child,
    );
  }
}

/// Internal [InheritedWidget] that propagates the [ToggleAIClient].
class _ToggleAIInherited extends InheritedWidget {
  const _ToggleAIInherited({
    required this.client,
    required this.version,
    required super.child,
  });

  final ToggleAIClient client;

  /// Version key — changes whenever the config payload is updated,
  /// triggering rebuilds in dependent widgets.
  final int version;

  @override
  bool updateShouldNotify(_ToggleAIInherited oldWidget) {
    return version != oldWidget.version || client != oldWidget.client;
  }
}

// ─────────────────────────────────────────────────────────────
// FlagBuilder
// ─────────────────────────────────────────────────────────────

/// A widget that evaluates a feature flag and rebuilds when the value changes.
///
/// ```dart
/// FlagBuilder(
///   flagKey: 'new-checkout-ui',
///   userId: 'user_42',
///   builder: (context, enabled, evaluation) {
///     return enabled ? const NewCheckout() : const OldCheckout();
///   },
/// );
/// ```
class FlagBuilder extends StatelessWidget {
  const FlagBuilder({
    super.key,
    required this.flagKey,
    required this.builder,
    this.userId,
    this.attributes,
    this.defaultValue = false,
  });

  /// The feature flag key to evaluate.
  final String flagKey;

  /// User ID for targeting and rollout bucketing.
  final String? userId;

  /// User attributes for targeting rule evaluation.
  final Map<String, dynamic>? attributes;

  /// Default value if the flag is not found.
  final bool defaultValue;

  /// Builder function called with the flag result.
  ///
  /// - [enabled]: Whether the flag is enabled for this user.
  /// - [evaluation]: Full evaluation result including reason and variationKey.
  final Widget Function(
    BuildContext context,
    bool enabled,
    FlagEvaluationResult evaluation,
  ) builder;

  @override
  Widget build(BuildContext context) {
    final client = ToggleAIProvider.of(context);
    final result = client.getEvaluation(
      flagKey,
      context: EvaluationContext(userId: userId, attributes: attributes),
    );

    final enabled = (result.reason == EvaluationReason.flagNotFound ||
            result.reason == EvaluationReason.error)
        ? defaultValue
        : (result.value == true || result.value == 1 || result.value == 'true');

    return builder(context, enabled, result);
  }
}

// ─────────────────────────────────────────────────────────────
// ConfigBuilder
// ─────────────────────────────────────────────────────────────

/// A widget that reads a remote config value and rebuilds when it changes.
///
/// ```dart
/// ConfigBuilder<String>(
///   configKey: 'app_theme',
///   defaultValue: 'light',
///   builder: (context, value) => Text('Theme: $value'),
/// );
/// ```
class ConfigBuilder<T> extends StatelessWidget {
  const ConfigBuilder({
    super.key,
    required this.configKey,
    required this.builder,
    this.defaultValue,
  });

  /// The remote config key to read.
  final String configKey;

  /// Default value if the config key is not found.
  final T? defaultValue;

  /// Builder function called with the config value.
  final Widget Function(BuildContext context, T? value) builder;

  @override
  Widget build(BuildContext context) {
    final client = ToggleAIProvider.of(context);
    final value = client.getConfig<T>(configKey, defaultValue: defaultValue);
    return builder(context, value);
  }
}

// ─────────────────────────────────────────────────────────────
// useFlag / useConfig hooks (StatefulWidget helpers)
// ─────────────────────────────────────────────────────────────

/// Mixin that provides flag and config access to [StatefulWidget] states.
///
/// ```dart
/// class _MyWidgetState extends State<MyWidget> with ToggleAIMixin {
///   @override
///   Widget build(BuildContext context) {
///     final darkMode = getFlag(context, 'dark-mode');
///     return Container(color: darkMode ? Colors.black : Colors.white);
///   }
/// }
/// ```
mixin ToggleAIMixin<T extends StatefulWidget> on State<T> {
  /// Get the [ToggleAIClient] from the widget tree.
  ToggleAIClient get toggleAI => ToggleAIProvider.of(context);

  /// Evaluate a boolean feature flag.
  bool getFlag(
    BuildContext context,
    String key, {
    String? userId,
    Map<String, dynamic>? attributes,
    bool defaultValue = false,
  }) {
    return ToggleAIProvider.of(context).getFlag(
      key,
      userId: userId,
      attributes: attributes,
      defaultValue: defaultValue,
    );
  }

  /// Get a remote config value.
  V? getConfig<V>(BuildContext context, String key, {V? defaultValue}) {
    return ToggleAIProvider.of(context).getConfig<V>(key, defaultValue: defaultValue);
  }
}
