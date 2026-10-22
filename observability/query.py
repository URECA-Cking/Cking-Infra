#!/usr/bin/env python3
"""경보 진단 Lambda가 SSM 문서(dev-cking-observability-query)로 실행하는 읽기 전용 조회.

인자: 종류(prometheus, prometheus_range, loki), base64로 감싼 쿼리, 조회 범위(분).
"""
import base64
import datetime
import json
import subprocess
import sys
import time
import urllib.parse

MAX_SERIES = 20
MAX_POINTS = 30
MAX_LINES = 50
MAX_LINE_CHARS = 300
MAX_OUTPUT_CHARS = 20000
KEEP_LABELS = ("instance", "job", "container", "unit", "level", "stream", "group", "consumer", "mountpoint", "name", "uri", "status", "reason")


def fetch(url):
    done = subprocess.run(
        ["docker", "exec", "observability-nginx-1", "wget", "-qO-", url],
        capture_output=True, text=True, timeout=60,
    )
    if done.returncode != 0:
        detail = (done.stderr or done.stdout).strip()
        raise RuntimeError(detail[:500] or f"wget 종료 코드 {done.returncode}")
    return json.loads(done.stdout)


def utc(ts):
    return datetime.datetime.fromtimestamp(float(ts), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def series(result):
    rows = []
    for item in result[:MAX_SERIES]:
        row = {"labels": item.get("metric", {})}
        if "value" in item:
            row["value"] = item["value"][1]
        else:
            values = item.get("values", [])
            stride = max(1, -(-len(values) // MAX_POINTS))
            row["values"] = [[utc(t), v] for t, v in values[::stride]]
        rows.append(row)
    return {"series": rows, "series_total": len(result)}


def streams(result):
    lines = []
    for stream in result:
        labels = {k: v for k, v in stream.get("stream", {}).items() if k in KEEP_LABELS}
        for ts, line in stream.get("values", []):
            lines.append((int(ts), labels, line[:MAX_LINE_CHARS]))
    lines.sort(key=lambda x: x[0], reverse=True)
    return {
        "lines": [{"time": utc(ts / 1e9), "labels": labels, "line": line} for ts, labels, line in lines[:MAX_LINES]],
        "lines_total": len(lines),
    }


def main():
    kind, encoded, minutes = sys.argv[1], sys.argv[2], int(sys.argv[3])
    query = base64.b64decode(encoded).decode()
    end = int(time.time())
    start = end - max(minutes, 1) * 60
    step = max(15, (end - start) // MAX_POINTS)

    if kind == "prometheus":
        url = "http://prometheus:9090/api/v1/query?" + urllib.parse.urlencode({"query": query})
    elif kind == "prometheus_range":
        url = "http://prometheus:9090/api/v1/query_range?" + urllib.parse.urlencode(
            {"query": query, "start": start, "end": end, "step": step})
    elif kind == "loki":
        url = "http://loki:3100/loki/api/v1/query_range?" + urllib.parse.urlencode(
            {"query": query, "start": start * 10**9, "end": end * 10**9, "step": step, "limit": MAX_LINES, "direction": "backward"})
    else:
        raise SystemExit(f"알 수 없는 종류: {kind}")

    try:
        body = fetch(url)
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        return
    if body.get("status") != "success":
        print(json.dumps({"error": body.get("error", body)}, ensure_ascii=False)[:MAX_OUTPUT_CHARS])
        return

    data = body["data"]
    out = streams(data["result"]) if data["resultType"] == "streams" else series(data["result"])
    out["query_time"] = utc(end)
    text = json.dumps(out, ensure_ascii=False)
    if len(text) > MAX_OUTPUT_CHARS:
        text = text[:MAX_OUTPUT_CHARS] + "…(잘림)"
    print(text)


if __name__ == "__main__":
    main()
