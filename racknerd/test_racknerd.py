#!/usr/bin/env python3
"""Tests for racknerd.py. Stdlib only: python3 -m unittest discover racknerd"""

import io
import json
import os
import sys
import unittest
import urllib.error
import urllib.parse
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import racknerd  # noqa: E402

GOOD_ENV = {
    "RACKNERD_API_URL": "https://panel.example.com/api/client/command.php",
    "RACKNERD_API_KEY": "test-key",
    "RACKNERD_API_HASH": "test-hash",
}


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def fake_api(body, captured=None):
    """Patch urlopen with a server that records the request it received."""

    def _urlopen(request, timeout=None):
        if captured is not None:
            captured["url"] = request.full_url
            captured["method"] = request.method
            captured["body"] = dict(urllib.parse.parse_qsl(request.data.decode()))
            captured["timeout"] = timeout
        return FakeResponse(body.encode())

    return mock.patch.object(racknerd.urllib.request, "urlopen", _urlopen)


class TestMask(unittest.TestCase):
    def test_long_secret_keeps_only_edges(self):
        masked = racknerd.mask("ABCDE-FGHIJ-KLMNO")
        self.assertEqual(masked, "ABCD*********LMNO")
        self.assertEqual(len(masked), len("ABCDE-FGHIJ-KLMNO"))

    def test_short_secret_fully_hidden(self):
        self.assertEqual(racknerd.mask("abcd"), "****")

    def test_empty(self):
        self.assertEqual(racknerd.mask(""), "(unset)")


class TestParseResponse(unittest.TestCase):
    def test_json(self):
        self.assertEqual(
            racknerd.parse_response('{"status":"success","vmstat":"online"}'),
            {"status": "success", "vmstat": "online"},
        )

    def test_solusvm_tags(self):
        parsed = racknerd.parse_response(
            "<status>success</status><statusmsg></statusmsg><vmstat>online</vmstat>"
        )
        self.assertEqual(parsed["status"], "success")
        self.assertEqual(parsed["vmstat"], "online")

    def test_key_value_lines(self):
        self.assertEqual(
            racknerd.parse_response("status=success\nipaddr=1.2.3.4"),
            {"status": "success", "ipaddr": "1.2.3.4"},
        )

    def test_empty_body_raises(self):
        with self.assertRaises(racknerd.ApiError):
            racknerd.parse_response("   ")

    def test_garbage_raises(self):
        with self.assertRaises(racknerd.ApiError):
            racknerd.parse_response("totally unparseable")


class TestConfig(unittest.TestCase):
    def test_missing_credentials_named_in_error(self):
        with mock.patch.dict(os.environ, {}, clear=True), \
             mock.patch.object(racknerd, "ENV_FILES", ()):
            with self.assertRaises(racknerd.ConfigError) as ctx:
                racknerd.get_config()
        message = str(ctx.exception)
        for name in GOOD_ENV:
            self.assertIn(name, message)

    def test_plain_http_rejected(self):
        env = dict(GOOD_ENV, RACKNERD_API_URL="http://panel.example.com/api")
        with mock.patch.dict(os.environ, env, clear=True), \
             mock.patch.object(racknerd, "ENV_FILES", ()):
            with self.assertRaises(racknerd.ConfigError):
                racknerd.get_config()

    def test_url_override_wins(self):
        with mock.patch.dict(os.environ, GOOD_ENV, clear=True), \
             mock.patch.object(racknerd, "ENV_FILES", ()):
            url, _, _ = racknerd.get_config("https://other.example.com/api")
        self.assertEqual(url, "https://other.example.com/api")


class TestCall(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, GOOD_ENV, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        files = mock.patch.object(racknerd, "ENV_FILES", ())
        files.start()
        self.addCleanup(files.stop)

    def test_credentials_go_in_post_body_not_url(self):
        captured = {}
        with fake_api('{"status":"success"}', captured):
            racknerd.call("status")
        self.assertEqual(captured["method"], "POST")
        self.assertNotIn("test-key", captured["url"])
        self.assertEqual(captured["body"]["key"], "test-key")
        self.assertEqual(captured["body"]["hash"], "test-hash")
        self.assertEqual(captured["body"]["action"], "status")
        self.assertEqual(captured["body"]["rdtype"], "json")

    def test_extra_params_are_sent(self):
        captured = {}
        with fake_api('{"status":"success"}', captured):
            racknerd.call("info", {"ipaddr": "true", "skipped": None})
        self.assertEqual(captured["body"]["ipaddr"], "true")
        self.assertNotIn("skipped", captured["body"])

    def test_api_error_status_raises(self):
        body = "<status>error</status><statusmsg>Invalid key</statusmsg>"
        with fake_api(body):
            with self.assertRaises(racknerd.ApiError) as ctx:
                racknerd.call("status")
        self.assertIn("Invalid key", str(ctx.exception))

    def test_http_error_is_wrapped(self):
        def _raise(request, timeout=None):
            raise urllib.error.HTTPError(
                request.full_url, 403, "Forbidden", {}, io.BytesIO(b"denied")
            )

        with mock.patch.object(racknerd.urllib.request, "urlopen", _raise):
            with self.assertRaises(racknerd.ApiError) as ctx:
                racknerd.call("status")
        self.assertIn("403", str(ctx.exception))

    def test_unreachable_host_is_wrapped(self):
        def _raise(request, timeout=None):
            raise urllib.error.URLError("name resolution failed")

        with mock.patch.object(racknerd.urllib.request, "urlopen", _raise):
            with self.assertRaises(racknerd.ApiError) as ctx:
                racknerd.call("status")
        self.assertIn("Could not reach", str(ctx.exception))


class TestCli(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, GOOD_ENV, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        files = mock.patch.object(racknerd, "ENV_FILES", ())
        files.start()
        self.addCleanup(files.stop)

    def run_cli(self, argv, body='{"status":"success","vmstat":"online"}', captured=None):
        out = io.StringIO()
        with fake_api(body, captured), mock.patch.object(sys, "stdout", out):
            code = racknerd.main(argv)
        return code, out.getvalue()

    def test_status(self):
        code, out = self.run_cli(["status"])
        self.assertEqual(code, racknerd.EXIT_OK)
        self.assertIn("online", out)

    def test_info_full_requests_all_sections(self):
        captured = {}
        code, _ = self.run_cli(["info", "--full"], captured=captured)
        self.assertEqual(code, racknerd.EXIT_OK)
        for field in ("ipaddr", "hdd", "mem", "bw"):
            self.assertEqual(captured["body"][field], "true")

    def test_json_output_is_valid_json(self):
        code, out = self.run_cli(["--json", "status"])
        self.assertEqual(code, racknerd.EXIT_OK)
        self.assertEqual(json.loads(out)["vmstat"], "online")

    def test_reboot_blocked_without_yes_when_non_interactive(self):
        with mock.patch.object(sys.stdin, "isatty", lambda: False), \
             mock.patch.object(sys, "stderr", io.StringIO()):
            code, _ = self.run_cli(["reboot"])
        self.assertEqual(code, racknerd.EXIT_API_ERROR)

    def test_reboot_runs_with_yes(self):
        captured = {}
        code, _ = self.run_cli(["--yes", "reboot"], captured=captured)
        self.assertEqual(code, racknerd.EXIT_OK)
        self.assertEqual(captured["body"]["action"], "reboot")

    def test_console_enable_sends_hours(self):
        captured = {}
        code, _ = self.run_cli(["console", "--hours", "3"], captured=captured)
        self.assertEqual(code, racknerd.EXIT_OK)
        self.assertEqual(captured["body"]["access"], "enable")
        self.assertEqual(captured["body"]["time"], "3")

    def test_console_disable_omits_hours(self):
        captured = {}
        code, _ = self.run_cli(["console", "--disable"], captured=captured)
        self.assertEqual(code, racknerd.EXIT_OK)
        self.assertEqual(captured["body"]["access"], "disable")
        self.assertNotIn("time", captured["body"])

    def test_raw_passes_through(self):
        captured = {}
        code, _ = self.run_cli(["raw", "vnc", "foo=bar"], captured=captured)
        self.assertEqual(code, racknerd.EXIT_OK)
        self.assertEqual(captured["body"]["action"], "vnc")
        self.assertEqual(captured["body"]["foo"], "bar")

    def test_test_command_masks_credentials(self):
        code, out = self.run_cli(["test"])
        self.assertEqual(code, racknerd.EXIT_OK)
        self.assertNotIn("test-key", out)
        self.assertNotIn("test-hash", out)

    def test_missing_config_exits_two(self):
        err = io.StringIO()
        with mock.patch.dict(os.environ, {}, clear=True), \
             mock.patch.object(sys, "stderr", err):
            code = racknerd.main(["status"])
        self.assertEqual(code, racknerd.EXIT_CONFIG_ERROR)


if __name__ == "__main__":
    unittest.main(verbosity=2)
