#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""android-agent skill runner —— 已注册 skill 的调用入口（不负责创建）。

扫描本目录下的 skill 脚本自动注册，支持两种布局（可混用）：

    扁平:   skills/<名称>.py            （模块名 <名称>）
    文件夹: skills/<名称>/skill.py      （入口、助手、配置同目录；相对导入可用）

脚本定义 ``run(arguments) -> (str | dict)``，返回统一信封
``{"status": "ok", "result": {...}}`` / ``{"status": "error", ...}``。
``_`` 开头的文件/目录不参与注册。脚本的编写规范见同目录 README.md。

本文件由 Kotlin 侧 SkillTool 调用，每次调用都是一个全新进程：

    <python> _skill_runner.py <request.json>

``request.json`` 结构::

    {"action": "list|usage|run|delete",
     "skill": "<名称>",           # usage / run / delete 使用
     "arguments": {...}}          # run 时传给脚本 run() 的参数字典

stdout 只输出一个 JSON 信封。
"""
import importlib.util
import io
import json
import os
import re
import shutil
import sys
import traceback
import types

SKILL_DIR = os.path.dirname(os.path.abspath(__file__))
if SKILL_DIR not in sys.path:
    sys.path.insert(0, SKILL_DIR)

_SKILL_RE = re.compile(r'^#\s*skill\s*:\s*([A-Za-z0-9_\-]+)', re.I)
_DESC_RE = re.compile(r'^#\s*description\s*:\s*(.*)$', re.I)
_STATUS_RE = re.compile(r'^#\s*status\s*:\s*([A-Za-z0-9_\-]+)', re.I)
_USAGE_RE = re.compile(r'^#\s*usage\s*:\s*(.*)$', re.I)
_HASH_RE = re.compile(r'^#\s?')
_NAME_RE = re.compile(r'^[A-Za-z0-9_\-]{1,64}$')

# 视为“不披露”的 status；其余（含缺省）一律按 enable
_DISABLED = {"disable", "disabled", "off", "false", "0"}


def ok(result=None):
    return {"status": "ok", "result": result if result is not None else {}}


def error(message, code=None):
    payload = {"status": "error", "error": str(message)}
    if code is not None:
        payload["code"] = code
    return payload


def _is_enabled(meta):
    return str(meta.get("status") or "enable").strip().lower() not in _DISABLED


def _parse_header(path):
    """静态解析脚本头部（不导入执行），返回 meta 或 None。"""
    name = None
    description = ""
    status = "enable"
    usage_lines = []
    in_usage = False
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return None
    for raw in lines[:300]:
        line = raw.strip()
        if not line:
            if name is not None and in_usage:
                usage_lines.append("")
            continue
        if not line.startswith("#"):
            break
        # 重复的 # skill: 块：后者覆盖前者，重开一个干净的头部（避免头部重复时解析错乱）
        m = _SKILL_RE.match(line)
        if m:
            name = m.group(1)
            description = ""
            status = "enable"
            in_usage = False
            usage_lines = []
            continue
        if name is None:
            continue
        # status 在头部块内任意位置都生效（允许尾随内容）
        m = _STATUS_RE.match(line)
        if m:
            status = m.group(1).strip().lower()
            continue
        m = _DESC_RE.match(line)
        if m and not in_usage:
            description = m.group(1).strip()
            continue
        m = _USAGE_RE.match(line)
        if m:
            in_usage = True
            rest = m.group(1).strip()
            if rest:
                usage_lines.append(rest)
            continue
        if in_usage:
            # 混入 usage 的元信息行不计入用法，避免污染
            if _SKILL_RE.match(line) or _STATUS_RE.match(line) or _DESC_RE.match(line):
                continue
            usage_lines.append(_HASH_RE.sub("", line))
    if not name:
        return None
    return {
        "name": name,
        "description": description,
        "status": status,
        "usage": "\n".join(usage_lines).strip(),
        "path": path,
        "module": os.path.splitext(os.path.basename(path))[0],
    }


def _iter_entries():
    """枚举 skill 入口文件，产出 (entry_path, folder)。

    - 扁平:  skill/<名>.py         → (path, None)
    - 文件夹: skill/<名>/skill.py   → (path, <folder>)（入口、助手、配置同目录）
    `_` / `.` 开头的文件或目录一律跳过。
    """
    if not os.path.isdir(SKILL_DIR):
        return
    for fn in sorted(os.listdir(SKILL_DIR)):
        if fn.startswith("_") or fn.startswith("."):
            continue
        full = os.path.join(SKILL_DIR, fn)
        if os.path.isfile(full) and fn.endswith(".py"):
            yield full, None
        elif os.path.isdir(full):
            entry = os.path.join(full, "skill.py")
            if os.path.isfile(entry):
                yield entry, full


def scan():
    """扫描 SKILL_DIR（扁平 + 文件夹），返回 name -> meta。"""
    registry = {}
    for entry, folder in _iter_entries():
        meta = _parse_header(entry)
        if meta:
            meta["folder"] = folder
            registry[meta["name"]] = meta
    return registry


REGISTRY = scan()


def act_list():
    skills = {}
    for name, meta in REGISTRY.items():
        skills[name] = {
            "description": meta["description"],
            "status": meta.get("status", "enable"),
            "path": meta["path"],
        }
    return ok({"count": len(REGISTRY), "dir": SKILL_DIR, "skills": skills})


def act_usage(skill):
    meta = REGISTRY.get(skill)
    if not meta:
        return error(
            "未知 skill '%s'，可用: %s" % (skill, ", ".join(REGISTRY) or "(空)"),
            code="unknown_skill",
        )
    return ok({
        "skill": skill,
        "description": meta["description"],
        "status": meta.get("status", "enable"),
        "path": meta["path"],
        "usage": meta["usage"],
    })


def _load_module(meta):
    """按布局加载入口模块：文件夹式以包上下文加载，使相对导入（from ._x import）可用。"""
    folder = meta.get("folder")
    if folder:
        pkg = "_skillpkg_" + os.path.basename(folder)
        if pkg not in sys.modules:
            pkg_mod = types.ModuleType(pkg)
            pkg_mod.__path__ = [folder]
            sys.modules[pkg] = pkg_mod
        spec = importlib.util.spec_from_file_location(pkg + ".skill", meta["path"])
    else:
        spec = importlib.util.spec_from_file_location("_skill_" + meta["module"], meta["path"])
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def act_run(skill, arguments):
    meta = REGISTRY.get(skill)
    if not meta:
        return error(
            "未知 skill '%s'，可用: %s" % (skill, ", ".join(REGISTRY) or "(空)"),
            code="unknown_skill",
        )
    try:
        module = _load_module(meta)
    except Exception as e:
        return error("加载 skill 模块失败 - %s" % e, code="internal")
    run = getattr(module, "run", None)
    if not callable(run):
        return error("skill '%s' 缺少 run(arguments) 函数" % skill, code="bad_skill")

    # 捕获脚本内的 print，避免污染 stdout 的 JSON 信封
    buf = io.StringIO()
    saved = sys.stdout
    sys.stdout = buf
    try:
        result = run(arguments or {})
    except Exception as e:
        sys.stdout = saved
        return error("skill %s 执行失败 - %s\n%s" % (skill, e, traceback.format_exc()),
                     code="internal")
    finally:
        sys.stdout = saved
    captured = buf.getvalue().strip()

    if isinstance(result, str):
        try:
            parsed = json.loads(result)
        except Exception:
            parsed = None
        if isinstance(parsed, dict) and "status" in parsed:
            payload = parsed
        else:
            payload = ok({"output": result})
    elif isinstance(result, dict):
        payload = result if result.get("status") in ("ok", "error") else ok(result)
    else:
        payload = ok({"output": result})

    if captured:
        res = payload.get("result")
        if isinstance(res, dict):
            res.setdefault("stdout", captured)
        else:
            payload["result"] = {"value": res, "stdout": captured}
    return payload


def act_delete(skill):
    name = (skill or "").strip()
    if not _NAME_RE.match(name):
        return error("非法 skill 名称", code="invalid_name")
    flat = os.path.join(SKILL_DIR, name + ".py")
    folder = os.path.join(SKILL_DIR, name)
    try:
        if os.path.isfile(flat):
            os.remove(flat)
        elif os.path.isdir(folder):
            shutil.rmtree(folder)
        else:
            return error("skill '%s' 不存在" % name, code="not_found")
    except OSError as e:
        return error("删除失败 - %s" % e, code="io_error")
    return ok({"skill": name, "deleted": True})


def main():
    if len(sys.argv) < 2:
        print(json.dumps(error("缺少 request.json 路径参数"), ensure_ascii=False))
        return
    try:
        with open(sys.argv[1], encoding="utf-8") as f:
            req = json.load(f)
    except Exception as e:
        print(json.dumps(error("读取请求失败 - %s" % e), ensure_ascii=False))
        return

    action = (req.get("action") or "").strip()
    try:
        if action == "list":
            out = act_list()
        elif action == "usage":
            out = act_usage(req.get("skill") or "")
        elif action == "run":
            out = act_run(req.get("skill") or "", req.get("arguments"))
        elif action == "delete":
            out = act_delete(req.get("skill") or "")
        else:
            out = error("未知操作: %s" % action, code="unknown_action")
    except Exception as e:
        out = error("skill runner 失败 - %s" % e, code="internal")
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
