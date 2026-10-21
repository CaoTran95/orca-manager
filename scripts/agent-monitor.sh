#!/usr/bin/env bash
# Read-only: tổng hợp agent Claude/Codex/Cursor từ Orca CLI và task file.
# Không tạo/dừng agent, không sửa worktree, không đổi task, không gọi AI.
# Dùng:
#   scripts/agent-monitor.sh --once
#   scripts/agent-monitor.sh --watch 5
#   scripts/agent-monitor.sh --self-test
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$ROOT" "$@" <<'PY'
import json, os, re, shutil, subprocess, sys, time
from datetime import datetime, timezone

ROOT = sys.argv[1]
ARGS = sys.argv[2:]
TASK_DIR = os.path.join(ROOT, "docs", "tasks")
SKIP_TASK_FILES = {"README.md", "TEMPLATE.md", "HANDOFF_TEMPLATE.md"}
PAGE_LIMIT = 100
MAX_PAGES = 50
LIST_CAP = 2000
CMD_TIMEOUT = 30
AGENT_SKIP = {"", "shell", "bash", "zsh", "fish"}
HANDLE_RE = re.compile(r"term_[0-9a-fA-F]{8}(?:-[0-9a-fA-F]+)*")
TASK_ID_RE = re.compile(r"(?i)^(?:T\d+[A-Za-z0-9-]*|task_[0-9a-fA-F]+)$")
INLINE_TASK_RE = re.compile(r"(?<![\w-])(task_[0-9a-fA-F]+|T\d+[A-Za-z0-9-]*)(?![\w-])", re.I)
STATUS_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{1,31}$")
FEATURE_RE = re.compile(r"(?m)^- Feature key:\s*(\S+)\s*$")
COLUMNS = ["Origin", "Agent", "Repository", "Worktree", "Feature", "Task", "Session", "Activity", "Updated"]

def die(msg, code=2):
    print(msg, file=sys.stderr)
    raise SystemExit(code)

def usage():
    die(
        "Dùng: scripts/agent-monitor.sh --once | --watch <giây> | --self-test\n"
        "Chỉ đọc trạng thái. Không tạo/dừng agent, không sửa worktree hay task.",
        2,
    )

def parse_args(argv):
    if argv == ["--once"]:
        return "once", None
    if argv == ["--self-test"]:
        return "self-test", None
    if len(argv) == 2 and argv[0] == "--watch":
        try:
            seconds = int(argv[1])
        except ValueError:
            die("--watch cần số giây nguyên dương, ví dụ --watch 5", 2)
        if seconds <= 0:
            die("--watch cần số giây nguyên dương, ví dụ --watch 5", 2)
        return "watch", seconds
    usage()

def cell(value):
    if value is None:
        return "-"
    text = str(value).strip()
    return text if text else "-"

def first(obj, *keys):
    if not isinstance(obj, dict):
        return None
    for key in keys:
        value = obj.get(key)
        if value not in (None, ""):
            return value
    return None

def as_dict(value):
    return value if isinstance(value, dict) else {}

def norm_path(value):
    if not isinstance(value, str):
        return None
    text = value.strip().rstrip("/")
    return text or None

def epoch_of(value):
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        number = float(value)
        if number > 10_000_000_000:
            number /= 1000.0
        if number > 1_000_000_000:
            return number
        return None
    if isinstance(value, str) and value.endswith("Z"):
        for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"):
            try:
                parsed = datetime.strptime(value, fmt).replace(tzinfo=timezone.utc)
                return parsed.timestamp()
            except ValueError:
                continue
    return None

def fmt_epoch(value):
    stamp = epoch_of(value)
    if stamp is None:
        return None
    return datetime.fromtimestamp(stamp).strftime("%Y-%m-%d %H:%M:%S")

def latest_update(values):
    best = None
    for value in values:
        stamp = epoch_of(value)
        if stamp is None:
            continue
        if best is None or stamp > best:
            best = stamp
    if best is None:
        return "-"
    return datetime.fromtimestamp(best).strftime("%Y-%m-%d %H:%M:%S")

def feature_from_branch(branch):
    if not isinstance(branch, str):
        return None
    name = branch.removeprefix("refs/heads/")
    if name.startswith("feat/") and name != "feat/":
        return name[len("feat/"):]
    return None

def path_from_worktree_id(value):
    if not isinstance(value, str) or "::/" not in value:
        return None
    path = norm_path(value.split("::", 1)[1])
    if path and path.startswith("/"):
        return path
    return None

def short_text(value, limit=180):
    if isinstance(value, dict):
        value = first(value, "message") or json.dumps(value, ensure_ascii=False)
    text = " ".join(str(value or "").split())
    return text[:limit] or "unknown"

def find_rows(result, names, hints):
    if isinstance(result, list):
        return result, "result-list"
    if not isinstance(result, dict):
        return [], "result-type"
    for name in names:
        if name in result:
            value = result[name]
            if isinstance(value, list):
                return value, None
            return [], f"bad-type:{name}"
    for key, value in result.items():
        if not isinstance(value, list) or not value or not isinstance(value[0], dict):
            continue
        if any(hint in value[0] for hint in hints):
            return value, f"alt:{key}"
    return [], "missing"

def page_info(result):
    if not isinstance(result, dict):
        return None, False, None
    page = result.get("page") if isinstance(result.get("page"), dict) else {}
    total = page.get("total")
    if not isinstance(total, int):
        total = result.get("total") if isinstance(result.get("total"), int) else None
    for source in (page, result):
        cursor = source.get("nextCursor", source.get("next_cursor"))
        has_more = source.get("hasMore", source.get("has_more"))
        if isinstance(cursor, str) and cursor:
            if has_more is False:
                return None, False, total
            return cursor, True, total
        if has_more is True:
            return None, True, total
    return None, False, total

def orca_json(args):
    try:
        proc = subprocess.run(
            ["orca", *args, "--json"],
            capture_output=True,
            text=True,
            timeout=CMD_TIMEOUT,
        )
    except FileNotFoundError:
        return None, "orca-not-found"
    except subprocess.TimeoutExpired:
        return None, f"timeout: orca {' '.join(args)}"
    payload = proc.stdout.strip()
    if not payload:
        err = short_text(proc.stderr or f"exit {proc.returncode}")
        return None, err
    try:
        data = json.loads(payload)
    except json.JSONDecodeError:
        return None, "json không hợp lệ"
    if not isinstance(data, dict):
        return None, "json không phải object"
    if data.get("ok") is False:
        return None, short_text(data.get("error") or "ok=false")
    return data, None

def collect_pages(fetch):
    rows, seen, errors = [], set(), []
    cursor = None
    pages = 0
    for _ in range(MAX_PAGES):
        page_rows, next_cursor, has_more, err = fetch(cursor)
        pages += 1
        if err:
            errors.append(err)
            break
        if isinstance(page_rows, list):
            rows.extend(page_rows)
        if not has_more:
            break
        if not isinstance(next_cursor, str) or not next_cursor:
            errors.append("hasMore nhưng không có nextCursor")
            break
        if next_cursor in seen or next_cursor == cursor:
            errors.append("nextCursor lặp")
            break
        seen.add(next_cursor)
        cursor = next_cursor
    else:
        errors.append(f"dừng sau {MAX_PAGES} trang")
    return rows, pages, errors

def fetch_named(args, names, hints, limit):
    warnings = []

    def fetch(cursor):
        cmd = [*args, "--limit", str(limit)]
        if cursor:
            cmd.extend(["--cursor", cursor])
        data, err = orca_json(cmd)
        if err:
            return [], None, False, err
        result = data.get("result")
        got, note = find_rows(result, names, hints)
        if note:
            warnings.append(f"{' '.join(args)} schema: {note}")
        nxt, more, _total = page_info(result if isinstance(result, dict) else {})
        return got, nxt, more, None

    rows, pages, errors = collect_pages(fetch)
    for err in errors:
        warnings.append(f"{' '.join(args)}: {err}")
    return rows, pages, warnings, (not errors or bool(rows))

def fetch_capped(args, names, hints):
    warnings = []
    limit = 200
    while True:
        data, err = orca_json([*args, "--limit", str(limit)])
        if err:
            return [], [f"{' '.join(args)}: {err}"], False
        result = data.get("result")
        result_dict = result if isinstance(result, dict) else {}
        rows, note = find_rows(result, names, hints)
        if note:
            warnings.append(f"{' '.join(args)} schema: {note}")
        host = result_dict.get("hostScope") if isinstance(result_dict.get("hostScope"), dict) else {}
        omitted = host.get("omittedHostIds")
        if isinstance(omitted, list) and omitted:
            warnings.append(
                f"{' '.join(args)}: host chưa phủ ({', '.join(map(str, omitted))}); không suy ra là không có agent"
            )
        truncated = result_dict.get("truncated")
        total = result_dict.get("totalCount")
        if not isinstance(total, int):
            total = result_dict.get("total") if isinstance(result_dict.get("total"), int) else None
        if truncated is True and isinstance(total, int) and total > len(rows) and limit < min(LIST_CAP, total):
            limit = min(LIST_CAP, total)
            continue
        if truncated is True:
            warnings.append(f"{' '.join(args)}: trang bị cắt {len(rows)}/{total if total is not None else '?'}")
        elif isinstance(total, int) and total > len(rows):
            warnings.append(f"{' '.join(args)}: nhận {len(rows)}/{total} dòng")
        return rows, warnings, True

def load_task_files(directory):
    records, warnings = [], []
    if not os.path.isdir(directory):
        return records, [f"không thấy {directory}"]
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".md") or name in SKIP_TASK_FILES:
            continue
        path = os.path.join(directory, name)
        try:
            text = open(path, encoding="utf-8").read()
        except OSError as exc:
            warnings.append(f"{name}: {exc}")
            continue
        features = [item for item in FEATURE_RE.findall(text) if not item.startswith("<")]
        feature = features[0] if len(set(features)) == 1 else None
        if len(set(features)) > 1:
            warnings.append(f"{name}: nhiều Feature key, không gắn feature từ file này")
        links = []
        headers = None
        for raw in text.splitlines():
            line = raw.strip()
            if not line.startswith("|"):
                if re.search(r"\bTask\b", line):
                    task_ids = [item for item in INLINE_TASK_RE.findall(line) if TASK_ID_RE.fullmatch(item)]
                    tokens = HANDLE_RE.findall(line)
                    for token in tokens:
                        for task_id in task_ids:
                            links.append({"token": token, "task_id": task_id, "status": None, "file": name})
                continue
            cells = [part.strip() for part in line.strip().strip("|").split("|")]
            if not cells or all(set(part) <= set("-: ") and part for part in cells):
                continue
            if cells[0].lower() in {"task id", "task"}:
                headers = [part.lower() for part in cells]
                continue
            if not TASK_ID_RE.fullmatch(cells[0]):
                continue
            status = None
            if headers and "status" in headers:
                index = headers.index("status")
                if index < len(cells) and STATUS_RE.fullmatch(cells[index]):
                    status = cells[index]
            for token in HANDLE_RE.findall(line):
                links.append({"token": token, "task_id": cells[0], "status": status, "file": name})
        records.append({"file": name, "feature": feature, "links": links})
    return records, warnings

def worker_handle(worker):
    handle = first(worker, "agentTerminalHandle", "agent_terminal_handle", "terminalHandle")
    if isinstance(handle, str):
        return handle
    return first(as_dict(worker.get("resource")), "terminalHandle", "terminal_handle")

def worker_task_id(worker):
    found = first(worker, "taskId", "task_id")
    if isinstance(found, str):
        return found
    found = first(as_dict(worker.get("projection")), "taskId", "task_id")
    return found if isinstance(found, str) else None

def worker_run_id(worker):
    found = first(worker, "runId", "run_id")
    if isinstance(found, str):
        return found
    found = first(as_dict(worker.get("projection")), "runId", "run_id")
    return found if isinstance(found, str) else None

def worker_agent(worker):
    provider = as_dict(as_dict(worker.get("projection")).get("provider"))
    found = first(provider, "id", "name") or first(worker, "agent", "agentType", "agent_type")
    return str(found).casefold() if isinstance(found, str) else None

def worker_path(worker):
    for source in (
        as_dict(worker.get("resource")).get("worktreeId"),
        as_dict(as_dict(worker.get("projection")).get("workspace")).get("id"),
        first(worker, "worktreeId", "worktree_id"),
    ):
        path = path_from_worktree_id(source)
        if path:
            return path
    return None

def worker_key(worker):
    dispatch = first(worker, "dispatchId", "dispatch_id")
    if isinstance(dispatch, str) and dispatch:
        return ("dispatch", dispatch)
    return ("fallback", worker_handle(worker), worker_task_id(worker), worker_run_id(worker))

def worker_times(worker):
    proj = as_dict(worker.get("projection"))
    live = as_dict(proj.get("liveness"))
    evidence = as_dict(proj.get("evidence"))
    return [live.get("observedAt"), live.get("observed_at"), evidence.get("lastObservedAt"), evidence.get("last_observed_at")]

def worker_activity(worker):
    stage = as_dict(as_dict(worker.get("projection")).get("stage"))
    parts = []
    activity = first(stage, "activity")
    state = first(worker, "workerState", "worker_state") or first(stage, "worker")
    if isinstance(activity, str) and activity:
        parts.append(f"activity:{activity}")
    if isinstance(state, str) and state and state != activity:
        parts.append(f"worker:{state}")
    return parts

def pane_type(pane):
    found = first(pane, "agentType", "agent_type", "type")
    if not isinstance(found, str):
        return None
    name = found.casefold()
    return None if name in AGENT_SKIP else name

def pane_list(worktree):
    for key in ("agents", "agentPanes", "panes"):
        if key in worktree:
            value = worktree.get(key)
            return value if isinstance(value, list) else []
    rows, note = find_rows(worktree, (), ("agentType", "agent_type"))
    return rows if note and note.startswith("alt:") else []

def terminal_agent(terminal):
    found = first(terminal, "agentIdentity", "agent_identity", "agentType", "agent_type")
    if not isinstance(found, str):
        return None
    name = found.casefold()
    return None if name in AGENT_SKIP else name

def resolve_handle(token, handles):
    if not isinstance(token, str) or len(token) < len("term_") + 8:
        return None
    if token in handles:
        return token
    matches = sorted({handle for handle in handles if handle.startswith(token + "-")})
    if len(matches) == 1:
        return matches[0]
    return None

def repo_id_from_worktree_id(value):
    if isinstance(value, str) and "::/" in value:
        prefix = value.split("::", 1)[0].strip()
        return prefix or None
    return None

def index_locations(ps_rows, wt_rows, repo_rows):
    repo_name = {}
    for repo in repo_rows:
        if isinstance(repo, dict) and isinstance(repo.get("id"), str):
            name = first(repo, "displayName", "name")
            if isinstance(name, str):
                repo_name[repo["id"]] = name
    locations = {}
    for row in wt_rows:
        if not isinstance(row, dict):
            continue
        path = norm_path(first(row, "path"))
        if not path:
            continue
        locations[path] = {
            "repo": repo_name.get(row.get("repoId")) or repo_name.get(row.get("repo_id")),
            "branch": first(row, "branch"),
            "display": first(row, "displayName", "display_name"),
        }
    for row in ps_rows:
        if not isinstance(row, dict):
            continue
        path = norm_path(first(row, "path"))
        if not path:
            continue
        current = locations.setdefault(path, {})
        if isinstance(first(row, "repo"), str):
            current["repo"] = first(row, "repo")
        if first(row, "branch"):
            current["branch"] = first(row, "branch")
        if first(row, "displayName", "display_name"):
            current["display"] = first(row, "displayName", "display_name")
        repo_id = first(row, "repoId", "repo_id")
        if not current.get("repo") and isinstance(repo_id, str):
            current["repo"] = repo_name.get(repo_id)
    return locations, repo_name

def format_tasks(items):
    merged, conflict = {}, set()
    for task_id, status in items:
        if not task_id:
            continue
        if task_id not in merged:
            merged[task_id] = status or None
        elif status and merged[task_id] and status != merged[task_id]:
            conflict.add(task_id)
        elif status and not merged[task_id]:
            merged[task_id] = status
    parts = []
    for task_id in sorted(merged):
        status = None if task_id in conflict else merged[task_id]
        parts.append(f"{task_id} (status={status})" if status else str(task_id))
    return ", ".join(parts) if parts else "-"

def build_rows(snapshot):
    warnings = list(snapshot.get("warnings") or [])
    locations, repo_names = index_locations(
        snapshot.get("ps") or [],
        snapshot.get("worktrees") or [],
        snapshot.get("repos") or [],
    )
    terminals = [item for item in (snapshot.get("terminals") or []) if isinstance(item, dict)]
    panes_by_path = {}
    for worktree in snapshot.get("ps") or []:
        if not isinstance(worktree, dict):
            continue
        path = norm_path(first(worktree, "path"))
        if not path:
            continue
        panes_by_path[path] = [pane for pane in pane_list(worktree) if isinstance(pane, dict) and pane_type(pane)]
    workers = []
    seen_workers = set()
    for worker in snapshot.get("workers") or []:
        if not isinstance(worker, dict):
            continue
        key = worker_key(worker)
        if key in seen_workers:
            continue
        seen_workers.add(key)
        workers.append(worker)
    task_status = {}
    for task in snapshot.get("tasks") or []:
        if not isinstance(task, dict):
            continue
        task_id = first(task, "id", "taskId", "task_id")
        status = first(task, "status")
        if isinstance(task_id, str) and isinstance(status, str) and STATUS_RE.fullmatch(status):
            task_status.setdefault(task_id, status)
    handles = set()
    for terminal in terminals:
        handle = first(terminal, "handle")
        if isinstance(handle, str):
            handles.add(handle)
    for worker in workers:
        handle = worker_handle(worker)
        if isinstance(handle, str):
            handles.add(handle)
    links_by_handle = {}
    features_by_handle = {}
    for record in snapshot.get("task_files") or []:
        for link in record.get("links") or []:
            token = link.get("token")
            if not isinstance(token, str):
                continue
            handle = resolve_handle(token, handles)
            if not handle:
                continue
            if link.get("task_id"):
                links_by_handle.setdefault(handle, []).append((link["task_id"], link.get("status")))
            if record.get("feature"):
                features_by_handle.setdefault(handle, set()).add(record["feature"])
    workers_by_handle = {}
    for worker in workers:
        handle = worker_handle(worker)
        if isinstance(handle, str):
            workers_by_handle.setdefault(handle, []).append(worker)
    terms_by_path = {}
    for terminal in terminals:
        agent = terminal_agent(terminal)
        path = norm_path(first(terminal, "worktreePath", "worktree_path", "path"))
        if not agent or not path:
            continue
        terms_by_path.setdefault(path, {}).setdefault(agent, []).append(terminal)
    consumed_panes = set()
    consumed_workers = set()
    rows = []

    def location_for(path, terminal=None):
        info = dict(locations.get(path) or {})
        if terminal and not info.get("branch"):
            info["branch"] = first(terminal, "branch")
        return info

    def add_row(*, origin, agent, path, info, feature_links, tasks, session, activity_parts, times, worktree_label=None):
        branch_feature = feature_from_branch((info or {}).get("branch"))
        features = set(feature_links or [])
        if branch_feature:
            features.add(branch_feature)
        if len(features) == 1:
            feature = next(iter(features))
        elif len(features) > 1:
            feature = " | ".join(sorted(features))
        else:
            feature = "-"
        display = worktree_label or (info or {}).get("display")
        if not display and path:
            display = os.path.basename(path)
        rows.append({
            "Origin": origin,
            "Agent": agent or "-",
            "Repository": cell((info or {}).get("repo")),
            "Worktree": cell(display),
            "Feature": cell(feature),
            "Task": format_tasks(tasks),
            "Session": cell(session),
            "Activity": " ".join(activity_parts) if activity_parts else "-",
            "Updated": latest_update(times),
            "_path": path or "",
        })

    paths = sorted(set(panes_by_path) | set(terms_by_path))
    for path in paths:
        pane_groups = {}
        for pane in panes_by_path.get(path, []):
            pane_groups.setdefault(pane_type(pane), []).append(pane)
        term_groups = terms_by_path.get(path) or {}
        for agent in sorted(set(pane_groups) | set(term_groups)):
            panes = pane_groups.get(agent) or []
            terms = term_groups.get(agent) or []
            if len(panes) == 1 and len(terms) == 1:
                pairs = [(panes[0], terms[0])]
            elif not terms:
                pairs = [(pane, None) for pane in panes]
            elif not panes:
                pairs = [(None, terminal) for terminal in terms]
            else:
                warnings.append(
                    f"không gán activity cho {path} ({agent}): {len(panes)} pane và {len(terms)} terminal, không khớp duy nhất"
                )
                pairs = [(None, terminal) for terminal in terms]
            for pane, terminal in pairs:
                if pane is not None:
                    consumed_panes.add(id(pane))
                handle = first(terminal, "handle") if terminal else None
                matched_workers = workers_by_handle.get(handle, []) if isinstance(handle, str) else []
                for worker in matched_workers:
                    consumed_workers.add(id(worker))
                origin = "orchestration" if matched_workers else "manual"
                activity = []
                if pane is not None and isinstance(pane.get("state"), str) and pane.get("state"):
                    activity.append(f"pane:{pane['state']}")
                    if pane.get("interrupted") is True:
                        activity.append("interrupted")
                times = []
                if pane is not None:
                    times.append(first(pane, "updatedAt", "updated_at"))
                if terminal is not None:
                    times.append(first(terminal, "lastOutputAt", "last_output_at"))
                tasks = []
                if isinstance(handle, str):
                    tasks.extend(links_by_handle.get(handle, []))
                feature_links = set(features_by_handle.get(handle, ())) if isinstance(handle, str) else set()
                for worker in matched_workers:
                    activity.extend(worker_activity(worker))
                    times.extend(worker_times(worker))
                    task_id = worker_task_id(worker)
                    if task_id:
                        tasks.append((task_id, task_status.get(task_id)))
                add_row(
                    origin=origin,
                    agent=agent,
                    path=path,
                    info=location_for(path, terminal),
                    feature_links=feature_links,
                    tasks=tasks,
                    session=handle,
                    activity_parts=activity,
                    times=times,
                )
    for worker in workers:
        if id(worker) in consumed_workers:
            continue
        path = worker_path(worker)
        agent = worker_agent(worker)
        handle = worker_handle(worker)
        info = dict(location_for(path) if path else {})
        if not info.get("repo"):
            for source in (
                as_dict(worker.get("resource")).get("worktreeId"),
                as_dict(as_dict(worker.get("projection")).get("workspace")).get("id"),
                first(worker, "worktreeId", "worktree_id"),
            ):
                repo_id = repo_id_from_worktree_id(source)
                if repo_id and repo_names.get(repo_id):
                    info["repo"] = repo_names[repo_id]
                    break
        candidate_panes = []
        if path and agent:
            candidate_panes = [pane for pane in panes_by_path.get(path, []) if pane_type(pane) == agent and id(pane) not in consumed_panes]
        pane = candidate_panes[0] if len(candidate_panes) == 1 and not (terms_by_path.get(path) or {}).get(agent) else None
        if pane is None and len(candidate_panes) > 1:
            warnings.append(
                f"không gán activity cho worker {handle or worker_task_id(worker) or '?'} tại {path}: {len(candidate_panes)} pane cùng loại"
            )
        if pane is not None:
            consumed_panes.add(id(pane))
        activity = worker_activity(worker)
        times = worker_times(worker)
        tasks = list(links_by_handle.get(handle, [])) if isinstance(handle, str) else []
        task_id = worker_task_id(worker)
        if task_id:
            tasks.append((task_id, task_status.get(task_id)))
        if pane is not None:
            if isinstance(pane.get("state"), str) and pane.get("state"):
                activity.insert(0, f"pane:{pane['state']}")
            times.append(first(pane, "updatedAt", "updated_at"))
        add_row(
            origin="orchestration",
            agent=agent,
            path=path,
            info=info,
            feature_links=features_by_handle.get(handle, set()) if isinstance(handle, str) else set(),
            tasks=tasks,
            session=handle,
            activity_parts=activity,
            times=times,
        )
    labels = {}
    for row in rows:
        labels.setdefault((row["Repository"], row["Worktree"]), set()).add(row["_path"])
    for row in rows:
        if len(labels.get((row["Repository"], row["Worktree"]), ())) > 1 and row["_path"]:
            row["Worktree"] = row["_path"]
    rows.sort(key=lambda row: (
        0 if row["Origin"] == "orchestration" else 1,
        row["Repository"],
        row["Worktree"],
        row["Agent"],
        row["Session"],
    ))
    for row in rows:
        row.pop("_path", None)
    return rows, warnings

def collect_snapshot():
    warnings = []
    if shutil.which("orca") is None:
        return None, ["không tìm thấy lệnh orca"]
    ps_rows, ps_warnings, ps_ok = fetch_capped(["worktree", "ps"], ["worktrees"], ["path", "repo", "agents"])
    term_rows, term_warnings, term_ok = fetch_capped(["terminal", "list"], ["terminals"], ["handle", "worktreePath"])
    wt_rows, wt_warnings, _wt_ok = fetch_capped(["worktree", "list"], ["worktrees"], ["path", "repoId"])
    repo_data, repo_err = orca_json(["repo", "list"])
    repos, repo_note = ([], None)
    if repo_err:
        warnings.append(f"repo list: {repo_err}")
    else:
        repos, repo_note = find_rows(repo_data.get("result"), ["repos"], ["displayName", "path", "id"])
        if repo_note:
            warnings.append(f"repo list schema: {repo_note}")
    run_rows, run_pages, run_warnings, run_ok = fetch_named(
        ["orchestration", "run-list"], ["runs"], ["id", "objective"], PAGE_LIMIT
    )
    run_ids = []
    for run in run_rows:
        if isinstance(run, dict):
            run_id = first(run, "id", "runId", "run_id")
            if isinstance(run_id, str):
                run_ids.append(run_id)
    workers, worker_warnings = [], []
    unbound, unbound_pages, unbound_warnings, worker_ok = fetch_named(
        ["orchestration", "worker-list"], ["workers"], ["dispatchId", "taskId", "agentTerminalHandle"], PAGE_LIMIT
    )
    workers.extend(unbound)
    worker_warnings.extend(unbound_warnings)
    scoped_pages = unbound_pages
    for run_id in run_ids:
        scoped, pages, notes, scoped_ok = fetch_named(
            ["orchestration", "worker-list", "--run", run_id],
            ["workers"],
            ["dispatchId", "taskId", "agentTerminalHandle"],
            PAGE_LIMIT,
        )
        worker_ok = worker_ok or scoped_ok
        workers.extend(scoped)
        scoped_pages += pages
        worker_warnings.extend(notes)
    tasks = []
    task_warnings = []
    if not run_ids and not run_ok:
        task_warnings.append("task-list: run-list lỗi, không gọi task-list")
    elif not run_ids:
        task_warnings.append("task-list: không có Run id, không gọi task-list")
    for run_id in run_ids:
        data, err = orca_json(["orchestration", "task-list", "--run", run_id, "--brief"])
        if err:
            task_warnings.append(f"task-list {run_id}: {err}")
            continue
        result = data.get("result")
        got, note = find_rows(result, ["tasks"], ["id", "status", "task_title"])
        if note:
            task_warnings.append(f"task-list {run_id} schema: {note}")
        if isinstance(result, dict) and isinstance(result.get("count"), int) and result["count"] != len(got):
            task_warnings.append(f"task-list {run_id}: count={result['count']} nhưng nhận {len(got)} task")
        for task in got:
            if isinstance(task, dict):
                tasks.append(task)
    task_files, file_warnings = load_task_files(TASK_DIR)
    warnings.extend(ps_warnings + term_warnings + wt_warnings + run_warnings + worker_warnings + task_warnings + file_warnings)
    snapshot = {
        "ps": ps_rows,
        "terminals": term_rows,
        "worktrees": wt_rows,
        "repos": repos,
        "workers": workers,
        "runs": run_rows,
        "tasks": tasks,
        "task_files": task_files,
        "warnings": warnings,
        "stats": {
            "runs": len(run_ids),
            "run_pages": run_pages,
            "workers": len({worker_key(worker) for worker in workers if isinstance(worker, dict)}),
            "worker_pages": scoped_pages,
            "tasks": len(tasks),
            "terminals": len(term_rows),
            "worktree_ps": len(ps_rows),
        },
        "source_ok": ps_ok or term_ok or run_ok or worker_ok,
    }
    return snapshot, warnings

def render(rows, warnings, stats):
    now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    print(f"# agent-monitor {now}")
    print("# Origin orchestration = có trong worker-list; manual = không có. '-' = thiếu dữ liệu, không suy đoán.")
    if not rows:
        print("Không có agent Claude/Codex/Cursor trong dữ liệu đã đọc.")
    else:
        widths = {name: len(name) for name in COLUMNS}
        for row in rows:
            for name in COLUMNS:
                widths[name] = max(widths[name], len(cell(row.get(name))))
        print("  ".join(name.ljust(widths[name]) for name in COLUMNS))
        for row in rows:
            print("  ".join(cell(row.get(name)).ljust(widths[name]) for name in COLUMNS))
    print(f"# rows={len(rows)} orchestration={sum(1 for row in rows if row['Origin']=='orchestration')} manual={sum(1 for row in rows if row['Origin']=='manual')}")
    if stats:
        print(
            "# sources "
            + " ".join(f"{key}={value}" for key, value in stats.items())
        )
    if warnings:
        print("# warnings")
        for warning in warnings:
            print(f"- {warning}")
    else:
        print("# warnings: none")

def snapshot_ok(snapshot):
    return bool(snapshot.get("source_ok"))

def run_once():
    snapshot, warnings = collect_snapshot()
    if snapshot is None:
        for warning in warnings:
            print(f"- {warning}", file=sys.stderr)
        return 2
    rows, row_warnings = build_rows(snapshot)
    render(rows, row_warnings, snapshot.get("stats"))
    return 0 if snapshot_ok(snapshot) else 2

def run_watch(seconds):
    while True:
        started = time.monotonic()
        if sys.stdout.isatty():
            sys.stdout.write("\033[2J\033[H")
        code = run_once()
        sys.stdout.flush()
        if code == 2 and shutil.which("orca") is None:
            return 2
        remaining = seconds - (time.monotonic() - started)
        if remaining > 0:
            time.sleep(remaining)

def self_test():
    failures = []
    def check(name, cond):
        if not cond:
            failures.append(name)
    pages = [
        ([{"id": "run-a"}], "cursor-2", True, None),
        ([{"id": "run-b"}], None, False, None),
    ]
    def fetch(cursor):
        return pages[0] if cursor is None else pages[1]
    rows, page_count, errors = collect_pages(fetch)
    check("pages", [row["id"] for row in rows] == ["run-a", "run-b"] and page_count == 2 and not errors)
    repeated = [("cursor-1", True), ("cursor-1", True)]
    state = {"n": 0}
    def fetch_repeat(cursor):
        item = repeated[min(state["n"], 1)]
        state["n"] += 1
        return [{"id": state["n"]}], item[0], item[1], None
    _rows, _pages, repeat_errors = collect_pages(fetch_repeat)
    check("cursor-repeat", "nextCursor lặp" in repeat_errors)
    handle = "term_322b3f65-02db-41c6-a68d-12f66bf4d129"
    other = "term_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    snapshot = {
        "ps": [
            {
                "repo": "bidu-ai-backend",
                "path": "/wt/ai",
                "branch": "refs/heads/feat/translate-ai",
                "displayName": "feat-translate-ai",
                "agents": [
                    {"agentType": "claude", "state": "working", "updatedAt": 1792552592832},
                    {"agentType": "claude", "state": "done", "updatedAt": 1792552592832},
                    {"agentType": "cursor", "state": "done", "updatedAt": 1792552590000, "taskTitle": "T2 Hermes: tách code"},
                ],
            },
            {
                "repo": "bidu-hermes-agent",
                "path": "/wt/hermes",
                "branch": "refs/heads/feat/case9b-marketing-processing",
                "displayName": "case9b-marketing-processing",
                "agents": [{"agentType": "codex", "state": "done", "updatedAt": 1792552592832, "taskTitle": "không dùng khi đã có id"}],
            },
            {
                "repo": "Orca Manager",
                "path": "/wt/main",
                "branch": "refs/heads/main",
                "displayName": "main",
                "agents": [{"agentType": "claude", "state": "done", "updatedAt": 1792552500000}],
            },
        ],
        "terminals": [
            {"handle": "term_11111111-1111-1111-1111-111111111111", "agentIdentity": "claude", "worktreePath": "/wt/ai", "lastOutputAt": 1792552591000},
            {"handle": "term_22222222-2222-2222-2222-222222222222", "agentIdentity": "claude", "worktreePath": "/wt/ai", "connected": True},
            {"handle": "term_33333333-3333-3333-3333-333333333333", "agentIdentity": "cursor", "worktreePath": "/wt/ai", "lastOutputAt": 1792552592000},
            {"handle": handle, "agentIdentity": "codex", "worktreePath": "/wt/hermes", "lastOutputAt": 1792552592832},
            {"handle": other, "agentIdentity": "codex", "worktreePath": "/wt/main"},
            {"handle": "term_shell", "agentIdentity": None, "worktreePath": "/wt/ai"},
        ],
        "worktrees": [],
        "repos": [],
        "workers": [
            {
                "dispatchId": "ctx_1",
                "taskId": "task_76912f16db8b",
                "runId": "run_1",
                "workerState": "succeeded",
                "dispatchStatus": "completed",
                "agentTerminalHandle": handle,
                "projection": {
                    "provider": {"id": "codex"},
                    "stage": {"activity": "done", "worker": "succeeded", "dispatch": "completed"},
                    "liveness": {"observedAt": 1792552592832},
                    "workspace": {"id": "repo::/wt/hermes"},
                },
            },
            {
                "dispatchId": "ctx_1",
                "taskId": "task_76912f16db8b",
                "agentTerminalHandle": handle,
                "workerState": "succeeded",
            },
        ],
        "tasks": [{"id": "task_76912f16db8b", "status": "completed"}, {"id": "task_other", "status": "completed"}],
        "task_files": [
            {
                "file": "sample.md",
                "feature": "case9b-marketing-processing",
                "links": [{"token": "term_322b3f65", "task_id": "T2", "status": "REVIEW"}],
            },
            {
                "file": "ambiguous.md",
                "feature": "should-not-attach",
                "links": [{"token": "term_aaaaaaaa", "task_id": "T9", "status": "DONE"}],
            },
        ],
        "warnings": [],
    }
    # term_aaaaaaaa is a prefix of only `other` if no second match. Add a second handle so it is ambiguous.
    snapshot["terminals"].append({"handle": "term_aaaaaaaa-ffff-ffff-ffff-ffffffffffff", "agentIdentity": "claude", "worktreePath": "/nowhere"})
    built, warnings = build_rows(snapshot)
    by_session = {row["Session"]: row for row in built}
    claude_rows = [row for row in built if row["Repository"] == "bidu-ai-backend" and row["Agent"] == "claude"]
    check("ambiguous-activity", len(claude_rows) == 2 and all(row["Activity"] == "-" for row in claude_rows))
    check("ambiguous-warning", any("không gán activity" in item and "/wt/ai" in item for item in warnings))
    cursor = by_session["term_33333333-3333-3333-3333-333333333333"]
    check("unique-pane", cursor["Activity"] == "pane:done" and cursor["Origin"] == "manual" and cursor["Task"] == "-")
    check("ignore-pane-title", "T2 Hermes" not in cursor["Task"] and not cursor["Task"].startswith("title:"))
    check("cursor-feature", cursor["Feature"] == "translate-ai")
    worker_row = by_session[handle]
    check("origin", worker_row["Origin"] == "orchestration")
    check("task-explicit", "T2 (status=REVIEW)" in worker_row["Task"] and "task_76912f16db8b (status=completed)" in worker_row["Task"])
    check("task-not-title", "title:" not in worker_row["Task"] and "không dùng" not in worker_row["Task"])
    check("activity-labeled", worker_row["Activity"] == "pane:done activity:done worker:succeeded")
    check("not-dispatch-completed", "completed" not in worker_row["Activity"])
    check("dedupe-worker", sum(1 for row in built if row["Session"] == handle) == 1)
    main_claude = [row for row in built if row["Worktree"] == "main" and row["Agent"] == "claude"]
    check("main-no-feature", len(main_claude) == 1 and main_claude[0]["Feature"] == "-" and main_claude[0]["Origin"] == "manual")
    ambiguous_handles = [row for row in built if row["Task"].startswith("T9") or "should-not-attach" in row["Feature"]]
    check("ambiguous-prefix", not ambiguous_handles)
    shell_rows = [row for row in built if row["Session"] == "term_shell"]
    check("skip-shell", not shell_rows)
    missing = build_rows({"ps": [], "terminals": [], "worktrees": [], "repos": [], "workers": [], "tasks": [], "task_files": [], "warnings": []})
    check("empty", missing[0] == [])
    orphan = build_rows({
        "ps": [],
        "terminals": [],
        "worktrees": [],
        "repos": [{"id": "r1", "displayName": "bidu-hermes-agent"}],
        "workers": [{
            "dispatchId": "ctx_orphan",
            "taskId": "task_orphan",
            "workerState": "running",
            "resource": {"worktreeId": "r1::/wt/orphan", "terminalHandle": "term_orphan11-1111-1111-1111-111111111111"},
            "projection": {"provider": {"id": "codex"}, "workspace": {"id": "r1::/wt/orphan"}},
        }],
        "tasks": [],
        "task_files": [],
        "warnings": [],
    })
    check("orphan-worker", len(orphan[0]) == 1 and orphan[0][0]["Origin"] == "orchestration" and orphan[0][0]["Task"] == "task_orphan" and orphan[0][0]["Repository"] == "bidu-hermes-agent")
    check("orphan-no-fake-done", orphan[0][0]["Activity"] == "worker:running")
    short_ids = [item for item in INLINE_TASK_RE.findall("Task: T2-review | Terminal: term_322b3f65-02db-41c6-a68d-12f66bf4d129") if TASK_ID_RE.fullmatch(item)]
    check("no-short-task-id", short_ids == ["T2-review"])
    full_ids = [item for item in INLINE_TASK_RE.findall("Task: task_76912f16db8b Terminal: term_abc") if TASK_ID_RE.fullmatch(item)]
    check("inline-task-id", full_ids == ["task_76912f16db8b"])
    if failures:
        print("self-test failed: " + ", ".join(failures))
        return 1
    print("self-test ok")
    return 0

def main():
    mode, seconds = parse_args(ARGS)
    if mode == "self-test":
        raise SystemExit(self_test())
    if mode == "once":
        raise SystemExit(run_once())
    try:
        raise SystemExit(run_watch(seconds))
    except KeyboardInterrupt:
        raise SystemExit(0)

if __name__ == "__main__":
    main()
PY
