import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/src/model/attributes.dart';

void main() {
  group('freezeAttributes', () {
    test('accepts every JSON scalar kind', () {
      final frozen = freezeAttributes(<String, Object?>{
        'null': null,
        'bool': true,
        'int': 42,
        'double': 3.5,
        'string': 'hello',
      });
      expect(frozen['null'], isNull);
      expect(frozen['bool'], true);
      expect(frozen['int'], 42);
      expect(frozen['double'], 3.5);
      expect(frozen['string'], 'hello');
    });

    test('returns the canonical empty bag for an empty input', () {
      expect(identical(freezeAttributes(<String, Object?>{}), emptyAttributes),
          isTrue);
    });

    test('top-level map is unmodifiable', () {
      final frozen = freezeAttributes(<String, Object?>{'a': 1});
      expect(() => frozen['b'] = 2, throwsUnsupportedError);
      expect(() => frozen.remove('a'), throwsUnsupportedError);
    });

    test('nested maps and lists are unmodifiable at every depth', () {
      final frozen = freezeAttributes(<String, Object?>{
        'nested': <String, Object?>{
          'list': <Object?>[
            <String, Object?>{'deep': 1},
          ],
        },
      });
      final nested = frozen['nested']! as Map<String, Object?>;
      final list = nested['list']! as List<Object?>;
      final deep = list[0]! as Map<String, Object?>;
      expect(() => nested['x'] = 1, throwsUnsupportedError);
      expect(() => list.add(1), throwsUnsupportedError);
      expect(() => deep['deep'] = 2, throwsUnsupportedError);
    });

    test('mutating the source afterwards does not affect the frozen bag', () {
      final inner = <String, Object?>{'count': 1};
      final source = <String, Object?>{'inner': inner};
      final frozen = freezeAttributes(source);
      inner['count'] = 999;
      source['other'] = true;
      final frozenInner = frozen['inner']! as Map<String, Object?>;
      expect(frozenInner['count'], 1);
      expect(frozen.containsKey('other'), isFalse);
    });

    test('rejects non-JSON values with a path-bearing ArgumentError', () {
      expect(
        () => freezeAttributes(<String, Object?>{'when': DateTime(2026)}),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains(r'$.when'))),
      );
      expect(
        () => freezeAttributes(<String, Object?>{
          'a': <Object?>[
            <String, Object?>{'bad': Object()},
          ],
        }),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains(r'$.a[0].bad'))),
      );
      expect(
        () => freezeAttributes(<String, Object?>{
          'set': <int>{1}
        }),
        throwsArgumentError,
      );
    });

    test('rejects nested maps with non-String keys', () {
      expect(
        () => freezeAttributes(<String, Object?>{
          'map': <Object?, Object?>{1: 'one'},
        }),
        throwsArgumentError,
      );
    });
  });

  group('attributesEqual', () {
    test('deep-equal nested structures compare equal', () {
      final a = <String, Object?>{
        'x': <Object?>[
          1,
          <String, Object?>{'y': null},
        ],
      };
      final b = <String, Object?>{
        'x': <Object?>[
          1,
          <String, Object?>{'y': null},
        ],
      };
      expect(identical(a, b), isFalse);
      expect(attributesEqual(a, b), isTrue);
    });

    test('differing values, missing keys, and extra keys compare unequal', () {
      expect(
        attributesEqual(<String, Object?>{'a': 1}, <String, Object?>{'a': 2}),
        isFalse,
      );
      expect(
        attributesEqual(<String, Object?>{'a': 1}, <String, Object?>{'b': 1}),
        isFalse,
      );
      expect(
        attributesEqual(
          <String, Object?>{'a': 1},
          <String, Object?>{'a': 1, 'b': 2},
        ),
        isFalse,
      );
    });

    test('list order and length matter', () {
      expect(attributesEqual(<Object?>[1, 2], <Object?>[2, 1]), isFalse);
      expect(attributesEqual(<Object?>[1], <Object?>[1, 1]), isFalse);
      expect(attributesEqual(<Object?>[1, 2], <Object?>[1, 2]), isTrue);
    });

    test('frozen output deep-equals its source', () {
      final source = <String, Object?>{
        'n': 1,
        'nested': <String, Object?>{
          'list': <Object?>['a', false, null],
        },
      };
      expect(attributesEqual(freezeAttributes(source), source), isTrue);
    });
  });
}
