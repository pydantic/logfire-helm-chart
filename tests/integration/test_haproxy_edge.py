"""What the rendered HAProxy does with hostnames, origins and redirects, for chosen chart values.

These tests need no cluster. They run the chart's HAProxy in front of a stub upstream and send
requests with chosen `Host`, `X-Forwarded-Host`, `Origin` and `Location` headers.
"""

from __future__ import annotations

from collections.abc import Iterator

import httpx
import pytest
from helpers.haproxy import Proxy, running_proxy

APP = "app.example.com"
ORIGIN = f"https://{APP}"
INTAKE = "ingest.example.com"
OTHER = "other.example.com"
HOSTS = {"gateway": {"hostnames": [APP]}, "ingress": {"hostnames": [APP]}, "intake": {"hostnames": [INTAKE]}}
SERVICE = "logfire-backend.default.svc.cluster.local"


def status(proxy: Proxy, path: str, *headers: tuple[str, str]) -> int:
    return proxy.get(path, list(headers)).status_code


def preflight(proxy: Proxy, origin: str, host: str = APP) -> httpx.Response:
    headers = {"Host": host, "Origin": origin, "Access-Control-Request-Method": "GET"}
    return httpx.options(f"http://{proxy.address}/ui-api/platform-config/", headers=headers, timeout=10)


def proxy_for(values: dict) -> Iterator[Proxy]:
    with running_proxy({**HOSTS, **values}) as proxy:
        yield proxy


@pytest.fixture(scope="module")
def default() -> Iterator[Proxy]:
    yield from proxy_for({})


@pytest.fixture(scope="module")
def enforce() -> Iterator[Proxy]:
    yield from proxy_for({"hostValidation": {"mode": "enforce"}})


@pytest.fixture(scope="module")
def report() -> Iterator[Proxy]:
    yield from proxy_for({"hostValidation": {"mode": "report"}})


def test_enforce_refuses_the_ui_on_an_unlisted_host_and_leaves_other_backends_open(enforce: Proxy) -> None:
    for path in ("/", "/ui-api/platform-config/", "/auth-api/callback"):
        assert status(enforce, path, ("Host", APP.upper())) == 200, path
        for host in (OTHER, f"{APP}.evil.example", f"{APP}:8443", INTAKE):
            assert status(enforce, path, ("Host", host)) == 421, (path, host)
    for path in ("/v1/traces", "/v2/query", "/mcp", "/proxy"):
        assert status(enforce, path, ("Host", OTHER)) == 200, path


def test_health_checks_and_internal_callers_stay_open(enforce: Proxy) -> None:
    assert status(enforce, "/health", ("Host", OTHER)) == 200
    assert status(enforce, "/", ("Host", "10.1.2.3:8080")) == 200
    assert enforce.raw_status("/", host=None) == 200, "a probe with no Host header"


@pytest.mark.parametrize(
    "path",
    ["/.well-known/%2e%2e/config.1.js", "/v1/x%00/../ui-api/platform-config/", "/%75i-api/platform-config/"],
    ids=["dot-segment", "nul-before-dot-segment", "encoded-ui-api"],
)
def test_a_path_that_a_backend_prefix_or_encoding_hides_is_still_checked(enforce: Proxy, path: str) -> None:
    assert enforce.raw_status(path, OTHER) == 421
    assert enforce.raw_status(path, APP) == 200


def test_a_preflight_from_a_listed_origin_to_an_unlisted_host_is_refused(enforce: Proxy) -> None:
    assert preflight(enforce, ORIGIN, host=OTHER).status_code == 421
    assert preflight(enforce, ORIGIN).status_code == 204


def test_x_forwarded_host_is_checked_as_well_as_the_host(enforce: Proxy) -> None:
    assert status(enforce, "/", ("Host", OTHER), ("X-Forwarded-Host", APP)) == 421
    assert status(enforce, "/", ("Host", APP), ("X-Forwarded-Host", OTHER)) == 421
    assert status(enforce, "/", ("Host", APP), ("X-Forwarded-Host", f"{APP}, {OTHER}")) == 421


def test_more_x_forwarded_host_lines_than_the_limit_are_refused(enforce: Proxy) -> None:
    for lines, expected in ((8, 200), (9, 421)):
        assert status(enforce, "/", ("Host", APP), *[("X-Forwarded-Host", APP)] * lines) == expected, lines


def test_report_logs_what_enforce_would_reject_and_refuses_nothing(report: Proxy) -> None:
    assert status(report, "/", ("Host", OTHER), ("X-Forwarded-Host", "hop.example.com")) == 200
    assert status(report, "/", ("Host", APP)) == 200
    lines = [line for line in report.logs() if "host_check=would_reject" in line]
    assert len(lines) == 1 and 'host="other.example.com"' in lines[0], lines


def test_overwrite_sets_x_forwarded_host_from_the_host() -> None:
    with running_proxy({"haproxy": {"overwriteForwardedHost": True}}) as proxy:
        proxy.get("/", [("Host", APP), ("X-Forwarded-Host", "chosen-by-client.example")])
        assert proxy.upstream_headers()["x-forwarded-host"] == APP


def test_exact_cors_grants_a_listed_origin_with_credentials(default: Proxy) -> None:
    answer = preflight(default, ORIGIN)
    assert answer.status_code == 204, answer.headers
    assert answer.headers["access-control-allow-origin"] == ORIGIN
    assert answer.headers["access-control-allow-credentials"] == "true"
    assert answer.headers["access-control-allow-methods"] == "GET,HEAD,POST,PUT,PATCH,DELETE"
    assert "If-None-Match" in answer.headers["access-control-allow-headers"]
    assert default.get("/ui-api/platform-config/", [("Host", APP), ("Origin", ORIGIN)]).headers["vary"] == "Origin"


@pytest.mark.parametrize("origin", [f"{ORIGIN}.evil.example", f"{ORIGIN}:8443", f"https://{INTAKE}"])
def test_exact_cors_grants_no_look_alike_origin_and_no_ingest_only_host(default: Proxy, origin: str) -> None:
    assert "access-control-allow-origin" not in preflight(default, origin).headers
    assert "access-control-allow-origin" not in default.get("/ui-api/platform-config/", [("Host", APP), ("Origin", origin)]).headers


def test_prefix_keeps_the_old_match_without_a_credentialed_grant() -> None:
    with running_proxy({**HOSTS, "haproxy": {"corsOriginMatch": "prefix"}}) as proxy:
        answer = preflight(proxy, f"{ORIGIN}.evil.example")
        assert answer.headers["access-control-allow-origin"] == f"{ORIGIN}.evil.example"
        assert "access-control-allow-credentials" not in answer.headers


@pytest.mark.parametrize(
    ("upstream", "expected"),
    [
        (f"http://{SERVICE}/ui-api/x/", "/ui-api/x/"),
        (f"HTTP://{SERVICE}/ui-api/x/", "/ui-api/x/"),
        (f"https://idp.example.org/auth?next=x,http://{SERVICE}/p", f"https://idp.example.org/auth?next=x,http://{SERVICE}/p"),
    ],
    ids=["in-cluster", "upper-case-scheme", "comma-in-the-query-of-another-host"],
)
def test_a_redirect_to_an_in_cluster_service_keeps_only_its_path(default: Proxy, upstream: str, expected: str) -> None:
    response = default.get("/", [("Host", APP), ("X-Stub-Location", upstream)])
    assert response.status_code == 307
    assert response.headers["location"] == expected
