#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""skill 脚本可选的统一信封工具（等价 shell-tool 的 core.tools.envelope）。

用法::

    from _envelope import ok, error

    def run(arguments):
        if not arguments.get("x"):
            return error("缺少 x 参数", code="invalid_argument")
        return ok({"value": arguments["x"] * 2})

``ok`` / ``error`` 返回 dict（信封）；``ok_json`` / ``error_json`` 返回 JSON 字符串。
skill 的 ``run`` 直接 return 其一即可，runner 会透传规范信封。
"""
import json


def ok(result=None):
    """构造成功信封。result 应为 dict（可空）。"""
    return {"status": "ok", "result": result if result is not None else {}}


def error(message, code=None):
    """构造失败信封。code 为可选的稳定错误类别（如 invalid_argument/not_found）。"""
    payload = {"status": "error", "error": str(message)}
    if code is not None:
        payload["code"] = code
    return payload


def ok_json(result=None):
    return json.dumps(ok(result), ensure_ascii=False)


def error_json(message, code=None):
    return json.dumps(error(message, code), ensure_ascii=False)
