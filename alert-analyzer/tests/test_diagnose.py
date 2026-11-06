from types import SimpleNamespace

import pytest

import diagnose
import tools


def usage(input=0, output=0, cache_read=None, cache_write=None, iterations=None, model=None):
    entry = SimpleNamespace(input_tokens=input, output_tokens=output, cache_read_input_tokens=cache_read,
                            cache_creation_input_tokens=cache_write, iterations=iterations)
    if model:
        entry.model = model
    return entry


def message(stop="end_turn", text=None, tool_uses=0, model="claude-opus-5-5", use=None):
    content = [SimpleNamespace(type="tool_use") for _ in range(tool_uses)]
    if text is not None:
        content.append(SimpleNamespace(type="text", text=text))
    return SimpleNamespace(stop_reason=stop, content=content, model=model, usage=use or usage(10, 5))


@pytest.fixture
def runner(monkeypatch):
    state = {"messages": [], "kwargs": None}

    def tool_runner(**kwargs):
        state["kwargs"] = kwargs
        return iter(state["messages"])

    fake = SimpleNamespace(beta=SimpleNamespace(messages=SimpleNamespace(tool_runner=tool_runner)))
    monkeypatch.setattr(diagnose, "_client", fake)
    return state


def zero():
    return {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "tool_calls": 0, "cost": 0.0}


class TestAddUsage:
    def test_single_model(self):
        total = zero()
        diagnose._add_usage(total, message(use=usage(1_000_000, 100_000, 2_000_000, 0)))
        assert (total["input"], total["output"], total["cache_read"], total["cache_write"]) == (1_000_000, 100_000, 2_000_000, 0)
        assert total["cost"] == pytest.approx(4.0 + 2.0 + 0.4)

    def test_none_cache_counts_as_zero(self):
        total = zero()
        diagnose._add_usage(total, message(use=usage(0, 0, None, None)))
        assert total["cache_read"] == 0 and total["cache_write"] == 0

    def test_fallback_iterations_priced_per_model(self):
        iterations = [usage(1_000_000, 0, model="claude-opus-5-5"), usage(1_000_000, 0, model="claude-opus-4-8")]
        total = zero()
        diagnose._add_usage(total, message(use=usage(2_000_000, 0, iterations=iterations)))
        assert total["input"] == 2_000_000
        assert total["cost"] == pytest.approx(4.0 + 5.0)

    def test_unknown_model_uses_main_price(self):
        total = zero()
        diagnose._add_usage(total, message(model="claude-other", use=usage(1_000_000, 0)))
        assert total["cost"] == pytest.approx(diagnose.PRICES[diagnose.MODEL]["input"])


class TestDiagnose:
    def test_final_text_and_tool_calls(self, runner):
        runner["messages"] = [message(stop="tool_use", tool_uses=2), message(text="*판단*: 조치 필요 없음\n*상황*: x ")]
        result = diagnose.diagnose("경보")
        assert result["text"] == "*판단*: 조치 필요 없음\n*상황*: x"
        assert result["ok"]
        assert result["usage"]["tool_calls"] == 2
        assert result["usage"]["input"] == 20
        assert result["proposal"] is None
        assert runner["kwargs"]["messages"] == [{"role": "user", "content": "경보"}]
        assert runner["kwargs"]["tools"] is tools.TOOLS

    def test_no_response(self, runner):
        result = diagnose.diagnose("경보")
        assert result == {"text": "응답이 없었다", "usage": zero(), "ok": False, "proposal": None}

    def test_refusal_drops_proposal(self, runner):
        def respond(**kwargs):
            tools.PROPOSAL.update({"action": "dev_app_restart"})
            return iter([message(stop="refusal", text="")])

        diagnose._client.beta.messages.tool_runner = respond
        result = diagnose.diagnose("경보")
        assert result["text"] == "모델이 분석을 거절했다"
        assert result["proposal"] is None
        assert not result["ok"]

    def test_iteration_limit_noted(self, runner):
        runner["messages"] = [message(stop="tool_use", text="중간 결과", tool_uses=1)]
        result = diagnose.diagnose("경보")
        assert result["text"] == "중간 결과\n_조회 횟수 상한(20번)에 닿아 중간에 멈췄다_"

    def test_empty_text(self, runner):
        runner["messages"] = [message(text="  ")]
        result = diagnose.diagnose("경보")
        assert result["text"] == "결과 문장이 없었다"
        assert not result["ok"]

    def test_proposal_reset_per_diagnosis(self, runner):
        tools.PROPOSAL.update({"action": "old"})
        runner["messages"] = [message(text="결과")]
        assert diagnose.diagnose("경보")["proposal"] is None

    def test_proposal_returned(self, runner):
        def respond(**kwargs):
            tools.PROPOSAL.update({"action": "dev_app_restart", "ok": True})
            return iter([message(text="*판단*: 지금 조치 필요")])

        diagnose._client.beta.messages.tool_runner = respond
        assert diagnose.diagnose("경보")["proposal"] == {"action": "dev_app_restart", "ok": True}
