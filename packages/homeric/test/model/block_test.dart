import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/src/model/block.dart';
import 'package:homeric/src/model/inline_run.dart';

void main() {
  group('Block', () {
    test('reads back id, type, attributes, runs, and text', () {
      final block = Block(
        id: 'b1',
        type: 'paragraph',
        attributes: {'align': 'left'},
        runs: [
          InlineRun('Hello, '),
          InlineRun('world', attributes: {'bold': true}),
        ],
      );
      expect(block.id, 'b1');
      expect(block.type, 'paragraph');
      expect(block.attributes, {'align': 'left'});
      expect(block.runs, hasLength(2));
      expect(block.text, 'Hello, world');
      expect(block.contentLength, 12);
    });

    test('size is content length + 2 (opening and closing tokens)', () {
      final block = Block(id: 'b', type: 'paragraph', runs: [InlineRun('Hi')]);
      expect(block.size, 4);
    });

    test('an empty block has size 2', () {
      expect(Block(id: 'b', type: 'paragraph').size, 2);
      expect(Block(id: 'b', type: 'paragraph', runs: [InlineRun('')]).size, 2);
    });

    test('never assumes one run per block: multi-run content concatenates', () {
      final block = Block(
        id: 'b',
        type: 'paragraph',
        runs: [InlineRun('one'), InlineRun('two'), InlineRun('three')],
      );
      expect(block.text, 'onetwothree');
      expect(block.contentLength, 11);
      expect(block.size, 13);
    });

    test('preserves empty runs between non-empty runs (no normalization)', () {
      final block = Block(
        id: 'b',
        type: 'paragraph',
        runs: [InlineRun('ab'), InlineRun(''), InlineRun('cd')],
      );
      expect(block.runs, hasLength(3));
      expect(block.runs[1].isEmpty, isTrue);
      expect(block.text, 'abcd');
      expect(block.contentLength, 4);
      expect(block.size, 6);
    });

    test('preserves adjacent runs with identical attributes (no merging)', () {
      final block = Block(
        id: 'b',
        type: 'paragraph',
        runs: [
          InlineRun('he', attributes: {'bold': true}),
          InlineRun('llo', attributes: {'bold': true}),
        ],
      );
      expect(block.runs, hasLength(2));
      expect(block.runs[0].hasSameAttributesAs(block.runs[1]), isTrue);
      expect(block.text, 'hello');
      expect(block.size, 7);
    });

    test('runs list and attribute bag are unmodifiable', () {
      final block = Block(
        id: 'b',
        type: 'paragraph',
        attributes: {'k': 'v'},
        runs: [InlineRun('x')],
      );
      expect(() => block.runs.add(InlineRun('y')), throwsUnsupportedError);
      expect(() => block.attributes['k'] = 'w', throwsUnsupportedError);
    });

    test('copyWith always preserves the stable id', () {
      final block = Block(id: 'stable', type: 'paragraph');
      final edited = block
          .copyWith(type: 'heading')
          .copyWith(runs: [InlineRun('t')]).copyWith(attributes: {'l': 1});
      expect(edited.id, 'stable');
    });

    test('copyWith shares untouched runs and attributes by reference', () {
      final block = Block(
        id: 'b',
        type: 'paragraph',
        attributes: {'k': 'v'},
        runs: [InlineRun('x')],
      );
      final retyped = block.copyWith(type: 'heading');
      expect(identical(retyped.runs, block.runs), isTrue);
      expect(identical(retyped.attributes, block.attributes), isTrue);
      expect(retyped.contentLength, block.contentLength);

      final rewritten = block.copyWith(runs: [InlineRun('longer')]);
      expect(identical(rewritten.attributes, block.attributes), isTrue);
      expect(rewritten.contentLength, 6);
      expect(block.text, 'x');
    });
  });
}
