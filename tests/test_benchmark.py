from benchmark.common import edit_distance, mixed_tokens, normalize_text


def test_normalize_text():
    assert normalize_text("KV Cache，FastAPI!") == "kvcachefastapi"


def test_mixed_tokens():
    assert mixed_tokens("我用 FastAPI 2 次") == ["我", "用", "fastapi", "2", "次"]


def test_edit_distance():
    assert edit_distance(list("模型"), list("摸型")) == 1
