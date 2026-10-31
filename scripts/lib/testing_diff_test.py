"""The integrity analyser on sample diffs in Python, TypeScript, Go, Rust and shell."""
import difflib
import io
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import testing_diff as td


def file_diff(path, old, new, new_path=None):
    """A git-style unified diff of one file; `old` or `new` None means created or deleted."""
    new_path = new_path or path
    old_lines = (old or '').splitlines(keepends=True)
    new_lines = (new or '').splitlines(keepends=True)
    head = ['diff --git a/%s b/%s\n' % (path, new_path)]
    if old is None:
        head.append('new file mode 100644\n')
    if new is None:
        head.append('deleted file mode 100644\n')
    if old is not None and new is not None and path != new_path:
        head += ['rename from %s\n' % path, 'rename to %s\n' % new_path]
    body = difflib.unified_diff(old_lines, new_lines, 'a/' + path if old is not None else '/dev/null',
                                'b/' + new_path if new is not None else '/dev/null', n=3)
    return ''.join(head) + ''.join(l if l.endswith('\n') else l + '\n' for l in body)


def kinds(result):
    return sorted((f.kind, f.path, f.detail) for f in result.findings)


PY_OLD = '''import unittest


class T(unittest.TestCase):
    def test_keeps(self):
        self.assertEqual(1, 1)
        self.assertTrue(True)

    def test_goes(self):
        self.assertEqual(2, 2)
'''
TS_OLD = '''describe('sum', () => {
  it('adds', () => {
    expect(1 + 1).toBe(2);
    expect(2 + 2).toBe(4);
  });
  it('subtracts', () => {
    expect(2 - 1).toBe(1);
  });
});
'''
GO_OLD = '''package sum

import "testing"

func TestAdd(t *testing.T) {
	if Add(1, 1) != 2 {
		t.Errorf("bad add")
	}
}

func TestSub(t *testing.T) {
	if Sub(2, 1) != 1 {
		t.Errorf("bad sub")
	}
}
'''
RS_OLD = '''#[cfg(test)]
mod tests {
    #[test]
    fn adds() {
        assert_eq!(1 + 1, 2);
    }

    #[test]
    fn subtracts() {
        assert_eq!(2 - 1, 1);
        assert!(true);
    }
}
'''
SH_OLD = '''#!/usr/bin/env bash
check "adds" test 2 -eq 2
check "subtracts" test 1 -eq 1
assert_ok "runs" true
'''


class DeletedTests(unittest.TestCase):
    def test_python_deleted_test_is_named(self):
        new = PY_OLD.replace('''
    def test_goes(self):
        self.assertEqual(2, 2)
''', '')
        r = td.analyse(file_diff('scripts/lib/x_test.py', PY_OLD, new))
        self.assertEqual(r.tests_deleted, [('scripts/lib/x_test.py', 'test_goes')])
        self.assertIn((td.DELETED_TEST, 'scripts/lib/x_test.py', 'test_goes'), kinds(r))

    def test_typescript_deleted_test(self):
        new = TS_OLD.replace('''  it('subtracts', () => {
    expect(2 - 1).toBe(1);
  });
''', '')
        r = td.analyse(file_diff('src/sum.test.ts', TS_OLD, new))
        self.assertEqual(r.tests_deleted, [('src/sum.test.ts', 'subtracts')])

    def test_go_deleted_test(self):
        new = GO_OLD.split('func TestSub')[0].rstrip('\n') + '\n'
        r = td.analyse(file_diff('sum/sum_test.go', GO_OLD, new))
        self.assertEqual(r.tests_deleted, [('sum/sum_test.go', 'TestSub')])

    def test_rust_deleted_test_after_attribute(self):
        new = RS_OLD.replace('''
    #[test]
    fn subtracts() {
        assert_eq!(2 - 1, 1);
        assert!(true);
    }
''', '')
        r = td.analyse(file_diff('tests/lib.rs', RS_OLD, new))
        self.assertEqual(r.tests_deleted, [('tests/lib.rs', 'subtracts')])

    def test_rust_attribute_dropped_is_a_deletion(self):
        new = RS_OLD.replace('    #[test]\n    fn adds', '    fn adds')
        r = td.analyse(file_diff('tests/adds.rs', RS_OLD, new))
        self.assertEqual(r.tests_deleted, [('tests/adds.rs', 'adds')])

    def test_deleted_shell_test_file(self):
        r = td.analyse(file_diff('scripts/x.test.sh', SH_OLD, None))
        self.assertEqual(r.deleted_files, ['scripts/x.test.sh'])
        self.assertEqual(kinds(r), [(td.DELETED_FILE, 'scripts/x.test.sh', '')])

    def test_deleted_python_file_names_each_test(self):
        r = td.analyse(file_diff('scripts/lib/x_test.py', PY_OLD, None))
        self.assertEqual(sorted(n for _, n in r.tests_deleted), ['test_goes', 'test_keeps'])

    def test_deleting_a_fixture_is_no_finding(self):
        r = td.analyse(file_diff('tests/fixtures/data.json', '{"a": 1}\n', None))
        self.assertEqual(r.findings, [])

    def test_helper_without_tests_or_assertions_is_no_finding(self):
        r = td.analyse(file_diff('tests/helpers.py', 'def make():\n    return 1\n', None))
        self.assertEqual(r.findings, [])

    def test_production_files_are_ignored(self):
        r = td.analyse(file_diff('src/sum.py', 'def test_like():\n    assert 1\n', None))
        self.assertEqual(r.findings, [])


class RenameIsNotDeletion(unittest.TestCase):
    def test_test_moved_to_another_file(self):
        diff = file_diff('scripts/lib/a_test.py', PY_OLD, None) + file_diff('scripts/lib/b_test.py', None, PY_OLD)
        r = td.analyse(diff)
        self.assertEqual(r.findings, [])
        self.assertEqual(r.tests_deleted, [])
        self.assertEqual(len(r.tests_added), 2)

    def test_git_rename_with_edits(self):
        new = PY_OLD.replace('assertTrue(True)', 'assertTrue(True)\n        self.assertFalse(False)')
        r = td.analyse(file_diff('scripts/lib/a_test.py', PY_OLD, new, new_path='scripts/lib/b_test.py'))
        self.assertEqual(r.findings, [])

    def test_pure_rename_has_no_hunks(self):
        diff = ('diff --git a/a_test.py b/b_test.py\nsimilarity index 100%\n'
                'rename from a_test.py\nrename to b_test.py\n')
        self.assertEqual(td.analyse(diff).findings, [])

    def test_shell_file_moved_nets_out(self):
        diff = file_diff('scripts/a.test.sh', SH_OLD, None) + file_diff('scripts/b.test.sh', None, SH_OLD)
        self.assertEqual(td.analyse(diff).findings, [])

    def test_shell_file_moved_with_a_dropped_check_is_flagged(self):
        dropped = SH_OLD.replace('check "subtracts" test 1 -eq 1\n', '')
        diff = file_diff('scripts/a.test.sh', SH_OLD, None) + file_diff('scripts/b.test.sh', None, dropped)
        self.assertEqual([k for k, _, _ in kinds(td.analyse(diff))], [td.DELETED_FILE])

    def test_a_test_added_and_removed_in_one_range_shows_nothing(self):
        # The range diff already folds the pair away: nothing to analyse.
        self.assertEqual(td.analyse('').findings, [])


class UnknownLanguage(unittest.TestCase):
    RB = 'it "adds" do\n  expect(1).to eq(1)\nend\n'

    def test_deleted_file_of_unknown_language_is_flagged(self):
        r = td.analyse(file_diff('spec/add.test.rb', self.RB, None))
        self.assertEqual(r.deleted_files, ['spec/add.test.rb'])

    def test_moved_file_of_unknown_language_is_not(self):
        diff = file_diff('spec/add.test.rb', self.RB, None) + file_diff('spec/sub/add.test.rb', None, self.RB)
        self.assertEqual(td.analyse(diff).findings, [])


class NewSkips(unittest.TestCase):
    def skipped(self, path, old, new):
        return [(k, d) for k, p, d in kinds(td.analyse(file_diff(path, old, new))) if k == td.NEW_SKIP]

    def test_pytest_skip_and_xfail(self):
        new = PY_OLD.replace('    def test_goes', '    @pytest.mark.skip(reason="later")\n    def test_goes')
        self.assertEqual(self.skipped('x_test.py', PY_OLD, new), [(td.NEW_SKIP, '@pytest.mark.skip(reason="later")')])
        new = PY_OLD.replace('    def test_goes', '    @pytest.mark.xfail\n    def test_goes')
        self.assertEqual(len(self.skipped('x_test.py', PY_OLD, new)), 1)

    def test_unittest_skip(self):
        new = PY_OLD.replace('    def test_goes', '    @unittest.skip("no")\n    def test_goes')
        self.assertEqual(len(self.skipped('x_test.py', PY_OLD, new)), 1)
        new = PY_OLD.replace('        self.assertEqual(2, 2)', '        self.skipTest("no")\n        self.assertEqual(2, 2)')
        self.assertEqual(len(self.skipped('x_test.py', PY_OLD, new)), 1)

    def test_jest_skip_keeps_the_test_defined(self):
        new = TS_OLD.replace("it('subtracts'", "it.skip('subtracts'")
        r = td.analyse(file_diff('src/sum.test.ts', TS_OLD, new))
        self.assertEqual([k for k, _, _ in kinds(r)], [td.NEW_SKIP])
        self.assertEqual(r.tests_deleted, [])
        new = TS_OLD.replace("it('adds'", "xit('adds'")
        self.assertEqual(len(self.skipped('src/sum.test.ts', TS_OLD, new)), 1)

    def test_go_skip(self):
        new = GO_OLD.replace('\tif Sub', '\tt.Skip("flaky")\n\tif Sub')
        self.assertEqual(len(self.skipped('sum/sum_test.go', GO_OLD, new)), 1)

    def test_rust_ignore(self):
        new = RS_OLD.replace('    #[test]\n    fn subtracts', '    #[test]\n    #[ignore]\n    fn subtracts')
        r = td.analyse(file_diff('tests/lib.rs', RS_OLD, new))
        self.assertEqual([k for k, _, _ in kinds(r)], [td.NEW_SKIP])
        self.assertEqual(r.tests_deleted, [])

    def test_junit_disabled(self):
        old = '    @Test\n    void adds() {\n        assertEquals(2, 2);\n    }\n'
        new = '    @Test\n    @Disabled\n    void adds() {\n        assertEquals(2, 2);\n    }\n'
        self.assertEqual(len(self.skipped('src/AddTest.java', old, new)), 0)  # not a test path
        self.assertEqual(len(self.skipped('tests/AddTest.java', old, new)), 1)

    def test_a_skip_in_a_comment_does_not_count(self):
        new = PY_OLD + '# pytest.skip("later")\n'
        self.assertEqual(self.skipped('x_test.py', PY_OLD, new), [])

    def test_a_skip_that_moves_is_not_new(self):
        skipped = PY_OLD.replace('    def test_goes', '    @pytest.mark.skip\n    def test_goes')
        diff = file_diff('a_test.py', skipped, None) + file_diff('b_test.py', None, skipped)
        self.assertEqual(td.analyse(diff).findings, [])

    def test_removing_a_skip_is_fine(self):
        skipped = PY_OLD.replace('    def test_goes', '    @pytest.mark.skip\n    def test_goes')
        self.assertEqual(td.analyse(file_diff('x_test.py', skipped, PY_OLD)).findings, [])


class RemovedAssertions(unittest.TestCase):
    def fewer(self, path, old, new):
        r = td.analyse(file_diff(path, old, new))
        return [f for f in r.findings if f.kind == td.FEWER_ASSERTIONS], r

    def test_python_falling_count(self):
        found, r = self.fewer('x_test.py', PY_OLD, PY_OLD.replace('        self.assertTrue(True)\n', ''))
        self.assertEqual(len(found), 1)
        self.assertEqual(r.assertion_deltas, {'x_test.py': -1})

    def test_typescript_falling_count(self):
        found, _ = self.fewer('src/sum.test.ts', TS_OLD, TS_OLD.replace('    expect(2 + 2).toBe(4);\n', ''))
        self.assertEqual(len(found), 1)

    def test_go_falling_count(self):
        found, _ = self.fewer('sum/sum_test.go', GO_OLD, GO_OLD.replace('\t\tt.Errorf("bad add")\n', '\t\treturn\n'))
        self.assertEqual(len(found), 1)

    def test_rust_falling_count(self):
        found, _ = self.fewer('tests/lib.rs', RS_OLD, RS_OLD.replace('        assert!(true);\n', ''))
        self.assertEqual(len(found), 1)

    def test_shell_falling_count(self):
        found, _ = self.fewer('scripts/x.test.sh', SH_OLD, SH_OLD.replace('assert_ok "runs" true\n', ''))
        self.assertEqual(len(found), 1)

    def test_replacing_an_assertion_keeps_the_count(self):
        new = PY_OLD.replace('assertTrue(True)', 'assertIsNone(None)')
        found, r = self.fewer('x_test.py', PY_OLD, new)
        self.assertEqual(found, [])
        self.assertEqual(r.assertion_deltas, {'x_test.py': 0})

    def test_reformatting_an_assertion_keeps_the_count(self):
        new = PY_OLD.replace('self.assertEqual(1, 1)', 'self.assertEqual(\n            1, 1)')
        found, _ = self.fewer('x_test.py', PY_OLD, new)
        self.assertEqual(found, [])

    def test_adding_assertions_is_fine(self):
        found, r = self.fewer('x_test.py', PY_OLD, PY_OLD + '        self.assertTrue(True)\n')
        self.assertEqual(found, [])
        self.assertEqual(r.assertion_deltas['x_test.py'], 1)

    def test_a_new_test_file_has_no_delta(self):
        r = td.analyse(file_diff('x_test.py', None, PY_OLD))
        self.assertEqual(r.findings, [])
        self.assertEqual(r.assertion_deltas, {})


class Rendering(unittest.TestCase):
    DIFF = file_diff('scripts/x.test.sh', SH_OLD, None)

    def run_main(self, *args):
        out = io.StringIO()
        code = td.main(list(args), stdin=io.StringIO(self.DIFF), out=out)
        return code, out.getvalue()

    def test_report_names_file(self):
        code, text = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn('FLAGGED: deleted test file: scripts/x.test.sh', text)

    def test_enforce_fails_on_a_finding(self):
        code, text = self.run_main('--enforce')
        self.assertEqual(code, 1)
        self.assertIn('Test-Integrity:', text)

    def test_a_reason_clears_the_finding(self):
        code, text = self.run_main('--enforce', '--justified', 'the behaviour was removed')
        self.assertEqual(code, 0)
        self.assertIn('justified: deleted test file: scripts/x.test.sh', text)
        self.assertIn('the behaviour was removed', text)

    def test_a_blank_reason_clears_nothing(self):
        self.assertEqual(self.run_main('--enforce', '--justified', '  ')[0], 1)

    def test_a_clean_range_says_so(self):
        out = io.StringIO()
        self.assertEqual(td.main(['--enforce'], stdin=io.StringIO(''), out=out), 0)
        self.assertIn('no weakened tests', out.getvalue())


if __name__ == '__main__':
    unittest.main()
