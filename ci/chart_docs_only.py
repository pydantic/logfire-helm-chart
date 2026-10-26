import json
import subprocess
import sys

import yaml


VALUES = 'charts/logfire/values.yaml'
DOCS = {'charts/logfire/README.md', 'charts/logfire/README.md.gotmpl'}


def values_tokens(content):
    yaml.safe_load(content)
    return json.dumps([
        (type(token).__name__, {key: value for key, value in vars(token).items()
                               if key not in ('start_mark', 'end_mark')})
        for token in yaml.scan(content)
    ], sort_keys=True)


def docs_only(changes, before_values='', after_values=''):
    chart_changes = [(status, path) for status, path in changes if path.startswith('charts/')]
    if not chart_changes or any(status != 'M' or path not in DOCS | {VALUES}
                                for status, path in chart_changes):
        return False
    if not any(path == VALUES for _, path in chart_changes):
        return True
    try:
        return values_tokens(before_values) == values_tokens(after_values)
    except (yaml.YAMLError, TypeError, ValueError):
        return False


def main():
    def git(*args):
        return subprocess.check_output(['git', *args], text=True)

    try:
        base = git('merge-base', sys.argv[1], 'HEAD').strip()
        fields = git('diff', '--name-status', '--no-renames', '-z', base, 'HEAD', '--', 'charts').split('\0')
        changes = list(zip(fields[:-1:2], fields[1:-1:2], strict=True))
        values_changed = ('M', VALUES) in changes
        before = git('show', f'{base}:{VALUES}') if values_changed else ''
        after = git('show', f'HEAD:{VALUES}') if values_changed else ''
        exempt = docs_only(changes, before, after)
    except (IndexError, OSError, subprocess.CalledProcessError, ValueError):
        exempt = False
    print('Documentation-only chart changes.' if exempt else 'Keep the chart version increment check.')
    return 0 if exempt else 1


if __name__ == '__main__':
    sys.exit(main())
