const _firstFrameBudgetUs = 500000;
const _coldMountP95BudgetUs = 50000;
const _scrollP50BudgetUs = 16000;
const _scrollP95BudgetUs = 33000;
const _activeWidgetsBudget = 500;
const _layoutBudgetUs = 200000;
const _paragraphCacheEntryLimitExclusive = 2049;
const _paragraphCacheTextCodeUnitLimitExclusive = 1000001;
const _baselineP95TolerancePercent = 5;

String? instrumentationCalibrationFailure(Map<String, Object?> result) {
  final calibration = _map(result, 'calibration');
  final delta = _integer(
    calibration,
    'paired_total_p95_delta_basis_points',
    path: 'calibration',
  );
  final layoutCount = _integer(
    calibration,
    'layout_total_count',
    path: 'calibration',
  );
  if (layoutCount <= 0) {
    return 'instrumentation calibration recorded no paragraph layouts';
  }
  if (delta.abs() > _baselineP95TolerancePercent * 100) {
    return 'instrumentation calibration was noisy: $delta bp';
  }
  if (calibration['valid'] != true) {
    return 'instrumentation calibration validity flag disagrees with '
        'recorded evidence';
  }
  return null;
}

List<String> largeGeneratedBudgetFailures({
  required Map<String, Object?> result,
  required Map<String, Object?> accepted,
}) {
  final schema = _integer(accepted, 'schema', path: 'accepted');
  if (schema != 1) {
    throw FormatException(
      'Unsupported benchmarks/accepted.json schema: $schema',
    );
  }

  final scrollDisabled = _map(result, 'scroll_disabled');
  final coldMount = _map(result, 'cold_mount');
  final homeric = _map(result, 'homeric');
  final observed = _map(accepted, 'observed');
  final fixture = _map(accepted, 'fixture');

  final firstFrameUs = _integer(
    homeric,
    'cold_load_first_frame_us',
    path: 'homeric',
  );
  final coldMountP95Us = _integer(
    coldMount,
    'total_p95_us',
    path: 'cold_mount',
  );
  final scrollP50Us = _integer(
    scrollDisabled,
    'total_p50_us',
    path: 'scroll_disabled',
  );
  final scrollP95Us = _integer(
    scrollDisabled,
    'total_p95_us',
    path: 'scroll_disabled',
  );
  final activeWidgets = _integer(
    homeric,
    'max_mounted_rows',
    path: 'homeric',
  );
  final layoutUs = _integer(
    homeric,
    'layout_median_sample_us',
    path: 'homeric',
  );
  final paragraphCacheEntries = _integer(
    homeric,
    'paragraph_cache_entries',
    path: 'homeric',
  );
  final paragraphCacheTextCodeUnits = _integer(
    homeric,
    'paragraph_cache_text_code_units',
    path: 'homeric',
  );

  final failures = <String>[];
  _requireEqual(
    failures,
    label: 'fixture file',
    actual: _string(homeric, 'fixture', path: 'homeric'),
    expected: _string(fixture, 'file', path: 'accepted.fixture'),
  );
  _requireEqual(
    failures,
    label: 'benchmark scenario',
    actual: _string(homeric, 'scenario', path: 'homeric'),
    expected: 'generated',
  );
  _requireEqual(
    failures,
    label: 'fixture word count',
    actual: _integer(homeric, 'fixture_words', path: 'homeric'),
    expected: _integer(fixture, 'words', path: 'accepted.fixture'),
  );
  _requireEqual(
    failures,
    label: 'fixture block count',
    actual: _integer(homeric, 'blocks', path: 'homeric'),
    expected: _integer(fixture, 'blocks', path: 'accepted.fixture'),
  );
  _requireEqual(
    failures,
    label: 'fixture fingerprint',
    actual: _string(homeric, 'fixture_fnv1a32', path: 'homeric'),
    expected: _string(fixture, 'fnv1a32', path: 'accepted.fixture'),
  );
  _requireUnder(
    failures,
    label: 'time to first frame',
    actual: firstFrameUs,
    budget: _firstFrameBudgetUs,
    unit: 'us',
  );
  _requireUnder(
    failures,
    label: 'detached paragraph cache entries',
    actual: paragraphCacheEntries,
    budget: _paragraphCacheEntryLimitExclusive,
    unit: 'entries',
  );
  _requireUnder(
    failures,
    label: 'detached paragraph cache text',
    actual: paragraphCacheTextCodeUnits,
    budget: _paragraphCacheTextCodeUnitLimitExclusive,
    unit: 'UTF-16 code units',
  );
  _requireUnder(
    failures,
    label: 'cold-load p95 frame time',
    actual: coldMountP95Us,
    budget: _coldMountP95BudgetUs,
    unit: 'us',
  );
  _requireUnder(
    failures,
    label: 'scroll p50 frame time',
    actual: scrollP50Us,
    budget: _scrollP50BudgetUs,
    unit: 'us',
  );
  _requireUnder(
    failures,
    label: 'scroll p95 frame time',
    actual: scrollP95Us,
    budget: _scrollP95BudgetUs,
    unit: 'us',
  );
  _requireUnder(
    failures,
    label: 'active widget count',
    actual: activeWidgets,
    budget: _activeWidgetsBudget,
    unit: 'widgets',
  );
  _requireUnder(
    failures,
    label: 'five-second cumulative paragraph layout',
    actual: layoutUs,
    budget: _layoutBudgetUs,
    unit: 'us',
  );

  // The older accepted cold summary used unbounded two-or-three-frame callback
  // batches, while the corrected harness records eight exact one-frame mounts.
  // Keep the binding 50 ms absolute budget for the current method; use the
  // accepted relative gate only for comparable exact-100-frame warmed scroll.
  _requireP95WithinBaseline(
    failures,
    label: 'scroll p95 frame time',
    actual: scrollP95Us,
    baseline: _integer(
      observed,
      'scroll_disabled_total_p95_us',
      path: 'accepted.observed',
    ),
  );
  return failures;
}

Map<String, Object?> _map(Map<String, Object?> parent, String key) {
  final value = parent[key];
  if (value is Map<String, Object?>) return value;
  throw FormatException('Expected $key to be a JSON object');
}

int _integer(
  Map<String, Object?> parent,
  String key, {
  required String path,
}) {
  final value = parent[key];
  if (value is int) return value;
  throw FormatException('Expected $path.$key to be an integer');
}

String _string(
  Map<String, Object?> parent,
  String key, {
  required String path,
}) {
  final value = parent[key];
  if (value is String) return value;
  throw FormatException('Expected $path.$key to be a string');
}

void _requireEqual<T>(
  List<String> failures, {
  required String label,
  required T actual,
  required T expected,
}) {
  if (actual == expected) return;
  failures.add('$label mismatch: $actual vs expected $expected');
}

void _requireUnder(
  List<String> failures, {
  required String label,
  required int actual,
  required int budget,
  required String unit,
}) {
  if (actual < budget) return;
  failures.add('$label: $actual $unit (must be < $budget $unit)');
}

void _requireP95WithinBaseline(
  List<String> failures, {
  required String label,
  required int actual,
  required int baseline,
}) {
  if (actual * 100 <= baseline * (100 + _baselineP95TolerancePercent)) {
    return;
  }
  final regression = (actual / baseline - 1) * 100;
  failures.add(
    '$label regression: $actual us vs $baseline us baseline '
    '(${regression.toStringAsFixed(1)}%; max +5.0%)',
  );
}
