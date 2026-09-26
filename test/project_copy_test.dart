import 'package:actionnotes/models/canvas_layout.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/storage/project_copy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a project copy bundles its markdown, canvas and attachments', () async {
    final project = Project(slug: 'images', title: 'Images', items: const [
      ChecklistItem(text: 'Photo',
        notes: '![photo](../attachments/images/photo.png)'),
    ]);
    final bytes = await ProjectCopy.encode(project, CanvasLayout.empty,
      (reference) async {
        expect(reference, '../attachments/images/photo.png');
        return [1, 2, 3];
      });
    final decoded = ProjectCopy.decode(bytes);
    expect(decoded.markdown, contains('Photo'));
    expect(decoded.layout, contains('sections'));
    expect(decoded.attachments['photo.png'], [1, 2, 3]);
  });
}
