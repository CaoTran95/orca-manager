import json, os, re, shutil, subprocess, sys, time
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARGS = sys.argv[1:]
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
CLI_CALLS = 0
BUCKET_ORDER = {"WORKING": 0, "WAITING": 1, "INTERRUPTED": 2, "UNKNOWN": 3, "COMPLETED": 4}
ATTENTION = {"WORKING", "WAITING", "INTERRUPTED", "UNKNOWN"}
WORKING_TOKENS = {"working", "running"}
WAITING_TOKENS = {"waiting", "blocked", "stalled", "queued"}
COMPLETED_TOKENS = {"done", "succeeded", "completed", "complete", "success"}

def die(msg, code=2):
    print(msg, file=sys.stderr)
    raise SystemExit(code)

def usage():
    print(
        "scripts/agent-monitor.sh — dashboard read-only trong Terminal\n"
        "\n"
        "  scripts/agent-monitor.sh                 cập nhật dashboard mỗi 5 giây\n"
        "  scripts/agent-monitor.sh --once          một khung hình\n"
        "  scripts/agent-monitor.sh --watch 5       cập nhật mỗi 5 giây\n"
        "  scripts/agent-monitor.sh --all           cả session đã hoàn thành\n"
        "  scripts/agent-monitor.sh --feature KEY   lọc đúng feature key\n"
        "  scripts/agent-monitor.sh --detail        hiện session id ở chế độ chữ\n"
        "  scripts/agent-monitor.sh --json          dữ liệu có cấu trúc\n"
        "  scripts/agent-monitor.sh --html FILE     ghi trang HTML (một lần); thêm --watch 5 để ghi lại mỗi 5 giây\n"
        "  scripts/agent-monitor.sh --self-test\n"
        "\n"
        "Trong dashboard: / tìm, a tất cả session, s lọc trạng thái, esc xóa lọc, q thoát.\n"
        "Mặc định chỉ hiện session đang hoạt động hoặc cần chú ý.\n"
        "Chỉ đọc trạng thái. Không tạo/dừng agent, không sửa worktree hay task."
    )

def parse_args(argv):
    opts = {
        "mode": None,
        "seconds": 5,
        "all": False,
        "feature": None,
        "json": False,
        "html": None,
        "detail": False,
        "self_test": False,
    }
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in ("-h", "--help"):
            usage()
            raise SystemExit(0)
        if arg == "--once":
            if opts["mode"] == "watch":
                die("Chỉ chọn một: --once hoặc --watch.", 2)
            opts["mode"] = "once"
        elif arg == "--watch":
            if opts["mode"] == "once":
                die("Chỉ chọn một: --once hoặc --watch.", 2)
            index += 1
            if index >= len(argv):
                die("--watch cần số giây nguyên dương, ví dụ --watch 5", 2)
            try:
                seconds = int(argv[index])
            except ValueError:
                die("--watch cần số giây nguyên dương, ví dụ --watch 5", 2)
            if seconds <= 0:
                die("--watch cần số giây nguyên dương, ví dụ --watch 5", 2)
            opts["mode"] = "watch"
            opts["seconds"] = seconds
        elif arg == "--all":
            opts["all"] = True
        elif arg == "--detail":
            opts["detail"] = True
        elif arg == "--json":
            opts["json"] = True
        elif arg == "--html":
            index += 1
            if index >= len(argv) or not argv[index].strip() or argv[index].startswith("--"):
                die("--html cần đường dẫn file, ví dụ --html /tmp/monitor.html", 2)
            opts["html"] = os.path.abspath(os.path.expanduser(argv[index].strip()))
        elif arg == "--self-test":
            opts["self_test"] = True
        elif arg == "--feature":
            index += 1
            if index >= len(argv) or not argv[index].strip():
                die("--feature cần một feature key.", 2)
            opts["feature"] = argv[index].strip()
        elif arg.startswith("--feature=") and arg.split("=", 1)[1].strip():
            opts["feature"] = arg.split("=", 1)[1].strip()
        else:
            die(f"Không hiểu đối số: {arg}\nChạy scripts/agent-monitor.sh --help", 2)
        index += 1
    if opts["self_test"]:
        return opts
    if opts["html"] and opts["json"]:
        die("Chỉ chọn một: --json hoặc --html.", 2)
    if opts["mode"] is None:
        opts["mode"] = "once" if (opts["json"] or opts["html"]) else "watch"
    return opts

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
    global CLI_CALLS
    CLI_CALLS += 1
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
    meta = {"scope": None, "complete": True}

    def fetch(cursor):
        cmd = [*args, "--limit", str(limit)]
        if cursor:
            cmd.extend(["--cursor", cursor])
        data, err = orca_json(cmd)
        if err:
            meta["complete"] = False
            return [], None, False, err
        result = data.get("result")
        result_dict = result if isinstance(result, dict) else {}
        scope = result_dict.get("scope")
        if isinstance(scope, dict) and isinstance(scope.get("source"), str):
            meta["scope"] = scope.get("source")
        got, note = find_rows(result, names, hints)
        if note:
            warnings.append(f"{' '.join(args)} schema: {note}")
        nxt, more, _total = page_info(result_dict)
        if more and not nxt:
            meta["complete"] = False
        return got, nxt, more, None

    rows, pages, errors = collect_pages(fetch)
    for err in errors:
        warnings.append(f"{' '.join(args)}: {err}")
        meta["complete"] = False
    return rows, pages, warnings, (not errors or bool(rows)), meta

def extra_worker_runs(scope, complete, run_ids):
    if scope == "all" and complete:
        return []
    return [run_id for run_id in run_ids if isinstance(run_id, str)]

def task_run_ids(workers):
    found = []
    for worker in workers:
        if not isinstance(worker, dict):
            continue
        run_id = worker_run_id(worker)
        if isinstance(run_id, str) and run_id not in found:
            found.append(run_id)
    return found

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

    def terminal_status_of(terminal):
        if not isinstance(terminal, dict):
            return "UNKNOWN"
        connected = terminal.get("connected", terminal.get("isConnected"))
        if connected is True:
            return "CONNECTED"
        if connected is False:
            return "DISCONNECTED"
        return "UNKNOWN"

    def add_row(*, origin, agent, path, info, feature_links, tasks, session, activity_parts, times, terminal_status="UNKNOWN", worktree_label=None):
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
            "TerminalStatus": terminal_status or "UNKNOWN",
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
                    terminal_status=terminal_status_of(terminal),
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
    global CLI_CALLS
    CLI_CALLS = 0
    warnings = []
    if shutil.which("orca") is None:
        return None, ["không tìm thấy lệnh orca"]
    ps_rows, ps_warnings, ps_ok = fetch_capped(["worktree", "ps"], ["worktrees"], ["path", "repo", "agents"])
    term_rows, term_warnings, term_ok = fetch_capped(["terminal", "list"], ["terminals"], ["handle", "worktreePath"])
    run_rows, run_pages, run_warnings, run_ok, _run_meta = fetch_named(
        ["orchestration", "run-list"], ["runs"], ["id", "objective"], PAGE_LIMIT
    )
    run_ids = []
    for run in run_rows:
        if isinstance(run, dict):
            run_id = first(run, "id", "runId", "run_id")
            if isinstance(run_id, str):
                run_ids.append(run_id)
    unbound, unbound_pages, unbound_warnings, worker_ok, worker_meta = fetch_named(
        ["orchestration", "worker-list"], ["workers"], ["dispatchId", "taskId", "agentTerminalHandle"], PAGE_LIMIT
    )
    workers = list(unbound)
    worker_warnings = list(unbound_warnings)
    scoped_pages = unbound_pages
    extra_runs = extra_worker_runs(worker_meta.get("scope"), worker_meta.get("complete"), run_ids)
    for run_id in extra_runs:
        scoped, pages, notes, scoped_ok, _meta = fetch_named(
            ["orchestration", "worker-list", "--run", run_id],
            ["workers"],
            ["dispatchId", "taskId", "agentTerminalHandle"],
            PAGE_LIMIT,
        )
        worker_ok = worker_ok or scoped_ok
        workers.extend(scoped)
        scoped_pages += pages
        worker_warnings.extend(notes)
    ps_paths = {norm_path(first(row, "path")) for row in ps_rows if isinstance(row, dict)}
    ps_paths.discard(None)
    need_catalog = any(not worker_path(worker) or worker_path(worker) not in ps_paths for worker in workers if isinstance(worker, dict))
    wt_rows, wt_warnings, repos = [], [], []
    if need_catalog:
        wt_rows, wt_warnings, _wt_ok = fetch_capped(["worktree", "list"], ["worktrees"], ["path", "repoId"])
        repo_data, repo_err = orca_json(["repo", "list"])
        if repo_err:
            warnings.append(f"repo list: {repo_err}")
        else:
            repos, repo_note = find_rows(repo_data.get("result"), ["repos"], ["displayName", "path", "id"])
            if repo_note:
                warnings.append(f"repo list schema: {repo_note}")
    tasks = []
    task_warnings = []
    wanted_runs = task_run_ids(workers)
    if not run_ids and not run_ok:
        task_warnings.append("task-list: run-list lỗi, không gọi task-list")
    elif workers and not wanted_runs:
        task_warnings.append("task-list: worker không có Run id, không gọi task-list")
    for run_id in wanted_runs:
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
            "worker_scope": worker_meta.get("scope") or "-",
            "extra_worker_queries": len(extra_runs),
            "tasks": len(tasks),
            "terminals": len(term_rows),
            "worktree_ps": len(ps_rows),
            "cli_commands": CLI_CALLS,
        },
        "source_ok": ps_ok or term_ok or run_ok or worker_ok,
    }
    return snapshot, warnings

def bucket_of(token):
    if not isinstance(token, str):
        return "UNKNOWN"
    name = token.strip().casefold()
    if name in WORKING_TOKENS:
        return "WORKING"
    if name in WAITING_TOKENS:
        return "WAITING"
    if name in COMPLETED_TOKENS:
        return "COMPLETED"
    return "UNKNOWN"

def split_activity(activity):
    pane = activity_field = worker = None
    interrupted = False
    if isinstance(activity, str) and activity not in ("", "-"):
        for part in activity.split():
            if part == "interrupted":
                interrupted = True
            elif part.startswith("pane:"):
                pane = part.split(":", 1)[1]
            elif part.startswith("activity:"):
                activity_field = part.split(":", 1)[1]
            elif part.startswith("worker:"):
                worker = part.split(":", 1)[1]
    return pane, activity_field, worker, interrupted

def task_fields(task):
    if not isinstance(task, str) or task.strip() in ("", "-"):
        return "-", None
    statuses = re.findall(r"\(status=([^)]+)\)", task)
    ids = re.sub(r"\s*\(status=[^)]+\)", "", task).strip() or "-"
    status = ", ".join(dict.fromkeys(statuses)) if statuses else None
    return ids, status

def classify_row(row):
    pane, activity, worker, interrupted = split_activity(row.get("Activity"))
    if pane:
        agent_status = bucket_of(pane)
    elif activity:
        agent_status = bucket_of(activity)
    else:
        agent_status = "UNKNOWN"
    if agent_status == "WORKING":
        bucket = "WORKING"
    elif agent_status == "WAITING":
        bucket = "WAITING"
    elif interrupted:
        bucket = "INTERRUPTED"
    elif agent_status == "COMPLETED":
        bucket = "COMPLETED"
    else:
        bucket = "UNKNOWN"
    task_ids, task_status = task_fields(row.get("Task"))
    if task_ids != "-" and not task_status:
        task_status = "UNKNOWN"
    return {
        "origin": row.get("Origin") or "manual",
        "agent": cell(row.get("Agent")),
        "repository": cell(row.get("Repository")),
        "feature": cell(row.get("Feature")),
        "task": task_ids,
        "task_status": task_status,
        "worktree": cell(row.get("Worktree")),
        "agent_status": agent_status,
        "worker_status": worker.strip().upper() if isinstance(worker, str) and worker.strip() else None,
        "terminal_status": row.get("TerminalStatus") or "UNKNOWN",
        "interrupted": interrupted,
        "session": cell(row.get("Session")),
        "updated": cell(row.get("Updated")),
        "bucket": bucket,
    }

def classify_rows(rows):
    return [classify_row(row) for row in rows]

def feature_match(feature, key):
    if not key:
        return True
    wanted = key.strip().casefold()
    parts = [part.strip().casefold() for part in str(feature).split("|")]
    return wanted in parts

def visible_rows(rows, show_all, feature):
    _summary, shown = select_rows(rows, show_all=show_all, feature=feature or "", repo="", query="", status="")
    return shown

def select_rows(rows, show_all, feature, repo, query, status):
    matched = []
    needle = (query or "").strip().casefold()
    repo_needle = (repo or "").strip().casefold()
    for row in rows:
        if feature and not feature_match(row["feature"], feature):
            continue
        if repo_needle and repo_needle not in row["repository"].casefold():
            continue
        if needle:
            blob = " ".join((
                row["agent"], row["repository"], row["feature"], row["task"], row["worktree"], row["origin"],
            )).casefold()
            if needle not in blob:
                continue
        matched.append(row)
    summary = summarize(matched)
    if status:
        shown = [row for row in matched if row["bucket"] == status]
    elif show_all:
        shown = list(matched)
    else:
        shown = [row for row in matched if row["bucket"] in ATTENTION]
    return summary, sort_rows(shown)

def feature_task(row):
    feature = "" if row["feature"] in ("", "-") else row["feature"]
    task = "" if row["task"] in ("", "-") else row["task"]
    if feature and task:
        return f"{feature} · {task}"
    return feature or task or "-"

def activity_label(row):
    if row["bucket"] == "INTERRUPTED":
        return "INTERRUPTED"
    if row.get("interrupted") and row["bucket"] not in ("UNKNOWN", "INTERRUPTED"):
        return f"{row['bucket']} · int"
    return row["bucket"]

def column_plan(available):
    """Content widths whose rendered size (content + 2 padding) fits `available`."""
    available = max(1, int(available))
    if available < 88:
        specs = (
            ("agent", "Agent", 2),
            ("repo", "Repo", 3),
            ("feature", "Feature / Task", 4),
            ("activity", "Activity", 2),
        )
    else:
        specs = (
            ("kind", "Kind", 1),
            ("agent", "Agent", 2),
            ("repo", "Repo", 3),
            ("feature", "Feature / Task", 4),
            ("worktree", "Worktree", 3),
            ("activity", "Activity", 2),
        )
    pad = 2 * len(specs)
    budget = available - pad
    if budget < len(specs):
        budget = len(specs)
    flex = sum(item[2] for item in specs)
    widths = [max(1, (budget * item[2]) // flex) for item in specs]
    while sum(widths) > budget:
        index = max(range(len(widths)), key=lambda i: widths[i])
        if widths[index] <= 1:
            break
        widths[index] -= 1
    while sum(widths) < budget:
        index = max(range(len(widths)), key=lambda i: specs[i][2])
        widths[index] += 1
    return tuple((specs[i][0], specs[i][1], widths[i]) for i in range(len(specs)))

def summarize(rows):
    counts = {"WORKING": 0, "WAITING": 0, "COMPLETED": 0, "INTERRUPTED": 0, "UNKNOWN": 0}
    for row in rows:
        counts[row["bucket"]] = counts.get(row["bucket"], 0) + 1
    return {
        "total": len(rows),
        "working": counts["WORKING"],
        "waiting_blocked": counts["WAITING"],
        "completed": counts["COMPLETED"],
        "interrupted_unknown": counts["INTERRUPTED"] + counts["UNKNOWN"],
    }

def use_color(stream):
    if os.environ.get("NO_COLOR") or os.environ.get("TERM") == "dumb":
        return False
    return bool(stream.isatty())

def term_width():
    raw = os.environ.get("COLUMNS")
    if raw and raw.isdigit():
        return max(40, min(200, int(raw)))
    return max(40, min(200, shutil.get_terminal_size((100, 24)).columns))

def fit(text, width):
    text = "" if text is None else str(text).replace("\n", " ")
    if width <= 0:
        return ""
    if len(text) <= width:
        return text
    if width == 1:
        return "…"
    return text[:width - 1] + "…"

def paint(text, code, enabled):
    if not enabled or not code:
        return text
    return f"\033[{code}m{text}\033[0m"

def status_code(bucket):
    return {"WORKING": "32", "WAITING": "33", "COMPLETED": "36", "INTERRUPTED": "35"}.get(bucket, "2")

def column_sizes(width):
    agent_w = 8
    rest = max(0, width - agent_w - 4)
    each = rest // 4
    leftover = rest - each * 4
    return [agent_w, each, each, each, each + leftover]

def pad(text, width):
    clipped = fit(text, width)
    return clipped.ljust(width)

def status_text(row):
    parts = [f"agent {row['agent_status']}"]
    if row.get("worker_status"):
        parts.append(f"worker {row['worker_status']}")
    if row.get("task_status"):
        parts.append(f"task {row['task_status']}")
    elif row.get("task") not in (None, "-"):
        parts.append("task UNKNOWN")
    parts.append(f"term {row['terminal_status']}")
    if row.get("interrupted"):
        parts.append("interrupted")
    return "  ".join(parts)

def sort_rows(rows):
    return sorted(rows, key=lambda row: (
        BUCKET_ORDER.get(row["bucket"], 9),
        row["repository"],
        row["worktree"],
        row["agent"],
        row["session"],
    ))

def session_lines(row, width, detail, color):
    status = status_text(row)
    code = status_code(row["bucket"])
    if width >= 100:
        fields = (row["agent"], row["repository"], row["feature"], row["task"], row["worktree"])
        line = " ".join(pad(value, size) for value, size in zip(fields, column_sizes(width)))
        lines = [paint(fit(line, width), code, color)]
        lines.append(paint(fit("  " + status, width), code, color))
    else:
        lines = [
            paint(fit(f"{row['agent']}  {row['repository']}", width), code, color),
            fit(f"{row['feature']}  {row['worktree']}", width),
            paint(fit(f"task {row['task']}  {status}", width), code, color),
        ]
    if detail and row["session"] != "-":
        lines.append(fit(row["session"], width))
    return lines

def dashboard_lines(rows, warnings, stats, options, width, color):
    matched = [row for row in rows if feature_match(row["feature"], options.get("feature"))]
    shown = visible_rows(rows, options.get("all"), options.get("feature"))
    summary = summarize(matched)
    hidden = summary["completed"] if not options.get("all") else 0
    now = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    mode = "once" if options.get("mode") == "once" else f"watch {options.get('seconds', 5)}s"
    feature = options.get("feature") or "all"
    lines = [
        fit(f"Orca Agents  {now}  {mode}", width),
        fit(
            f"Sessions {summary['total']}   Working {summary['working']}   "
            f"Waiting/Blocked {summary['waiting_blocked']}   Completed {summary['completed']}   "
            f"Interrupted/Unknown {summary['interrupted_unknown']}",
            width,
        ),
        fit(
            f"feature {feature}   "
            + ("all sessions" if options.get("all") else f"attention only   {hidden} completed hidden (--all)"),
            width,
        ),
    ]
    grouped = {
        "orchestration": [row for row in shown if row["origin"] == "orchestration"],
        "manual": [row for row in shown if row["origin"] != "orchestration"],
    }
    titles = (("orchestration", "ORCHESTRATION WORKERS"), ("manual", "MANUAL SESSIONS"))
    for key, title in titles:
        group = sort_rows(grouped[key])
        lines.append(fit(f"{title}  {len(group)}", width))
        if not group:
            lines.append(fit("  không có session trong bộ lọc này", width))
            continue
        if width >= 100:
            labels = ("Agent", "Repository", "Feature", "Task", "Worktree")
            lines.append(fit(" ".join(pad(label, size) for label, size in zip(labels, column_sizes(width))), width))
        else:
            lines.append(fit("Agent  Repository", width))
        for row in group:
            lines.extend(session_lines(row, width, options.get("detail"), color))
    if warnings:
        lines.append(fit(f"Warnings {len(warnings)}", width))
        for warning in warnings[:3]:
            lines.append(fit(f"- {warning}", width))
        if len(warnings) > 3:
            lines.append(fit(f"- … {len(warnings) - 3} cảnh báo nữa", width))
    if stats:
        lines.append(fit(
            "sources "
            + " ".join(f"{key}={value}" for key, value in stats.items()),
            width,
        ))
    return [fit(line, width) if "\033" not in line else line for line in lines], summary, shown

def plain_len(text):
    return len(re.sub(r"\033\[[0-9;]*m", "", text))

def json_payload(rows, warnings, stats, options):
    matched = [row for row in rows if feature_match(row["feature"], options.get("feature"))]
    shown = visible_rows(rows, options.get("all"), options.get("feature"))
    summary = summarize(matched)
    summary["shown"] = len(shown)

    def public(row):
        item = dict(row)
        item.pop("interrupted", None)
        return item

    return {
        "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "summary": summary,
        "orchestration": [public(row) for row in sort_rows(shown) if row["origin"] == "orchestration"],
        "manual": [public(row) for row in sort_rows(shown) if row["origin"] != "orchestration"],
        "warnings": warnings,
        "sources": stats or {},
    }

def emit_text(lines, clear):
    if clear:
        sys.stdout.write("\033[H\033[2J")
    sys.stdout.write("\n".join(lines) + "\n")
    sys.stdout.flush()

def snapshot_ok(snapshot):
    return bool(snapshot.get("source_ok"))

def load_view():
    snapshot, warnings = collect_snapshot()
    if snapshot is None:
        return None, warnings, [], {}
    rows, row_warnings = build_rows(snapshot)
    return snapshot, row_warnings, classify_rows(rows), snapshot.get("stats") or {}

def write_html(options, rows, warnings, stats, refresh):
    """Ghi trang HTML tĩnh (nguyên tử: file tạm rồi os.replace). Luôn gồm mọi session; trang tự lọc."""
    from monitor_html import render_html, render_data_js
    opts = dict(options, all=True)
    payload = json_payload(rows, warnings, stats, opts)
    path = options["html"]
    data_path = os.path.splitext(path)[0] + ".data.js"
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    for target, text in ((data_path, render_data_js(payload)), (path, render_html(payload, refresh, os.path.basename(data_path)))):
        tmp = f"{target}.tmp{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, target)

def run_once(options):
    snapshot, warnings, rows, stats = load_view()
    if snapshot is None:
        for warning in warnings:
            print(f"- {warning}", file=sys.stderr)
        return 2
    if options.get("html"):
        write_html(options, rows, warnings, stats, 0)
        print(f"Đã ghi {options['html']}")
        return 0 if snapshot_ok(snapshot) else 2
    if options.get("json"):
        print(json.dumps(json_payload(rows, warnings, stats, options), ensure_ascii=False, indent=2))
        return 0 if snapshot_ok(snapshot) else 2
    if not render_rich_once(rows, warnings, stats, options):
        color = use_color(sys.stdout)
        lines, _summary, _shown = dashboard_lines(rows, warnings, stats, options, term_width(), color)
        emit_text(lines, clear=False)
    return 0 if snapshot_ok(snapshot) else 2

def run_watch_html(options):
    print(f"Đang ghi {options['html']} mỗi {options['seconds']}s (trang tự tải lại). Ctrl+C để dừng.", file=sys.stderr)
    try:
        while True:
            started = time.monotonic()
            snapshot, warnings, rows, stats = load_view()
            if snapshot is None:
                for warning in warnings:
                    print(f"- {warning}", file=sys.stderr)
                if shutil.which("orca") is None:
                    return 2
            else:
                write_html(options, rows, warnings, stats, options["seconds"])
            remaining = options["seconds"] - (time.monotonic() - started)
            if remaining > 0:
                time.sleep(remaining)
    except KeyboardInterrupt:
        return 0

def run_watch(options):
    if options.get("html"):
        return run_watch_html(options)
    interactive = sys.stdout.isatty() and not options.get("json") and TEXTUAL
    if interactive:
        AgentMonitorApp(options).run()
        return 0
    tty = sys.stdout.isatty() and not options.get("json")
    if tty and not TEXTUAL:
        print("Textual chưa được cài. Đang dùng bản chữ. Cài: python3.11 -m pip install textual", file=sys.stderr)
    if tty:
        sys.stdout.write("\033[?1049h\033[?25l")
        sys.stdout.flush()
    try:
        while True:
            started = time.monotonic()
            snapshot, warnings, rows, stats = load_view()
            if snapshot is None:
                for warning in warnings:
                    print(f"- {warning}", file=sys.stderr)
                if shutil.which("orca") is None:
                    return 2
            elif options.get("json"):
                print(json.dumps(json_payload(rows, warnings, stats, options), ensure_ascii=False), flush=True)
            else:
                color = use_color(sys.stdout)
                lines, _summary, _shown = dashboard_lines(rows, warnings, stats, options, term_width(), color)
                emit_text(lines, clear=tty)
            remaining = options["seconds"] - (time.monotonic() - started)
            if remaining > 0:
                time.sleep(remaining)
    except KeyboardInterrupt:
        return 0
    finally:
        if tty:
            sys.stdout.write("\033[?25h\033[?1049l")
            sys.stdout.flush()

def render(rows, warnings, stats):
    options = {"mode": "once", "seconds": 5, "all": True, "feature": None, "detail": True, "json": False}
    lines, _summary, _shown = dashboard_lines(classify_rows(rows), warnings, stats, options, term_width(), False)
    emit_text(lines, clear=False)


ACTIVITY_STYLE = {
    "WORKING": "bold #3fb950",
    "WAITING": "bold #d29922",
    "COMPLETED": "#6cb6ff",
    "INTERRUPTED": "bold #bc8cff",
    "UNKNOWN": "#8b98a8",
}
STATUS_CYCLE = ["", "WORKING", "WAITING", "INTERRUPTED", "UNKNOWN", "COMPLETED"]

def cell_values(row):
    task_line = row["task_status"] or ("UNKNOWN" if row["task"] not in ("", "-") else "—")
    return {
        "kind": "orch" if row["origin"] == "orchestration" else "manual",
        "agent": row["agent"],
        "repo": row["repository"],
        "feature": feature_task(row),
        "worktree": row["worktree"],
        "activity": activity_label(row),
        "task_line": task_line,
    }

def detail_plain(row):
    if not row:
        return "Chọn một session. Activity, Terminal và Task là ba trạng thái riêng."
    values = cell_values(row)
    task = row["task"] if row["task"] not in ("", "-") else "—"
    task_status = values["task_line"] if task != "—" else "—"
    return "\n".join((
        f"{row['agent']}   {row['repository']}   {row['origin']}",
        f"Activity {values['activity']}    Terminal {row['terminal_status']}",
        f"Task {task}  {task_status}    Worker {row['worker_status'] or '—'}",
        f"Feature {row['feature']}    Worktree {row['worktree']}",
        f"Session {row['session']}    Updated {row['updated']}",
    ))

def diagnostics_plain(warnings):
    if not warnings:
        return "Diagnostics  clear"
    lines = ["Diagnostics"]
    for item in warnings[:6]:
        lines.append(f"• {item}")
    if len(warnings) > 6:
        lines.append(f"• … {len(warnings) - 6} more")
    return "\n".join(lines)

def render_rich_once(rows, warnings, stats, options):
    try:
        from rich.console import Console
        from rich.panel import Panel
        from rich.table import Table
        from rich.text import Text
    except ImportError:
        return False
    width = term_width()
    console = Console(width=width, force_terminal=use_color(sys.stdout), no_color=not use_color(sys.stdout))
    summary, shown = select_rows(
        rows,
        show_all=bool(options.get("all")),
        feature=options.get("feature") or "",
        repo="",
        query="",
        status="",
    )
    cards = "   ".join((
        f"Sessions {summary['total']}",
        f"Working {summary['working']}",
        f"Waiting {summary['waiting_blocked']}",
        f"Completed {summary['completed']}",
        f"Interrupted/Unknown {summary['interrupted_unknown']}",
    ))
    mode = "all sessions" if options.get("all") else f"attention · {summary['completed']} completed hidden"
    console.print(Panel(f"{cards}\n{mode}", title="Orca Agents", border_style="#243041"))
    table = Table(expand=True, header_style="bold #8b98a8", border_style="#243041", pad_edge=False)
    plan = column_plan(width)
    for _key, label, col_width in plan:
        table.add_column(label, no_wrap=True, overflow="ellipsis", max_width=col_width, min_width=1)
    for row in shown:
        values = cell_values(row)
        cells = []
        for key, _label, _col_width in plan:
            if key == "activity":
                cells.append(Text(values["activity"], style=ACTIVITY_STYLE.get(row["bucket"], "#8b98a8")))
            else:
                cells.append(values[key])
        table.add_row(*cells)
    console.print(table)
    focus = shown[0] if shown else None
    console.print(Panel(detail_plain(focus), title="Detail", border_style="#243041"))
    border = "#9e6a03" if warnings else "#243041"
    console.print(Panel(diagnostics_plain(warnings), title="Diagnostics", border_style=border))
    if stats:
        console.print(f"[dim]sources {' '.join(f'{key}={value}' for key, value in stats.items())}[/dim]" if use_color(sys.stdout) else "sources " + " ".join(f"{key}={value}" for key, value in stats.items()))
    return True

try:
    from textual.app import App, ComposeResult
    from textual.binding import Binding
    from textual.containers import Horizontal
    from textual.widgets import Button, DataTable, Footer, Input, Static
    from rich.text import Text
    TEXTUAL = True
except ImportError:
    TEXTUAL = False

if TEXTUAL:
    class AgentMonitorApp(App):
        TITLE = "Orca Agents"
        CSS = """
        Screen { background: #0b0f14; color: #d7dee8; }
        #title { height: 1; padding: 0 1; background: #12181f; color: #e6edf3; text-style: bold; }
        #cards { height: 3; padding: 0 1; }
        .card { width: 1fr; height: 3; margin: 0 1 0 0; padding: 0 1; background: #12181f; border: round #243041; content-align: center middle; }
        .card-working { border: round #2ea043; }
        .card-waiting { border: round #9e6a03; }
        .card-completed { border: round #1f6feb; }
        .card-unknown { border: round #6e7681; }
        #filters { height: 3; padding: 0 1; }
        #filters Input { width: 1fr; margin: 0 1 0 0; }
        #status-btn { width: 22; }
        #agents { height: 1fr; margin: 0 1; background: #0b0f14; }
        #detail { height: 8; margin: 0 1; padding: 0 1; background: #12181f; border: round #243041; }
        #diagnostics { height: 4; margin: 0 1 1 1; padding: 0 1; background: #1c1408; color: #e3b341; border: round #9e6a03; }
        #diagnostics.clear { background: #12181f; color: #8b98a8; border: round #243041; }
        DataTable { background: #0b0f14; }
        DataTable > .datatable--header { background: #161b22; color: #8b98a8; text-style: bold; }
        DataTable > .datatable--cursor { background: #1f3a5f; }
        """
        BINDINGS = [
            Binding("slash", "search", "Search"),
            Binding("a", "toggle_all", "All"),
            Binding("s", "cycle_status", "Status"),
            Binding("escape", "back", "Back"),
            Binding("q", "quit", "Quit"),
        ]

        def __init__(self, options, preload=None):
            super().__init__()
            self.options = options
            self.live = preload is None
            self.rows = list((preload or {}).get("rows") or [])
            self.warnings = list((preload or {}).get("warnings") or [])
            self.stats = dict((preload or {}).get("stats") or {})
            self.show_all = bool(options.get("all"))
            self.feature = options.get("feature") or ""
            self.repo = ""
            self.search_text = ""
            self.status_filter = ""
            self._plan = None
            self._shown = []
            self.diagnostics_plain = ""

        def compose(self) -> ComposeResult:
            yield Static("Orca Agents", id="title")
            yield Horizontal(
                Static("", id="card-total", classes="card"),
                Static("", id="card-working", classes="card card-working"),
                Static("", id="card-waiting", classes="card card-waiting"),
                Static("", id="card-completed", classes="card card-completed"),
                Static("", id="card-unknown", classes="card card-unknown"),
                id="cards",
            )
            yield Horizontal(
                Input(placeholder="Search", id="search"),
                Input(placeholder="Repo", id="repo"),
                Input(placeholder="Feature", id="feature", value=self.feature),
                Button(self._status_name(), id="status-btn"),
                id="filters",
            )
            yield DataTable(id="agents", cursor_type="row", zebra_stripes=True)
            yield Static("", id="detail")
            yield Static("", id="diagnostics")
            yield Footer()

        def on_mount(self) -> None:
            self.theme = "textual-dark"
            self.query_one("#agents", DataTable).focus()
            self.call_after_refresh(self._paint)
            if self.live:
                self.set_interval(self.options.get("seconds") or 5, self._kick)
                self._kick()

        def on_resize(self, event) -> None:
            if not self.query("#detail"):
                return
            height = event.size.height
            self.query_one("#detail").styles.height = 8 if height >= 32 else 5
            self.query_one("#diagnostics").styles.height = 4 if height >= 32 else 3
            self.call_after_refresh(self._paint)

        def _status_name(self) -> str:
            if self.status_filter:
                return self.status_filter
            return "all" if self.show_all else "attention"

        def _kick(self) -> None:
            self.run_worker(self._fetch, thread=True, exclusive=True, name="refresh")

        def _fetch(self) -> None:
            snapshot, warnings, rows, stats = load_view()
            self.call_from_thread(self._apply, snapshot, warnings, rows, stats)

        def _apply(self, snapshot, warnings, rows, stats) -> None:
            if snapshot is None:
                self.warnings = warnings or ["không đọc được Orca"]
            else:
                self.rows = rows
                self.warnings = warnings
                self.stats = stats
            if self.is_mounted:
                self._paint()

        def on_input_changed(self, event: Input.Changed) -> None:
            if event.input.id == "search":
                self.search_text = event.value
            elif event.input.id == "repo":
                self.repo = event.value.strip()
            elif event.input.id == "feature":
                self.feature = event.value.strip()
            if self.is_mounted:
                self._paint()

        def on_button_pressed(self, event: Button.Pressed) -> None:
            if event.button.id == "status-btn":
                self.action_cycle_status()

        def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
            self._update_detail()

        def action_search(self) -> None:
            self.query_one("#search", Input).focus()

        def action_toggle_all(self) -> None:
            self.show_all = not self.show_all
            self.status_filter = ""
            self._paint()

        def action_cycle_status(self) -> None:
            index = STATUS_CYCLE.index(self.status_filter) if self.status_filter in STATUS_CYCLE else 0
            self.status_filter = STATUS_CYCLE[(index + 1) % len(STATUS_CYCLE)]
            self._paint()

        def action_back(self) -> None:
            focused = self.focused
            if isinstance(focused, Input):
                focused.value = ""
                self.query_one("#agents", DataTable).focus()
                return
            self.search_text = ""
            self.repo = ""
            self.feature = self.options.get("feature") or ""
            self.status_filter = ""
            self.query_one("#search", Input).value = ""
            self.query_one("#repo", Input).value = ""
            self.query_one("#feature", Input).value = self.feature
            self._paint()

        def _ensure_columns(self, available=None) -> None:
            table = self.query_one("#agents", DataTable)
            if available is None:
                available = table.size.width or self.size.width or 80
            plan = column_plan(available)
            if plan == self._plan:
                return
            self._plan = plan
            table.clear(columns=True)
            for key, label, col_width in plan:
                table.add_column(label, key=key, width=col_width)

        def _fill_table(self, shown) -> None:
            table = self.query_one("#agents", DataTable)
            previous = None
            if self._shown and table.cursor_row is not None and table.cursor_row < len(self._shown):
                previous = self._shown[table.cursor_row].get("session")
            self._shown = shown
            table.clear()
            for index, row in enumerate(shown):
                key = row["session"] if row["session"] != "-" else f"row-{index}-{row['repository']}-{row['agent']}"
                table.add_row(*self._cells(row), key=key)
            if not shown:
                return
            target = 0
            if previous and previous != "-":
                for index, row in enumerate(shown):
                    if row["session"] == previous:
                        target = index
                        break
            table.move_cursor(row=target)

        def _cells(self, row):
            values = cell_values(row)
            cells = []
            for key, _label, _width in self._plan:
                if key == "activity":
                    cells.append(Text(values["activity"], style=ACTIVITY_STYLE.get(row["bucket"], "#8b98a8"), no_wrap=True, overflow="ellipsis"))
                else:
                    cells.append(Text(str(values[key]), no_wrap=True, overflow="ellipsis"))
            return cells

        def _paint(self) -> None:
            if not self.is_mounted or not self.query("#agents"):
                return
            summary, shown = select_rows(
                self.rows,
                show_all=self.show_all,
                feature=self.feature,
                repo=self.repo,
                query=self.search_text,
                status=self.status_filter,
            )
            table = self.query_one("#agents", DataTable)
            width = table.size.width or self.size.width or 80
            height = table.size.height
            thickness = int(getattr(table.styles, "scrollbar_size_vertical", 0) or 0)
            gutter = thickness if height and (1 + len(shown)) > height else 0
            self._ensure_columns(max(1, width - gutter))
            self._fill_table(shown)
            self._update_cards(summary)
            self.query_one("#status-btn", Button).label = self._status_name()
            self._update_detail()
            self._update_diag()
            now = datetime.now().astimezone().strftime("%H:%M:%S")
            hidden = "" if self.show_all or self.status_filter else f"  ·  {summary['completed']} completed hidden"
            self.query_one("#title", Static).update(
                f"Orca Agents    read-only · {self.options.get('seconds') or 5}s · {now}{hidden}"
            )

        def _update_cards(self, summary) -> None:
            pairs = (
                ("card-total", summary["total"], "Sessions"),
                ("card-working", summary["working"], "Working"),
                ("card-waiting", summary["waiting_blocked"], "Waiting"),
                ("card-completed", summary["completed"], "Completed"),
                ("card-unknown", summary["interrupted_unknown"], "Unknown"),
            )
            for ident, value, label in pairs:
                self.query_one(f"#{ident}", Static).update(f"[b]{value}[/]\n[dim]{label}[/]")

        def _current(self):
            table = self.query_one("#agents", DataTable)
            if not self._shown:
                return None
            index = table.cursor_row or 0
            if index >= len(self._shown):
                index = 0
            return self._shown[index]

        def _update_detail(self) -> None:
            self.query_one("#detail", Static).update(detail_plain(self._current()))

        def _update_diag(self) -> None:
            text = diagnostics_plain(self.warnings)
            self.diagnostics_plain = text
            widget = self.query_one("#diagnostics", Static)
            widget.update(text)
            widget.set_class(not self.warnings, "clear")


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
    classified = classify_rows(built)
    by_class = {row["session"]: row for row in classified}
    ambiguous = [row for row in classified if row["repository"] == "bidu-ai-backend" and row["agent"] == "claude"]
    check("term-not-working", len(ambiguous) == 2 and all(row["agent_status"] == "UNKNOWN" and row["bucket"] == "UNKNOWN" for row in ambiguous))
    check("connected-not-agent", any(row["terminal_status"] == "CONNECTED" and row["agent_status"] == "UNKNOWN" for row in ambiguous))
    check("cursor-completed", by_class["term_33333333-3333-3333-3333-333333333333"]["bucket"] == "COMPLETED")
    worker_view = by_class[handle]
    check("worker-split", worker_view["agent_status"] == "COMPLETED" and worker_view["worker_status"] == "SUCCEEDED" and "REVIEW" in worker_view["task_status"] and "completed" in worker_view["task_status"])
    attention = visible_rows(classified, False, None)
    check("default-hides-completed", attention and all(row["bucket"] != "COMPLETED" for row in attention))
    check("all-shows-completed", any(row["bucket"] == "COMPLETED" for row in visible_rows(classified, True, None)))
    filtered = visible_rows(classified, True, "translate-ai")
    check("feature-filter", filtered and all(row["feature"] == "translate-ai" for row in filtered))
    unknown = classify_row({
        "Origin": "orchestration", "Agent": "codex", "Repository": "r", "Worktree": "w", "Feature": "-",
        "Task": "task_x", "Session": "term_hidden", "Activity": "activity:unknown worker:succeeded",
        "Updated": "-", "TerminalStatus": "CONNECTED",
    })
    check("unknown-not-done", unknown["agent_status"] == "UNKNOWN" and unknown["bucket"] == "UNKNOWN" and unknown["worker_status"] == "SUCCEEDED")
    running = classify_row({
        "Origin": "orchestration", "Agent": "codex", "Repository": "r", "Worktree": "w", "Feature": "-",
        "Task": "task_x", "Session": "term_run", "Activity": "activity:unknown worker:running",
        "Updated": "-", "TerminalStatus": "CONNECTED",
    })
    check("worker-running-not-working", running["agent_status"] == "UNKNOWN" and running["bucket"] == "UNKNOWN" and running["worker_status"] == "RUNNING")
    stopped = classify_row({
        "Origin": "manual", "Agent": "claude", "Repository": "r", "Worktree": "w", "Feature": "-",
        "Task": "-", "Session": "term_stop", "Activity": "interrupted worker:running",
        "Updated": "-", "TerminalStatus": "CONNECTED",
    })
    check("interrupted-not-working", stopped["bucket"] == "INTERRUPTED" and stopped["agent_status"] == "UNKNOWN")
    only_term = classify_row({
        "Origin": "manual", "Agent": "claude", "Repository": "r", "Worktree": "w", "Feature": "-",
        "Task": "-", "Session": "term_only", "Activity": "-", "Updated": "-", "TerminalStatus": "CONNECTED",
    })
    check("terminal-not-running", only_term["agent_status"] == "UNKNOWN" and only_term["bucket"] == "UNKNOWN")
    check("no-extra-worker-query", extra_worker_runs("all", True, ["run_a", "run_b"]) == [])
    check("bound-worker-query", extra_worker_runs("bound", True, ["run_a"]) == ["run_a"])
    options = {"mode": "once", "seconds": 5, "all": False, "feature": None, "detail": False, "json": False}
    narrow, _summary, _shown = dashboard_lines(classified, [], {}, options, 60, False)
    wide, _summary, _shown = dashboard_lines(classified, [], {}, {**options, "all": True, "detail": True}, 140, False)
    check("narrow-fit", narrow and all(plain_len(line) <= 60 for line in narrow))
    check("wide-fit", wide and all(plain_len(line) <= 140 for line in wide))
    check("session-hidden", all(handle not in line for line in narrow))
    check("session-detail", any(handle in line for line in wide))
    check("parse-default", parse_args([])["mode"] == "watch" and parse_args([])["seconds"] == 5)
    parsed = parse_args(["--once", "--all", "--feature", "translate-ai", "--detail", "--json"])
    check("parse-flags", parsed["mode"] == "once" and parsed["all"] and parsed["feature"] == "translate-ai" and parsed["detail"] and parsed["json"])
    repo_summary, repo_rows = select_rows(classified, True, "", "bidu-ai-backend", "", "")
    check("repo-filter", repo_rows and all(row["repository"] == "bidu-ai-backend" for row in repo_rows))
    _query_summary, query_rows = select_rows(classified, True, "", "", "cursor", "")
    check("search-filter", query_rows and all("cursor" in row["agent"] for row in query_rows))
    status_summary, status_rows = select_rows(classified, False, "", "", "", "COMPLETED")
    check("status-filter", status_rows and all(row["bucket"] == "COMPLETED" for row in status_rows) and status_summary["working"] >= 0)
    check("unknown-style", ACTIVITY_STYLE["UNKNOWN"] != ACTIVITY_STYLE["WORKING"])
    sample = classify_rows([
        {"Origin": "orchestration", "Agent": "codex", "Repository": "bidu-hermes-agent", "Worktree": "feat-case9b", "Feature": "case9b-marketing-processing", "Task": "T2 (status=REVIEW)", "Session": handle, "Activity": "pane:working", "Updated": "10:00", "TerminalStatus": "CONNECTED"},
        {"Origin": "manual", "Agent": "claude", "Repository": "bidu-ai-backend", "Worktree": "feat-translate-ai", "Feature": "translate-ai", "Task": "-", "Session": "term_done", "Activity": "pane:done", "Updated": "09:00", "TerminalStatus": "DISCONNECTED"},
        {"Origin": "manual", "Agent": "cursor", "Repository": "orca", "Worktree": "main", "Feature": "-", "Task": "-", "Session": "term_unk", "Activity": "-", "Updated": "-", "TerminalStatus": "CONNECTED"},
        {"Origin": "manual", "Agent": "claude", "Repository": "orca", "Worktree": "feat-x", "Feature": "feat-x", "Task": "-", "Session": "term_int", "Activity": "interrupted", "Updated": "-", "TerminalStatus": "UNKNOWN"},
    ])
    import io
    saved_out, saved_columns, saved_nocolor = sys.stdout, os.environ.get("COLUMNS"), os.environ.get("NO_COLOR")
    try:
        os.environ["NO_COLOR"] = "1"
        rendered = {}
        for width in ("60", "40"):
            os.environ["COLUMNS"] = width
            buffer = io.StringIO()
            sys.stdout = buffer
            rendered[width] = (render_rich_once(sample, ["không gán activity cho /wt/ai (claude)"], {"cli_commands": 5}, options), buffer.getvalue())
    finally:
        sys.stdout = saved_out
        if saved_columns is None:
            os.environ.pop("COLUMNS", None)
        else:
            os.environ["COLUMNS"] = saved_columns
        if saved_nocolor is None:
            os.environ.pop("NO_COLOR", None)
        else:
            os.environ["NO_COLOR"] = saved_nocolor
    rendered60, snapshot_text = rendered["60"]
    rendered40, narrow_text = rendered["40"]
    check("rich-once", rendered60 and "Diagnostics" in snapshot_text and "không gán activity" in snapshot_text)
    check("rich-narrow", snapshot_text and all(len(line) <= 60 for line in snapshot_text.splitlines()))
    check("rich-40", rendered40 and narrow_text and all(len(line) <= 40 for line in narrow_text.splitlines()))
    check("rich-hides-completed", "COMPLETED" not in snapshot_text)
    if TEXTUAL:
        import asyncio

        async def tui_smoke(size, show_all):
            app = AgentMonitorApp(
                {"seconds": 5, "all": show_all, "feature": None},
                preload={"rows": sample, "warnings": ["không gán activity cho /wt/ai (claude)"], "stats": {}},
            )
            async with app.run_test(size=size) as pilot:
                await pilot.pause()
                table = app.query_one("#agents", DataTable)
                texts = []
                for row in table.ordered_rows:
                    texts.append(" ".join(str(table.get_cell(row.key, col.key)) for col in table.ordered_columns))
                width_sum = sum(column.get_render_width(table) for column in table.ordered_columns)
                return table.row_count, texts, app.diagnostics_plain, width_sum, table.size.width, table.max_scroll_x

        narrow_count, narrow_text, narrow_diag, narrow_sum, narrow_width, narrow_scroll = asyncio.run(tui_smoke((60, 20), False))
        check("tui-attention", narrow_count == 3)
        check("tui-warning-separated", "không gán activity" in narrow_diag and all("không gán activity" not in line for line in narrow_text))
        check("tui-unknown-not-working", any("UNKNOWN" in line and "WORKING" not in line for line in narrow_text))
        check("tui-narrow-fit", narrow_width > 0 and narrow_sum <= narrow_width and narrow_scroll == 0)
        wide_count, wide_text, _diag, wide_sum, wide_width, wide_scroll = asyncio.run(tui_smoke((120, 30), False))
        check("tui-wide-fit", wide_width > 0 and wide_sum <= wide_width and wide_scroll == 0 and wide_count == 3)
        _tiny_count, _tiny_text, _tiny_diag, _tiny_sum, tiny_width, tiny_scroll = asyncio.run(tui_smoke((24, 10), False))
        check("tui-tiny-fit", tiny_width > 0 and tiny_scroll == 0)
        check("tui-kind", any(line.startswith("orch") or line.startswith("manual") for line in wide_text))

        async def tui_keys():
            app = AgentMonitorApp(
                {"seconds": 5, "all": False, "feature": None},
                preload={"rows": sample, "warnings": [], "stats": {}},
            )
            async with app.run_test(size=(80, 24)) as pilot:
                await pilot.pause()
                table = app.query_one("#agents", DataTable)
                await pilot.press("a")
                await pilot.pause()
                shown_all = table.row_count
                await pilot.press("s", "s", "s", "s", "s")
                await pilot.pause()
                completed = table.row_count
                status_label = str(app.query_one("#status-btn", Button).label)
                await pilot.press("escape")
                await pilot.pause()
                app.query_one("#repo", Input).focus()
                await pilot.pause()
                for char in "hermes":
                    await pilot.press(char)
                await pilot.pause()
                return shown_all, completed, table.row_count, status_label

        shown_all, completed_count, repo_count, status_label = asyncio.run(tui_keys())
        check("tui-all", shown_all == 4)
        check("tui-status", completed_count == 1 and status_label == "COMPLETED")
        check("tui-repo", repo_count == 1)
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from monitor_html import render_html
        sample = {"generated_at": "2026-01-01T00:00:00+00:00", "summary": {"total": 1}, "sources": {}, "warnings": ["</script><b>x"],
                  "orchestration": [{"origin": "orchestration", "agent": "codex", "repository": "r", "feature": "f", "task": "T1",
                                     "bucket": "WORKING", "session": "term_1"}], "manual": []}
        page = render_html(sample, 5)
        from monitor_html import render_data_js
        check("html-render", "Agent Monitor" in page and "term_1" in page and 'REFRESH=5' in page and 'REFRESH=0' in render_html(sample, 0))
        check("html-escape", "</script><b>x" not in page.split('id="data">', 1)[1].split("</script>", 1)[0])
        check("html-data-js", render_data_js(sample).startswith("window.__AGENT_MONITOR_DATA = {"))
    except Exception:
        check("html-render", False)
    if failures:
        print("self-test failed: " + ", ".join(failures))
        return 1
    print("self-test ok")
    return 0

def main():
    options = parse_args(ARGS)
    if options["self_test"]:
        raise SystemExit(self_test())
    if options["mode"] == "once":
        raise SystemExit(run_once(options))
    raise SystemExit(run_watch(options))

if __name__ == "__main__":
    main()
