from pathlib import Path

from anthropic import AnthropicBedrock, BetaFallbackState, BetaRefusalFallbackMiddleware

from tools import TOOLS

# 서울 Mantle 엔드포인트에는 두 모델이 없어 bedrock-runtime의 global 추론 프로필로 부른다.
MODEL = "global.anthropic.claude-opus-5-5"
FALLBACK_MODEL = "global.anthropic.claude-opus-4-8"
# 100만 토큰당 달러. Bedrock 약관 제안(서울, global)에 적힌 값이다.
PRICES = {
    "claude-opus-5-5": {"input": 4.0, "output": 20.0, "cache_read": 0.20, "cache_write": 5.0},
    "claude-opus-4-8": {"input": 5.0, "output": 25.0, "cache_read": 0.50, "cache_write": 6.25},
}
SYSTEM = Path(__file__).with_name("prompt.md").read_text()

_client = AnthropicBedrock(
    aws_region="ap-northeast-2",
    middleware=[BetaRefusalFallbackMiddleware([{"model": FALLBACK_MODEL}])],
)


def diagnose(alert_text):
    usage = {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "tool_calls": 0, "cost": 0.0}
    last = None
    with BetaFallbackState():
        runner = _client.beta.messages.tool_runner(
            model=MODEL,
            max_tokens=16000,
            max_iterations=20,
            thinking={"type": "adaptive"},
            output_config={"effort": "medium"},
            system=[{"type": "text", "text": SYSTEM, "cache_control": {"type": "ephemeral"}}],
            tools=TOOLS,
            messages=[{"role": "user", "content": alert_text}],
        )
        for message in runner:
            last = message
            price = next((p for name, p in PRICES.items() if name in message.model), PRICES["claude-opus-5-5"])
            spent = {
                "input": message.usage.input_tokens,
                "output": message.usage.output_tokens,
                "cache_read": message.usage.cache_read_input_tokens or 0,
                "cache_write": message.usage.cache_creation_input_tokens or 0,
            }
            for key, tokens in spent.items():
                usage[key] += tokens
                usage["cost"] += tokens * price[key] / 1_000_000
            usage["tool_calls"] += sum(1 for block in message.content if block.type == "tool_use")

    if last is None:
        return {"text": "응답이 없었다", "usage": usage, "ok": False}
    if last.stop_reason == "refusal":
        return {"text": "모델이 분석을 거절했다", "usage": usage, "ok": False}
    text = "\n".join(block.text for block in last.content if block.type == "text").strip()
    if last.stop_reason == "tool_use":
        text = (text + "\n" if text else "") + "_조회 횟수 상한(20번)에 닿아 중간에 멈췄다_"
    return {"text": text or "결과 문장이 없었다", "usage": usage, "ok": bool(text)}
