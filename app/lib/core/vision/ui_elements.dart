import 'dart:math';

/// One actionable node of the accessibility tree (AT-SPI on Linux, the
/// AccessibilityNodeInfo tree on Android), in real screen pixels.
class UiElement {
  const UiElement({required this.role, required this.name, required this.bounds});

  /// Normalized role: button, entry, check box, link, tab, menu item, list item, ...
  final String role;
  final String name;
  final Rectangle<int> bounds;

  Point<int> get center => Point(bounds.left + bounds.width ~/ 2, bounds.top + bounds.height ~/ 2);

  String describe() => name.isEmpty ? role : "$role '$name'";

  factory UiElement.fromJson(Map<Object?, Object?> j) => UiElement(
    role: '${j['role'] ?? ''}',
    name: '${j['name'] ?? ''}',
    bounds: Rectangle(
      (j['x'] as num).toInt(),
      (j['y'] as num).toInt(),
      (j['w'] as num).toInt(),
      (j['h'] as num).toInt(),
    ),
  );

  @override
  String toString() => '${describe()} @${bounds.left},${bounds.top} ${bounds.width}x${bounds.height}';
}

/// The visible actionable elements of the screen right now.
abstract class ElementSource {
  Future<List<UiElement>> elements();
}

const _stop = {
  'the', 'a', 'an', 'on', 'in', 'at', 'of', 'to', 'for', 'with', 'and', 'or', 'that', 'which', 'says', 'labelled',
  'labeled', 'named', 'called', 'click', 'tap', 'press', 'open', 'select', 'please', 'it', 'this', 'its', 'one',
  'itself', 'box', 'small', 'big', 'large', 'little', 'go', 'show', 'choose', 'pick', 'hit', 'into', 'from', 'by', 'is',
};

/// Words that name a role, and the roles they fit.
const _roleWords = <String, List<String>>{
  'button': ['button', 'push button', 'toggle button', 'menu button', 'image', 'icon'],
  'btn': ['button', 'push button', 'toggle button'],
  'icon': ['button', 'push button', 'toggle button', 'image', 'icon', 'menu button'],
  'field': ['entry', 'text', 'password text', 'search', 'combo box', 'spin button'],
  'input': ['entry', 'text', 'password text', 'search', 'combo box'],
  'textbox': ['entry', 'text', 'search'],
  'search': ['entry', 'search', 'text'],
  'checkbox': ['check box', 'checkbox', 'toggle button', 'switch'],
  'check': ['check box', 'checkbox'],
  'toggle': ['toggle button', 'switch', 'check box'],
  'switch': ['switch', 'toggle button', 'check box'],
  'link': ['link'],
  'tab': ['page tab', 'tab'],
  'menu': ['menu', 'menu item', 'menu button'],
  'item': ['list item', 'menu item', 'tree item', 'table cell'],
  'folder': ['list item', 'tree item', 'table cell'],
  'radio': ['radio button', 'radio'],
  'dropdown': ['combo box', 'menu button', 'list box'],
  'combo': ['combo box'],
};

List<String> _words(String s) =>
    s.toLowerCase().replaceAll(RegExp(r"[^\p{L}\p{N}]+", unicode: true), ' ').trim().split(' ').where((w) => w.isNotEmpty).toList();

/// Quoted label in the description ('Save', "Remember me", “OK”).
String? quotedLabel(String target) {
  final m = RegExp('["“”\'‘’]([^"“”\'‘’]{1,60})["“”\'‘’]').firstMatch(target);
  final q = m?[1]?.trim();
  return q == null || q.isEmpty ? null : q;
}

/// Whether the role named by a word in [target] ("button", "field",
/// "checkbox") fits [role]; null when the description names no role.
bool? roleFits(String target, String role) {
  final r = role.toLowerCase();
  bool? fits;
  for (final w in _words(target)) {
    final roles = _roleWords[w];
    if (roles == null) continue;
    if (roles.any((x) => r.contains(x))) return true;
    fits = false;
  }
  return fits;
}

/// Whether [e]'s whole name occurs in [target] (a quoted label must equal
/// it). Names made of filler words only ("Open", "Select") never match.
bool nameOccurs(String target, UiElement e) {
  final name = _words(e.name);
  if (name.isEmpty || name.length > 8 || name.every(_stop.contains)) return false;
  final quoted = quotedLabel(target);
  if (quoted != null) return _words(quoted).join(' ') == name.join(' ');
  return ' ${_words(target).join(' ')} '.contains(' ${name.join(' ')} ');
}

/// The element [target] means, when the accessibility tree says so
/// unambiguously. Candidates are the elements whose name occurs in the
/// description, narrowed to the role it names ("the Save button") and then
/// to the longest name ("Delete account" over "Delete"). One left: that one.
/// Several (five "Edit" buttons): [hint], the voice model's guess, decides
/// only when one is much nearer than the rest. Null = let vision decide.
UiElement? matchElement(String target, List<UiElement> els, {Point<int>? hint}) {
  var c = [
    for (final e in els)
      if (e.bounds.width > 1 && e.bounds.height > 1 && nameOccurs(target, e)) e,
  ];
  if (c.isEmpty) return null;
  final byRole = [for (final e in c) if (roleFits(target, e.role) ?? true) e];
  if (byRole.isNotEmpty) c = byRole;
  final longest = c.map((e) => _words(e.name).length).reduce(max);
  c = [for (final e in c) if (_words(e.name).length == longest) e];
  // One control reported twice (same name, one box inside the other: a
  // table cell around its button, a list item around its link) counts once,
  // as the innermost box.
  final distinct = <UiElement>[];
  for (final e in c..sort((a, b) => _area(a).compareTo(_area(b)))) {
    if (!distinct.any((d) => _sameName(d, e) && _contains(e.bounds, d.bounds))) distinct.add(e);
  }
  if (distinct.length == 1) return distinct.first;
  if (hint == null) return null;
  distinct.sort((a, b) => _dist(a, hint).compareTo(_dist(b, hint)));
  final d0 = _dist(distinct[0], hint), d1 = _dist(distinct[1], hint);
  return d0 <= 0.5 * d1 ? distinct[0] : null;
}

int _area(UiElement e) => e.bounds.width * e.bounds.height;

bool _sameName(UiElement a, UiElement b) => _words(a.name).join(' ') == _words(b.name).join(' ');

bool _contains(Rectangle<int> outer, Rectangle<int> inner) =>
    inner.left >= outer.left && inner.top >= outer.top && inner.right <= outer.right && inner.bottom <= outer.bottom;

double _dist(UiElement e, Point<int> p) {
  final b = e.bounds;
  final dx = p.x < b.left ? b.left - p.x : (p.x > b.right ? p.x - b.right : 0);
  final dy = p.y < b.top ? b.top - p.y : (p.y > b.bottom ? p.y - b.bottom : 0);
  return sqrt(dx * dx + dy * dy).toDouble();
}
