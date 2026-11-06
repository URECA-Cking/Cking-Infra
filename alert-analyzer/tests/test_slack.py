import json

import pytest

import slack


@pytest.fixture
def requests(monkeypatch):
    sent = []
    replies = {}

    def request(url, payload, headers):
        sent.append({"url": url, "payload": payload, "headers": headers})
        reply = replies.get(url, {"ok": True, "channel": "C-DEV", "ts": "9.9"})
        if isinstance(reply, Exception):
            raise reply
        return json.dumps(reply).encode()

    monkeypatch.setattr(slack, "_request", request)
    monkeypatch.setattr(slack, "_parameter", lambda name: f"value-of:{name}")
    return sent, replies


class TestSections:
    def test_short_text_one_block(self):
        assert slack.sections("a\nb") == [{"type": "section", "text": {"type": "mrkdwn", "text": "a\nb"}}]

    def test_splits_on_lines_under_limit(self):
        lines = ["x" * 1000] * 7
        blocks = slack.sections("\n".join(lines))
        texts = [b["text"]["text"] for b in blocks]
        assert all(len(t) <= slack.SECTION_CHARS for t in texts)
        assert "\n".join(texts) == "\n".join(lines)

    def test_long_single_line_cut(self):
        [block] = slack.sections("y" * 5000)
        assert len(block["text"]["text"]) == slack.SECTION_CHARS

    def test_empty(self):
        assert slack.sections("") == []


def test_context_limit():
    block = slack.context("z" * 5000)
    assert block["type"] == "context"
    assert len(block["elements"][0]["text"]) == 2900


class TestApi:
    def test_ok(self, requests):
        sent, _ = requests
        assert slack.api("chat.update", {"a": 1})["ok"]
        assert sent[0]["url"] == "https://slack.com/api/chat.update"
        assert sent[0]["headers"]["Authorization"] == f"Bearer value-of:{slack.BOT_TOKEN_PARAMETER}"

    def test_not_ok_raises(self, requests):
        _, replies = requests
        replies["https://slack.com/api/chat.update"] = {"ok": False, "error": "message_not_found"}
        with pytest.raises(RuntimeError, match="message_not_found"):
            slack.api("chat.update", {})


class TestPost:
    def test_bot_post(self, requests):
        sent, _ = requests
        assert slack.post("prod", "제목\n본문", thread_ts="1.1") == ("C-DEV", "9.9")
        payload = sent[0]["payload"]
        assert payload["channel"] == "C-PROD"
        assert payload["text"] == "제목"
        assert payload["thread_ts"] == "1.1"
        assert payload["blocks"] == slack.sections("제목\n본문")

    def test_preview_text_cut(self, requests):
        sent, _ = requests
        slack.post("dev", "가" * 300, blocks=[{"type": "divider"}])
        assert len(sent[0]["payload"]["text"]) == 150
        assert sent[0]["payload"]["blocks"] == [{"type": "divider"}]
        assert "thread_ts" not in sent[0]["payload"]

    def test_falls_back_to_webhook(self, requests):
        sent, replies = requests
        replies["https://slack.com/api/chat.postMessage"] = {"ok": False, "error": "not_in_channel"}
        assert slack.post("dev", "전체 본문") == (None, None)
        assert sent[-1]["url"] == f"value-of:{slack.WEBHOOK_PARAMETERS['dev']}"
        assert sent[-1]["payload"] == {"text": "전체 본문"}

    def test_unknown_channel_falls_back(self, requests, monkeypatch):
        sent, _ = requests
        monkeypatch.setattr(slack, "CHANNELS", {})
        assert slack.post("dev", "x") == (None, None)
        assert len(sent) == 1

    def test_webhook_failure_propagates(self, requests):
        _, replies = requests
        replies["https://slack.com/api/chat.postMessage"] = RuntimeError("bot")
        replies[f"value-of:{slack.WEBHOOK_PARAMETERS['dev']}"] = RuntimeError("webhook")
        with pytest.raises(RuntimeError, match="webhook"):
            slack.post("dev", "x")


def test_parameter_cached():
    slack._ssm.get_parameter.return_value = {"Parameter": {"Value": "secret"}}
    assert slack._parameter("/p") == "secret"
    assert slack._parameter("/p") == "secret"
    slack._ssm.get_parameter.assert_called_once_with(Name="/p", WithDecryption=True)
