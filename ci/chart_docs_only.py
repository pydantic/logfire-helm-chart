import json
import subprocess
import sys

import yaml


VALUES = {'charts/logfire/values.yaml', 'charts/logfire/values.prod.yaml', 'charts/logfire/values.dev.yaml'}
DOCS = {'charts/logfire/README.md', 'charts/logfire/README.md.gotmpl'}


def values_tokens(content):
    yaml.safe_load(content)
    return json.dumps([
        (type(token).__name__, {key: value for key, value in vars(token).items()
                               if key not in ('start_mark', 'end_mark')})
        for token in yaml.scan(content)
    ], sort_keys=True)


def docs_only(changes, values=None):
    values = values or {}
    chart_changes = [(status, path) for status, path in changes if path.startswith('charts/')]
    if not chart_changes or any(status != 'M' or path not in DOCS | VALUES
                                for status, path in chart_changes):
        return False
    try:
        return all(values_tokens(values[path][0]) == values_tokens(values[path][1])
                   for _, path in chart_changes if path in VALUES)
    except (KeyError, yaml.YAMLError, TypeError, ValueError):
        return False


def main():
    def git(*args):
        return subprocess.check_output(['git', *args], text=True)

    try:
        base = git('merge-base', sys.argv[1], 'HEAD').strip()
        fields = git('diff', '--name-status', '--no-renames', '-z', base, 'HEAD', '--', 'charts').split('\0')
        changes = list(zip(fields[:-1:2], fields[1:-1:2], strict=True))
        values = {path: (git('show', f'{base}:{path}'), git('show', f'HEAD:{path}'))
                  for status, path in changes if status == 'M' and path in VALUES}
        exempt = docs_only(changes, values)
    except (IndexError, OSError, subprocess.CalledProcessError, ValueError):
        exempt = False
    print('Documentation-only chart changes.' if exempt else 'Keep the chart version increment check.')
    return 0 if exempt else 1


if __name__ == '__main__':
    sys.exit(main())
