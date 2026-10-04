import 'package:actionnotes/markdown/portal_links.dart';
import 'package:actionnotes/models/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final personal = Project(slug: 'list', title: 'Personal');
  final shared = Project(
    slug: 'shared~list',
    sourceId: 'shared',
    title: 'Shared',
  );
  final projects = [personal, shared];

  test('old relative links stay in the containing notebook', () {
    expect(PortalLinks.resolve('list', 'shared~board', projects), same(shared));
    expect(PortalLinks.resolve('list', 'board', projects), same(personal));
    expect(PortalLinks.resolve('list', 'other~board', projects), isNull);
  });

  test('cross-notebook references preserve either direction explicitly', () {
    final toShared = PortalLinks.reference(shared, 'board');
    final toPersonal = PortalLinks.reference(personal, 'shared~board');
    expect(toShared, 'shared~list');
    expect(toPersonal, 'mine~list');
    expect(PortalLinks.resolve(toShared, 'board', projects), same(shared));
    expect(
      PortalLinks.resolve(toPersonal, 'shared~board', projects),
      same(personal),
    );
    expect(PortalLinks.reference(shared, 'shared~board'), 'list');
  });
}
