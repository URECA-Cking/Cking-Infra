import importlib.util
import os
from pathlib import Path
from unittest import mock

import boto3
import pytest

os.environ.setdefault("RESULTS_QUEUE_URL", "https://sqs.test/results")

# 경보 진단 Lambda에도 handler 모듈이 있어 이름이 겹치지 않게 파일 경로로 불러온다.
_spec = importlib.util.spec_from_file_location(
    "image_normalizer_handler", Path(__file__).resolve().parent.parent / "handler.py")
normalizer = importlib.util.module_from_spec(_spec)
with mock.patch.object(boto3, "client", lambda *args, **kwargs: mock.MagicMock()):
    _spec.loader.exec_module(normalizer)


@pytest.fixture
def handler():
    return normalizer
