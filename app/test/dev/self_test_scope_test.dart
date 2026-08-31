import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/dev/self_test.dart';

import '../fixtures.dart';

void main() {
  group('what the self test is allowed to touch', () {
    // It edits the document it is given — imports, a caption, a shape on a
    // lane it makes — so which project it is pointed at is not a detail. When
    // this was gated on "the main track is empty" alone, every project made by
    // hand in a self-test build filled itself with sample media, which reads
    // as the editor inventing clips out of nowhere.
    test('its own project, by name', () {
      expect(isSelfTestProject(emptyProject().copyWith(name: 'Self test')),
          isTrue);
    });

    test('and nothing else, however empty', () {
      for (final name in ['Untitled', 'Untitled 3', 'self test', 'Holiday']) {
        expect(isSelfTestProject(emptyProject().copyWith(name: name)), isFalse,
            reason: '"$name" is somebody else\'s project');
      }
    });

    test('the name it opens is the name it recognises', () {
      // One constant behind both, so the project it creates cannot be one it
      // then declines to use.
      expect(selfTestProjectName, 'Self test');
      expect(
          isSelfTestProject(
              emptyProject().copyWith(name: selfTestProjectName)),
          isTrue);
    });
  });
}
