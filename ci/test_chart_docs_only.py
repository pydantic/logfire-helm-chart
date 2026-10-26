import unittest

from chart_docs_only import docs_only


VALUES = 'charts/logfire/values.yaml'


class DocsOnlyChartChanges(unittest.TestCase):
    def test_readme_changes(self):
        self.assertTrue(docs_only([('M', 'charts/logfire/README.md'), ('M', 'charts/logfire/README.md.gotmpl')]))
        self.assertTrue(docs_only([('M', 'charts/logfire/README.md'), ('M', '.github/workflows/pr.yaml')]))

    def test_values_comments_and_whitespace(self):
        before = 'enabled: true\ncount: 1\n'
        for after in ('# Explain the setting.\nenabled: true\ncount: 1\n',
                      'enabled: true # Inline explanation.\n\ncount: 1\n'):
            with self.subTest(after=after):
                self.assertTrue(docs_only([('M', VALUES)], before, after))

    def test_runtime_values_retain_version_check(self):
        cases = [('enabled: true\n', 'enabled: false\n'),
                 ('value: false\n', 'value: 0\n'),
                 ('value: 1\n', 'value: 1.0\n'),
                 ('value: 1\n', 'value: "1"\n'),
                 ('value: yes\n', 'value: true\n'),
                 ('value: a\n', 'value: "a"\n'),
                 ('config: |\n  # first payload\n', 'config: |\n  # second payload\n'),
                 ('value: &first a\ncopy: *first\n', 'value: &second a\ncopy: *second\n'),
                 ('%YAML 1.1\n---\nvalue: a\n', '%YAML 1.2\n---\nvalue: a\n')]
        for before, after in cases:
            with self.subTest(before=before, after=after):
                self.assertFalse(docs_only([('M', VALUES)], before, after))

    def test_other_chart_changes_retain_version_check(self):
        for status, path in [('M', 'charts/logfire/Chart.yaml'),
                             ('M', 'charts/logfire/templates/deployment.yaml'),
                             ('M', 'charts/logfire/values.prod.yaml'),
                             ('M', 'charts/another/README.md'),
                             ('A', 'charts/logfire/README.md'),
                             ('D', 'charts/logfire/README.md'),
                             ('T', VALUES)]:
            with self.subTest(status=status, path=path):
                self.assertFalse(docs_only([('M', 'charts/logfire/README.md'), (status, path)]))

    def test_missing_or_invalid_values_retain_version_check(self):
        for content in ('key: [broken', 'key: !unsupported payload', 'key: one\n---\nkey: two\n'):
            with self.subTest(content=content):
                self.assertFalse(docs_only([('M', VALUES)], content, content))
        self.assertFalse(docs_only([]))
        self.assertFalse(docs_only([('M', 'README.md')]))


if __name__ == '__main__':
    unittest.main()
