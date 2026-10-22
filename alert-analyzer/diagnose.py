from pathlib import Path

import boto3
from anthropic import Anthropic

from tools import TOOLS

API_KEY_PARAMETER = "/cking/dev/monitoring/ANTHROPIC_API_KEY"
MODEL = "claude-opus-5-5"
FALLBACK_MODEL = "claude-opus-4-8"
# 100만 토큰당 달러(Claude API 가격표). 캐시 쓰기는 5분 캐시 단가다.
PRICES = {
    "claude-opus-5-5": {"input": 4.0, "output": 20.0, "cache_read": 0.20, "cache_write": 5.0},
    "claude-opus-4-8": {"input": 5.0, "output": 25.0, "cache_read": 0.50, "cache_write": 6.25},
}
SYSTEM = Path(__file__).with_name("prompt.md").read_text()

_client = Anthropic(
    api_key=boto3.client("ssm", region_name="ap-northeast-2")
    .get_parameter(Name=API_KEY_PARAMETER, WithDecryption=True)["Parameter"]["Value"],
)


def _add_usage(usage, message):
    # 거절되어 대체 모델로 넘어가면 시도마다 모델이 달라 iterations로 나눠 센다.
    entries = message.usage.iterations or [message.usage]
    for entry in entries:
        model = getattr(entry, "model", None) or (message.model if entry is message.usage else MODEL)
        price = next((p for name, p in PRICES.items() if name in model), PRICES[MODEL])
        spent = {
            "input": entry.input_tokens,
            "output": entry.output_tokens,
            "cache_read": entry.cache_read_input_tokens or 0,
            "cache_write": entry.cache_creation_input_tokens or 0,
        }
        for key, tokens in spent.items():
            usage[key] += tokens
            usage["cost"] += tokens * price[key] / 1_000_000


def diagnose(alert_text):
    usage = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "tool_calls": 0, "cost": 0.0}
    last = None
    # 조회할 때마다 앞선 대화 전체를 다시 보내므로 자동 캐시로 이전 부분을 캐시 읽기 단가로 받는다.
    runner = _client.beta.messages.tool_runner(
        model=MODEL,
        max_tokens=16000,
        max_iterations=20,
        thinking={"type": "adaptive"},
        output_config={"effort": "medium"},
        cache_control={"type": "ephemeral"},
        betas=["server-side-fallback-2026-06-01"],
        fallbacks=[{"model": FALLBACK_MODEL}],
        system=SYSTEM,
        tools=TOOLS,
        messages=[{"role": "user", "content": alert_text}],
    )
    for message in runner:
        last = message
        _add_usage(usage, message)
        usage["tool_calls"] += sum(1 for block in message.content if block.type == "tool_use")

    if last is None:
        return {"text": "응답이 없었다", "usage": usage, "ok": False}
    if last.stop_reason == "refusal":
        return {"text": "모델이 분석을 거절했다", "usage": usage, "ok": False}
    text = "\n".join(block.text for block in last.content if block.type == "text").strip()
    if last.stop_reason == "tool_use":
        text = (text + "\n" if text else "") + "_조회 횟수 상한(20번)에 닿아 중간에 멈췄다_"
    return {"text": text or "결과 문장이 없었다", "usage": usage, "ok": bool(text)}
