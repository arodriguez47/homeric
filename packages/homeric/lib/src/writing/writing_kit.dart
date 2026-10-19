/// The set of writing features an app installs on its editor.
library;

import 'package:flutter/foundation.dart';

import '../editing/editor_controller.dart';
import 'smart_punctuation.dart';
import 'writing_feature.dart';

/// The writing features an app runs, installed together.
///
/// [HomericWritingKit.standard] is every feature that needs nothing from the
/// host, at its defaults. A feature added to Homeric joins it, so an app
/// built on the standard kit picks it up by bumping Homeric; an app turns one
/// off by naming its [HomericWritingFeature.id] in `without`, or replaces it
/// with its own configuration in `with_`. Features that need the host (a
/// note resolver, a composer) are passed in `with_` by the app that has them.
@immutable
final class HomericWritingKit {
  /// A kit of exactly [features], in install order.
  HomericWritingKit(Iterable<HomericWritingFeature> features)
      : features = List<HomericWritingFeature>.unmodifiable(features) {
    final ids = <String>{};
    for (final feature in this.features) {
      if (!ids.add(feature.id)) {
        throw ArgumentError.value(
          feature.id,
          'features',
          'Each writing feature can be in a kit once',
        );
      }
    }
  }

  /// Every host-free feature at its defaults, minus the ids in [without];
  /// a feature in [with_] replaces the standard one with its id, or joins the
  /// kit when it has none.
  factory HomericWritingKit.standard({
    Set<String> without = const <String>{},
    Iterable<HomericWritingFeature> with_ = const <HomericWritingFeature>[],
  }) {
    final chosen = <String, HomericWritingFeature>{
      for (final feature in standardFeatures)
        if (!without.contains(feature.id)) feature.id: feature,
    };
    for (final feature in with_) {
      chosen[feature.id] = feature;
    }
    return HomericWritingKit(chosen.values);
  }

  /// No features: the editor as it is without this module.
  static final HomericWritingKit none =
      HomericWritingKit(const <HomericWritingFeature>[]);

  /// The features [HomericWritingKit.standard] starts from, in install
  /// order. A new host-free feature is added here.
  static const List<HomericWritingFeature> standardFeatures =
      <HomericWritingFeature>[
    HomericSmartPunctuation(),
  ];

  /// Features in install order; interceptors run in this order.
  final List<HomericWritingFeature> features;

  /// Whether the kit carries a feature with [id].
  bool has(String id) => features.any((feature) => feature.id == id);

  /// Installs every feature on [controller]; returns one callback that stops
  /// them all.
  VoidCallback installOn(HomericEditorController controller) {
    final stops = <VoidCallback>[
      for (final feature in features) feature.installOn(controller),
    ];
    return () {
      for (final stop in stops.reversed) {
        stop();
      }
    };
  }
}
