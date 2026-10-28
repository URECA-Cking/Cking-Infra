"""업로드 원본(raw/)을 앱과 같은 규칙으로 정규화해 최종 키에 저장하고 결과를 결과 큐로 보낸다.

작업 큐 메시지는 S3 이벤트다. 원본 키는 raw/<최종 키>이고, 최소 크기는 앱이 사전 서명 때 넣은
메타데이터(min-width, min-height)로 받는다. 이미지가 규칙에 맞지 않으면 FAILED 결과를 보내고
메시지는 성공 처리한다. 그 밖의 오류는 다시 시도되고, 세 번 실패하면 DLQ로 간다.
"""
import io
import json
import logging
import os
import urllib.parse

import boto3
from PIL import Image, ImageOps

log = logging.getLogger()
log.setLevel(logging.INFO)

RAW_PREFIX = "raw/"
MAX_SOURCE_BYTES = 5 * 1024 * 1024
MAX_PIXEL_COUNT = 20_000_000
MAX_LONG_EDGE = 2048
JPEG_QUALITY = 90
ALLOWED_FORMATS = {"JPEG", "PNG"}
FINAL_PREFIXES = ("member-profile-images/", "creator-space-profile-images/", "post-images/")

Image.MAX_IMAGE_PIXELS = MAX_PIXEL_COUNT

s3 = boto3.client("s3")
sqs = boto3.client("sqs")
RESULTS_QUEUE_URL = os.environ["RESULTS_QUEUE_URL"]


class InvalidImage(Exception):
    pass


def handler(event, _context):
    failures = []
    for record in event.get("Records", []):
        try:
            for bucket, raw_key in s3_objects(json.loads(record["body"])):
                process(bucket, raw_key)
        except Exception:
            log.exception("처리 실패: messageId=%s", record.get("messageId"))
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}


def s3_objects(body):
    for item in body.get("Records", []):
        if not item.get("eventName", "").startswith("ObjectCreated"):
            continue
        yield item["s3"]["bucket"]["name"], urllib.parse.unquote_plus(item["s3"]["object"]["key"])


def process(bucket, raw_key):
    final_key = final_key_of(raw_key)
    if final_key is None:
        log.warning("처리 대상이 아닌 키: %s", raw_key)
        return
    head = s3.head_object(Bucket=bucket, Key=raw_key)
    try:
        if head["ContentLength"] <= 0 or head["ContentLength"] > MAX_SOURCE_BYTES:
            raise InvalidImage("size")
        meta = head.get("Metadata", {})
        min_width, min_height = int(meta.get("min-width", "0")), int(meta.get("min-height", "0"))
        source = s3.get_object(Bucket=bucket, Key=raw_key)["Body"].read()
        jpeg, width, height = normalize(source, min_width, min_height)
    except InvalidImage as e:
        send_result(final_key, "FAILED", reason=str(e))
        return
    s3.put_object(Bucket=bucket, Key=final_key, Body=jpeg, ContentType="image/jpeg")
    send_result(final_key, "READY", width=width, height=height, size=len(jpeg))


def final_key_of(raw_key):
    if not raw_key.startswith(RAW_PREFIX):
        return None
    final_key = raw_key[len(RAW_PREFIX):]
    if not final_key.startswith(FINAL_PREFIXES) or not final_key.endswith(".jpg") or ".." in final_key:
        return None
    return final_key


def normalize(source, min_width, min_height):
    try:
        image = Image.open(io.BytesIO(source))
        if image.format not in ALLOWED_FORMATS:
            raise InvalidImage("format")
        if image.width * image.height > MAX_PIXEL_COUNT:
            raise InvalidImage("pixels")
        image = ImageOps.exif_transpose(image)
    except (Image.DecompressionBombError, OSError, SyntaxError) as e:
        raise InvalidImage("decode") from e
    if image.width < min_width or image.height < min_height:
        raise InvalidImage("dimensions")

    longest = max(image.width, image.height)
    if longest > MAX_LONG_EDGE:
        scale = MAX_LONG_EDGE / longest
        target = (max(1, round(image.width * scale)), max(1, round(image.height * scale)))
        image = image.resize(target, Image.Resampling.BICUBIC)

    if image.mode != "RGB":
        rgba = image.convert("RGBA")
        background = Image.new("RGB", rgba.size, (255, 255, 255))
        background.paste(rgba, mask=rgba.getchannel("A"))
        image = background

    out = io.BytesIO()
    image.save(out, format="JPEG", quality=JPEG_QUALITY, progressive=False)
    return out.getvalue(), image.width, image.height


def send_result(final_key, status, **fields):
    body = {"key": final_key, "status": status, **fields}
    sqs.send_message(QueueUrl=RESULTS_QUEUE_URL, MessageBody=json.dumps(body))
    log.info("결과: %s", body)
