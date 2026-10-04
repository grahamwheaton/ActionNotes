import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/models/view_preferences.dart';
import 'package:actionnotes/storage/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('preferences round-trip and preserve existing device pins', () async {
    SharedPreferences.setMockInitialValues({'android_pinned_projects': ['work']});
    final store = SettingsStore();
    expect(await store.loadProjectPins(), {'work'});
    await store.saveViewPreferences(const ViewPreferences(sidebarWidth: 360,
      projectSort: ProjectSort.stars, formatting: NoteFormatting(
        horizontalMargin: 56, verticalMargin: 40, fontSize: 20,
        lineHeight: 1.8, paragraphSpacing: 14, headingScale: 1.2, font: 'Monospace')));
    final restored = await SettingsStore().loadViewPreferences();
    expect(restored.sidebarWidth, 360);
    expect(restored.projectSort, ProjectSort.stars);
    expect(restored.formatting.horizontalMargin, 56);
    expect(restored.formatting.font, 'Monospace');
    expect(restored.formatting.fontSize, 20);
    await store.saveProjectPins({'home'});
    expect(await store.loadProjectPins(), {'home'});
  });
  test('damaged or out-of-range preferences recover safely', () async {
    SharedPreferences.setMockInitialValues({'view_preferences': 'broken'});
    expect((await SettingsStore().loadViewPreferences()).sidebarWidth, 280);
    final value = ViewPreferences.fromJson({'sidebarWidth': 9000,
      'projectSort': 'unknown', 'formatting': {'fontSize': -10, 'font': 'missing'}});
    expect(value.sidebarWidth, 600);
    expect(value.projectSort, ProjectSort.recent);
    expect(value.formatting.fontSize, 12);
    expect(value.formatting.font, 'System');
  });
  test('sort options use timestamps, names and star counts with stable ties', () {
    final projects = [
      Project(slug: 'alpha', title: 'Alpha', updated: DateTime(2026, 1, 1)),
      Project(slug: 'zulu', title: 'Zulu', updated: DateTime(2026, 1, 3)),
      Project(slug: 'beta', title: 'Beta', updated: DateTime(2026, 1, 2),
        items: const [ChecklistItem(text: 'Star', starred: true)]),
    ];
    List<String> order(ProjectSort sort) => sort.sorted(projects).map((p) => p.slug).toList();
    expect(order(ProjectSort.recent), ['zulu', 'beta', 'alpha']);
    expect(order(ProjectSort.alphabetical), ['alpha', 'beta', 'zulu']);
    expect(order(ProjectSort.stars), ['beta', 'alpha', 'zulu']);
  });
}
