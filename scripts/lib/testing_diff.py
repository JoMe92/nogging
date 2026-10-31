"""The test-integrity analyser: what a diff does to the tests it touches.

Pure: it reads unified-diff text and returns findings, never running git. The
`scripts/check-test-integrity` script supplies the diff of a whole range
(`<base>...HEAD`) and the `Test-Integrity:` justifications; this module decides
what is a deleted test, a new skip or a fall in assertions (design Decision 10).

The range is analysed as one: a test, skip or assertion removed from one file
and added in another nets out, so a move or a rename is no finding, and a test
added and removed inside the range never shows. Findings are only about files
`TEST_PATH_RE` classifies as tests.
"""
import collections
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from token_usage_report import TEST_PATH_RE  # noqa: E402

DELETED_TEST = 'deleted-test'
DELETED_FILE = 'deleted-test-file'
NEW_SKIP = 'new-skip'
FEWER_ASSERTIONS = 'fewer-assertions'

# A directory of fixtures or test data matches TEST_PATH_RE but holds no tests.
DATA_DIR_RE = re.compile(r'(^|/)(fixtures|testdata)/')

LANG_BY_EXT = {
    '.py': 'python',
    '.js': 'js', '.jsx': 'js', '.mjs': 'js', '.cjs': 'js',
    '.ts': 'js', '.tsx': 'js', '.mts': 'js', '.cts': 'js',
    '.go': 'go',
    '.rs': 'rust',
    '.java': 'java', '.kt': 'java', '.kts': 'java',
    '.sh': 'shell', '.bash': 'shell',
}

# Test definitions: language -> (name patterns on one line, attribute patterns
# that mark the next definition line as a test). A name pattern's first
# non-None group is the test name. A language with an attribute table only
# counts a name line directly after (or on) an attribute line.
DEFINITIONS = {
    'python': {'names': [re.compile(r'^\s*(?:async\s+)?def\s+(test\w*)\s*\(')]},
    'js': {'names': [re.compile(
        r'(?:^|[^\w.$])(?:it|test)(?:\.(?:only|concurrent|skip|todo|failing))?'
        r'\s*\(\s*(?:\'((?:\\.|[^\'\\])*)\'|"((?:\\.|[^"\\])*)"|`((?:\\.|[^`\\])*)`)')]},
    'go': {'names': [re.compile(r'^func\s+((?:Test|Benchmark|Fuzz|Example)\w*)\s*\(')]},
    'rust': {'attrs': [re.compile(r'#\[\s*(?:\w+::)*test\b[^\]]*\]')],
             'names': [re.compile(r'^\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)\s*[(<]')]},
    'java': {'attrs': [re.compile(r'@(?:Test|ParameterizedTest|RepeatedTest|TestFactory)\b')],
             'names': [re.compile(r'^\s*(?:(?:public|protected|private|static|final)\s+)*'
                                  r'(?:void|fun)\s+(\w+)\s*\(')]},
}

# Skip and expected-failure forms, added lines only.
# Anchored at the start of the line: a skip form quoted inside a string, as in a
# test of this very rule, is not a skip.
SKIPS = {
    'python': [re.compile(p) for p in (
        r'^\s*@pytest\.mark\.(?:skip|skipif|xfail)\b', r'^\s*(?:return\s+)?pytest\.(?:skip|xfail)\s*\(',
        r'^\s*@(?:unittest\.)?(?:skip|skipIf|skipUnless|expectedFailure)\b',
        r'^\s*(?:self\.)?skipTest\s*\(')],
    'js': [re.compile(p) for p in (
        r'^\s*(?:it|test|describe)\.(?:skip|todo|failing)\b', r'^\s*(?:xit|xtest|xdescribe)\s*\(')],
    'go': [re.compile(r'^\s*t\.(?:Skip|Skipf|SkipNow)\s*\(')],
    'rust': [re.compile(r'^\s*#\[\s*ignore\b')],
    'java': [re.compile(r'^\s*@(?:Disabled|Ignore)\b')],
    'shell': [],
}

# Assertion forms, one per line.
ASSERTIONS = {
    'python': [re.compile(p) for p in (
        r'^\s*assert\b', r'\bself\.assert\w*\s*\(', r'\bpytest\.raises\b', r'\bself\.fail\s*\(')],
    'js': [re.compile(p) for p in (
        r'\bexpect\s*\(', r'\bassert(?:\.\w+)?\s*\(', r'\bt\.(?:is|true|false|deepEqual|throws)\w*\s*\(')],
    'go': [re.compile(p) for p in (
        r'\bt\.(?:Error|Errorf|Fatal|Fatalf|Fail|FailNow)\s*\(', r'\b(?:assert|require)\.\w+\s*\(')],
    'rust': [re.compile(r'\bassert(?:_eq|_ne|_matches)?!\s*\(|\bdebug_assert\w*!\s*\(')],
    'java': [re.compile(p) for p in (
        r'\bassert\w*\s*\(', r'\bassertThat\s*\(', r'\bfail\s*\(', r'\bexpect\s*\(')],
    'shell': [re.compile(r'^\s*(?:if\s+!?\s*)?(?:check|assert\w*)\s')],
}


class Finding(collections.namedtuple('Finding', 'kind path detail')):
    """One uncleared or cleared flag: `kind`, the file, and the test or line."""
    __slots__ = ()

    def __str__(self):
        label = {DELETED_TEST: 'deleted test', DELETED_FILE: 'deleted test file',
                 NEW_SKIP: 'new skip', FEWER_ASSERTIONS: 'fewer assertions'}[self.kind]
        return '%s: %s%s' % (label, self.path, ': ' + self.detail if self.detail else '')


class Result:
    """What the range does to its tests; `findings` is the flagged part."""

    def __init__(self):
        self.tests_added = []        # [(path, name)]
        self.tests_deleted = []      # [(path, name)], names not added anywhere in the range
        self.skips_added = []        # [(path, line)]
        self.assertion_deltas = {}   # path -> added minus removed, moves netted out
        self.deleted_files = []      # test files deleted outright, moves netted out
        self.findings = []

    def as_dict(self):
        return {'tests_added': self.tests_added, 'tests_deleted': self.tests_deleted,
                'skips_added': self.skips_added, 'assertion_deltas': self.assertion_deltas,
                'deleted_files': self.deleted_files, 'findings': [tuple(f) for f in self.findings]}


class _File:
    def __init__(self, old, new):
        self.old, self.new = old, new
        self.old_lines = []   # [(text, changed)] context and removed lines
        self.new_lines = []   # [(text, changed)] context and added lines

    @property
    def path(self):
        return self.new or self.old

    @property
    def deleted(self):
        return self.new is None

    @property
    def created(self):
        return self.old is None


def _strip_prefix(token):
    token = token.split('\t', 1)[0].strip()
    if token == '/dev/null':
        return None
    if token.startswith('"') and token.endswith('"'):
        token = token[1:-1]
    return token[2:] if token[:2] in ('a/', 'b/') else token


def parse_diff(text):
    """The files of a unified diff, each with its old-side and new-side lines.

    Handles git's extended headers (renames, deletions, creations); a pure
    rename carries no hunks and so no lines.
    """
    files, cur, in_hunk = [], None, False
    for raw in text.splitlines():
        if raw.startswith('diff --git '):
            m = re.match(r'diff --git "?a/(.*?)"? "?b/(.*?)"?$', raw)
            cur = _File(m.group(1) if m else None, m.group(2) if m else None)
            files.append(cur)
            in_hunk = False
        elif cur is not None and not in_hunk and raw.startswith('rename from '):
            cur.old = raw[len('rename from '):]
        elif cur is not None and not in_hunk and raw.startswith('rename to '):
            cur.new = raw[len('rename to '):]
        elif cur is not None and not in_hunk and raw.startswith('deleted file mode'):
            cur.new = None
        elif cur is not None and not in_hunk and raw.startswith('new file mode'):
            cur.old = None
        elif raw.startswith('--- ') and not in_hunk:
            if cur is None or cur.old_lines or cur.new_lines:
                cur = _File(None, None)    # a plain `diff -u` without git headers
                files.append(cur)
            cur.old = _strip_prefix(raw[4:])
        elif raw.startswith('+++ ') and not in_hunk:
            cur.new = _strip_prefix(raw[4:])
        elif raw.startswith('@@'):
            in_hunk = True
        elif in_hunk and cur is not None:
            if raw.startswith('+'):
                cur.new_lines.append((raw[1:], True))
            elif raw.startswith('-'):
                cur.old_lines.append((raw[1:], True))
            elif raw.startswith(' ') or raw == '':
                cur.old_lines.append((raw[1:], False))
                cur.new_lines.append((raw[1:], False))
            elif raw.startswith('\\'):
                pass
            else:
                in_hunk = False
    return files


def language(path):
    return LANG_BY_EXT.get(os.path.splitext(path or '')[1].lower())


def is_test_source(path):
    """A test file by `TEST_PATH_RE`, leaving fixture and test-data directories out."""
    return bool(path) and bool(TEST_PATH_RE.search(path)) and not DATA_DIR_RE.search(path)


def _is_comment(line):
    s = line.strip()
    if s.startswith('#'):
        return not s.startswith('#[')
    return s.startswith('//') or s.startswith('*') or s.startswith('/*')


def _norm(line):
    return ' '.join(line.split())


def _names(lang, lines):
    """Test names defined on changed lines, with the attribute rule of the language."""
    spec = DEFINITIONS.get(lang)
    if not spec:
        return []
    attrs = spec.get('attrs')
    found, pending = [], None    # pending: None, or whether the test attribute changed
    for text, changed in lines:
        if _is_comment(text):
            continue
        if attrs:
            if any(a.search(text) for a in attrs):
                pending = changed or bool(pending)
            elif pending is None:
                continue
            elif not text.strip() or text.strip().startswith(('#', '@')):
                continue      # blank lines and further attributes keep the mark
        for pattern in spec['names']:
            m = pattern.search(text)
            if m:
                name = next((g for g in m.groups() if g is not None), None)
                if name and (changed or pending):
                    found.append(name)
                pending = None
                break
        else:
            if attrs and not any(a.search(text) for a in attrs):
                pending = None
    return found


def _matching(lang, table, lines, changed_only=True):
    patterns = table.get(lang) or []
    return [_norm(t) for t, changed in lines
            if (changed or not changed_only) and not _is_comment(t) and any(p.search(t) for p in patterns)]


def analyse(diff_text):
    """Tests added and deleted, skips added and assertion deltas over a whole diff."""
    result = Result()
    files = [f for f in parse_diff(diff_text) if is_test_source(f.path) or is_test_source(f.old)]

    names_added, names_removed = {}, {}
    created_bases = {os.path.basename(f.path) for f in files if f.created}
    added_assertions, removed_assertions = collections.Counter(), collections.Counter()
    added_skips, removed_skips = collections.Counter(), collections.Counter()
    per_file = []
    for f in files:
        lang = language(f.path)
        added = _names(lang, f.new_lines) if not f.deleted else []
        removed = _names(lang, f.old_lines) if not f.created else []
        a_lines = _matching(lang, ASSERTIONS, f.new_lines) if not f.deleted else []
        r_lines = _matching(lang, ASSERTIONS, f.old_lines) if not f.created else []
        a_skips = _matching(lang, SKIPS, f.new_lines) if not f.deleted else []
        r_skips = _matching(lang, SKIPS, f.old_lines) if not f.created else []
        for n in added:
            names_added.setdefault(n, f.path)
            result.tests_added.append((f.path, n))
        for n in removed:
            names_removed.setdefault(n, []).append(f.path)
        added_assertions.update(a_lines)
        removed_assertions.update(r_lines)
        added_skips.update(a_skips)
        removed_skips.update(r_skips)
        per_file.append((f, lang, removed, a_lines, r_lines, a_skips))

    # A name removed and added anywhere in the range is a move; the rest is gone.
    gone = {n for n in names_removed if n not in names_added}
    for name in sorted(gone):
        for path in names_removed[name]:
            result.tests_deleted.append((path, name))
            result.findings.append(Finding(DELETED_TEST, path, name))

    moved = {line: min(added_assertions[line], removed_assertions[line])
             for line in set(added_assertions) & set(removed_assertions)}
    budget_a, budget_r = collections.Counter(moved), collections.Counter(moved)
    for f, lang, removed, a_lines, r_lines, a_skips in per_file:
        # An added skip line that the range also removes elsewhere is a move.
        for line in a_skips:
            if removed_skips[line] > 0:
                removed_skips[line] -= 1
                continue
            result.skips_added.append((f.path, line))
            result.findings.append(Finding(NEW_SKIP, f.path, line))

        # Assertion lines present on both sides of the range net out pairwise.
        a_net, r_net = collections.Counter(a_lines), collections.Counter(r_lines)
        for line in set(a_net) | set(r_net):
            take_a = min(a_net[line], budget_a[line])
            take_r = min(r_net[line], budget_r[line])
            a_net[line] -= take_a
            r_net[line] -= take_r
            budget_a[line] -= take_a
            budget_r[line] -= take_r
        delta = sum(a_net.values()) - sum(r_net.values())

        if f.deleted:
            unmatched = sum(r_net.values()) > 0
            # A file of no known language cannot be counted: a same-named file added is its move.
            if not removed and (unmatched or (lang is None and os.path.basename(f.path) not in created_bases)):
                result.deleted_files.append(f.path)
                result.findings.append(Finding(DELETED_FILE, f.path, ''))
            continue
        if f.created:
            continue
        result.assertion_deltas[f.path] = delta
        if delta < 0:
            result.findings.append(
                Finding(FEWER_ASSERTIONS, f.path, '%d fewer assertion%s' % (-delta, '' if delta == -1 else 's')))
    return result


def render(result, justifications=()):
    """The report text: each finding, marked justified when a reason clears it."""
    cleared = [r for r in justifications if r and r.strip()]
    lines = []
    for finding in result.findings:
        lines.append('%s%s' % ('justified: ' if cleared else 'FLAGGED: ', finding))
    if cleared:
        lines.extend('  Test-Integrity: %s' % r.strip() for r in cleared)
    return lines


def uncleared(result, justifications=()):
    """The findings still standing: none when any commit carries a reason."""
    if any(r and r.strip() for r in justifications):
        return []
    return list(result.findings)


def main(argv=None, stdin=None, out=None):
    """`testing_diff.py [--enforce] [--justified REASON]...`: a unified diff on stdin."""
    argv = list(sys.argv[1:] if argv is None else argv)
    out = out or sys.stdout
    enforce, reasons = False, []
    while argv:
        arg = argv.pop(0)
        if arg == '--enforce':
            enforce = True
        elif arg == '--justified':
            reasons.append(argv.pop(0) if argv else '')
        else:
            print('usage: testing_diff.py [--enforce] [--justified REASON]... < diff', file=sys.stderr)
            return 2
    result = analyse((stdin or sys.stdin).read())
    report = render(result, reasons)
    if not report:
        print('test integrity: no weakened tests in the range', file=out)
        return 0
    for line in report:
        print(line, file=out)
    left = uncleared(result, reasons)
    if left and enforce:
        print('test integrity: %d uncleared finding%s; add a `Test-Integrity: <reason>` trailer to a '
              'commit in the range, or restore the tests' % (len(left), '' if len(left) == 1 else 's'),
              file=out)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
