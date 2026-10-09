import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeric/homeric.dart';

void main() {
  testWidgets('measureContent returns a finite size under maxWidth',
      (tester) async {
    final controller = HomericEditorController(
      document: Document([
        Block(
          id: 'a',
          type: 'paragraph',
          runs: [InlineRun('Short line')],
        ),
        Block(
          id: 'b',
          type: 'paragraph',
          runs: [
            InlineRun(
              'A longer paragraph that should wrap when the max width is narrow.',
            ),
          ],
        ),
      ]),
    );
    addTearDown(controller.dispose);

    final extent = controller.measureContent(maxWidth: 120);
    expect(extent.maxWidth, 120);
    expect(extent.size.width, lessThanOrEqualTo(120));
    expect(extent.size.height, greaterThan(0));

    final wider = controller.measureContent(maxWidth: 400);
    expect(wider.size.height, lessThanOrEqualTo(extent.size.height));
  });

  test('empty document measures as zero size', () {
    final extent = measureDocumentContent(Document(), maxWidth: 200);
    expect(extent.size, Size.zero);
  });
}
