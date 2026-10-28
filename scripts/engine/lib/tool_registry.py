# -*- coding: utf-8 -*-
"""Реєстр інструментів фабрики (strw-state/engine/tools.yaml, схема v1/v1.1) — читання, проба, підбір.

Один модуль на два входи — tool-probe.sh (проба одного запису) і tool-select.sh (підбір
під тип задачі, роль і контур), щоб «доступний» означало одне й те саме в обох
(елемент factory.tool-select, слова CEO 28.10). Схему тримає валідатор strw-state
(`scripts/tools-registry-check.sh`); тут перевіряються лише поля, які цей модуль ЧИТАЄ, —
зламане таке поле дає RegistryError («не поміряти», код 2), а не тихий пропуск запису.

Три форми проби (`availability.probe.kind`):
  · shell      — `cmd` виконується тут і зараз у теці `cwd` (strw-ops|strw-factory|strw-state),
                 stdin закритий, таймаут; код 0 = доступний;
  · lanes-tool — проба з `lanes.yaml tools.<ref>.probe` (та сама, що в toolchain-filter);
  · session    — інструмент сесії (MCP, Artifact, Skill) з shell НЕ міряється: читається
                 `availability.measured` (result + at); вимір, старший за max_age_days або
                 з майбутнього (понад годину), — «протух», не «доступний».
"""
import datetime
import glob
import os
import signal
import subprocess

PROBE_KINDS = ("shell", "lanes-tool", "session")
SESSION_RESULTS = ("available", "unavailable", "needs-auth")
STATUSES = ("active", "candidate", "forbidden")
CWD_REPOS = ("strw-ops", "strw-factory", "strw-state")
FUTURE_GRACE = datetime.timedelta(hours=1)   # годинник сесії й машини розходяться; більше — одруківка дати


class RegistryError(Exception):
    """Реєстр не прочитати або запис зламаний — «не поміряти» (код 2), не порожній успіх."""


def _str_list(v):
    return isinstance(v, list) and all(isinstance(x, str) and x for x in v)


def _nonblank(v):
    return isinstance(v, str) and bool(v.strip())


def _check_tool(t, i):
    if not isinstance(t, dict):
        raise RegistryError(f"tools[{i}] не мапа")
    tid = t.get("id")
    if not _nonblank(tid):
        raise RegistryError(f"tools[{i}]: немає `id`")
    where = f"інструмент {tid}"
    if not _nonblank(t.get("kind")):
        raise RegistryError(f"{where}: немає `kind`")
    if t.get("status") not in STATUSES:
        raise RegistryError(f"{where}: status {t.get('status')!r} поза {'|'.join(STATUSES)}")
    rank = t.get("rank")
    if not isinstance(rank, int) or isinstance(rank, bool):
        raise RegistryError(f"{where}: rank {rank!r} — не ціле число")
    for f in ("tasks", "contours"):
        if not _str_list(t.get(f)) or not t[f]:
            raise RegistryError(f"{where}: `{f}` — непорожній список рядків (порожній = запис недосяжний)")
    for f in ("roles", "loops"):
        if not _str_list(t.get(f, [])):
            raise RegistryError(f"{where}: `{f}` — список рядків ([] = будь-яка)")
    av = t.get("availability")
    probe = av.get("probe") if isinstance(av, dict) else None
    if not isinstance(probe, dict) or probe.get("kind") not in PROBE_KINDS:
        raise RegistryError(f"{where}: availability.probe.kind поза {'|'.join(PROBE_KINDS)}")
    kind = probe["kind"]
    if kind == "shell":
        if not _nonblank(probe.get("cmd")):
            raise RegistryError(f"{where}: проба shell без `cmd` (порожня команда дала б код 0 = «доступний»)")
        if probe.get("cwd", "strw-ops") not in CWD_REPOS:
            raise RegistryError(f"{where}: cwd {probe.get('cwd')!r} поза {'|'.join(CWD_REPOS)}")
    elif kind == "lanes-tool":
        if not _nonblank(probe.get("ref")):
            raise RegistryError(f"{where}: проба lanes-tool без `ref`")
    else:
        m = av.get("measured")
        if not isinstance(m, dict) or m.get("result") not in SESSION_RESULTS or not m.get("at"):
            raise RegistryError(f"{where}: проба session без measured.at/result ({'|'.join(SESSION_RESULTS)}) — "
                                "з shell її не поміряти, без виміру — не вгадувати")
        parse_at(m["at"], where)


def _vocab_list(vocab, key, allow_map=False):
    v = vocab.get(key)
    if allow_map and isinstance(v, dict) and all(isinstance(k, str) for k in v):
        return list(v.keys())
    if _str_list(v):
        return list(v)
    raise RegistryError(f"tools.yaml: vocab.{key} — {'мапа або ' if allow_map else ''}список рядків, а не {type(v).__name__}")


def load(engine, load_nodup):
    path = os.path.join(engine, "tools.yaml")
    if not os.path.isfile(path):
        raise RegistryError(f"немає {path}")
    try:
        with open(path, encoding="utf-8") as fh:
            doc = load_nodup(fh) or {}
    except Exception as e:
        raise RegistryError(f"tools.yaml не парситься: {e}")
    if not isinstance(doc, dict) or doc.get("schema_version") != 1:
        raise RegistryError("tools.yaml: schema_version не 1 — цей скрипт знає лише схему v1")
    vocab = doc.get("vocab")
    if not isinstance(vocab, dict):
        raise RegistryError("tools.yaml: немає `vocab:`")
    doc["_vocab"] = {"task_types": _vocab_list(vocab, "task_types", allow_map=True),
                     "session_roles": _vocab_list(vocab, "session_roles"),
                     "contours": _vocab_list(vocab, "contours"),
                     "kinds": _vocab_list(vocab, "kinds")}
    tools = doc.get("tools")
    if not isinstance(tools, list):
        raise RegistryError("tools.yaml: `tools:` має бути списком")
    seen = set()
    for i, t in enumerate(tools):
        _check_tool(t, i)
        if t["id"] in seen:
            raise RegistryError(f"дубль id {t['id']}")
        seen.add(t["id"])
    return doc


def find(doc, tid):
    for t in doc["tools"]:
        if t["id"] == tid:
            return t
    raise RegistryError(f"інструмента {tid!r} немає в tools.yaml")


def parse_at(v, where="measured.at"):
    """measured.at → aware UTC datetime. YAML дає рядок («…T09:00Z» без секунд), date або datetime."""
    if isinstance(v, datetime.datetime):
        return v if v.tzinfo else v.replace(tzinfo=datetime.timezone.utc)
    if isinstance(v, datetime.date):
        return datetime.datetime(v.year, v.month, v.day, tzinfo=datetime.timezone.utc)
    if isinstance(v, str):
        for fmt in ("%Y-%m-%dT%H:%MZ", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d"):
            try:
                return datetime.datetime.strptime(v, fmt).replace(tzinfo=datetime.timezone.utc)
            except ValueError:
                pass
    raise RegistryError(f"{where}: measured.at {v!r} — не дата (2026-10-28T09:00Z)")


def one_line(cmd):
    """Команда в рядку виводу — без переносів: stdout tool-probe — рівно один рядок, а `cmd: |` у YAML багаторядковий."""
    return " ⏎ ".join(l.strip() for l in cmd.strip().splitlines() if l.strip())


class Prober:
    """Пробує інструменти тут і зараз, з таймаутом."""

    def __init__(self, engine, repo_dirs, timeout, now, max_age_days, load_nodup):
        self.engine, self.repo_dirs, self.timeout = engine, repo_dirs, timeout
        self.now, self.max_age = now, datetime.timedelta(days=max_age_days)
        self.load_nodup, self._lanes = load_nodup, None

    def _lanes_tools(self):
        if self._lanes is None:
            p = os.path.join(self.engine, "lanes.yaml")
            try:
                with open(p, encoding="utf-8") as fh:
                    doc = self.load_nodup(fh) or {}
            except FileNotFoundError:
                raise RegistryError(f"проба lanes-tool, а {p} немає")
            except Exception as e:
                raise RegistryError(f"lanes.yaml не парситься: {e}")
            tools = doc.get("tools") if isinstance(doc, dict) else None
            self._lanes = tools if isinstance(tools, dict) else {}
        return self._lanes

    def _run(self, cmd, cwd):
        """Код 0 → available; інакше unavailable; не вклався в таймаут → timeout (уся група процесів убита)."""
        shown = one_line(cmd)
        try:
            p = subprocess.Popen(["bash", "-c", cmd], cwd=cwd, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as e:
            return "unavailable", f"проба `{shown}` не запустилась: {e}"
        try:
            rc = p.wait(timeout=self.timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass
            p.wait()
            return "timeout", f"проба `{shown}` не завершилась за {self.timeout:g} с"
        return ("available" if rc == 0 else "unavailable"), f"проба `{shown}` → код {rc}"

    def probe(self, t):
        """→ (стан, деталь); стан ∈ available | unavailable | needs-auth | stale | timeout."""
        av = t["availability"]
        pr = av["probe"]
        kind = pr["kind"]
        if kind == "shell":
            repo = pr.get("cwd", "strw-ops")
            d = self.repo_dirs.get(repo)
            if not d:
                raise RegistryError(f"немає словника репо для cwd {repo} (repo-dir.sh)")
            if not os.path.isdir(d):
                return "unavailable", f"shell: немає теки {repo} ({d})"
            st, det = self._run(pr["cmd"], d)
            return st, f"shell (cwd {repo}): {det}"
        if kind == "lanes-tool":
            lt = self._lanes_tools().get(pr["ref"])
            if not isinstance(lt, dict) or not _nonblank(lt.get("probe")):
                raise RegistryError(f"інструмент {t['id']}: lanes-tool {pr['ref']!r} — немає в lanes.yaml tools або проба порожня")
            st, det = self._run(lt["probe"], None)
            return st, f"lanes-tool {pr['ref']}: {det}"
        m = av["measured"]
        at = parse_at(m["at"], f"інструмент {t['id']}")
        by = f" · by {m['by']}" if m.get("by") else ""
        stamp = f"сесійний вимір {m['at']}: {m['result']}{by}"
        if at > self.now + FUTURE_GRACE:
            return "stale", f"{stamp} — дата з майбутнього, вимір не чинний"
        if self.now - at > self.max_age:
            return "stale", f"{stamp} — старший за {self.max_age.days} дн., переміряти в сесії"
        return m["result"], stamp


def frontmatter_values(path, key):
    """Значення `key:` лише з ЗАКРИТОГО frontmatter (`---` … `---` на початку файла); тіло — не словник."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    if not lines or lines[0].strip() != "---":
        return []
    vals = []
    for ln in lines[1:]:
        if ln.strip() == "---":
            return vals
        if ln.startswith(key + ":"):
            vals.append(ln[len(key) + 1:].strip().strip("\"'"))
    return []   # frontmatter не закрито — увесь файл не читається як словник


def agent_names(agents_dir):
    """Ролі-агенти — `name:` з frontmatter agents/**/*.md плагіна."""
    if not agents_dir or not os.path.isdir(agents_dir):
        return set()
    return {v for p in glob.glob(os.path.join(agents_dir, "**", "*.md"), recursive=True)
            for v in frontmatter_values(p, "name")}


def loop_ids(loops_dir):
    """Петлі — `id:` з frontmatter loops/*.md плагіна (реєстр словника петель не має)."""
    if not loops_dir or not os.path.isdir(loops_dir):
        return set()
    return {v for p in glob.glob(os.path.join(loops_dir, "*.md")) for v in frontmatter_values(p, "id")}


def select(doc, task, role, contour, loop, kind, agents, loops, prober):
    """→ (код, рядки stdout, рядки stderr). 0 обрано · 3 немає доступного · 4 немає в реєстрі."""
    v = doc["_vocab"]
    roles = v["session_roles"] + sorted(agents)
    if task not in v["task_types"]:
        raise RegistryError(f"невідомий тип задачі {task!r}; словник: {', '.join(v['task_types']) or '(порожній)'}")
    if role not in roles:
        hint = "" if agents else " (agents/ плагіна не знайдено — ролі-агенти не відомі)"
        raise RegistryError(f"невідома роль {role!r}; словник: {', '.join(roles) or '(порожній)'}{hint}")
    if contour not in v["contours"]:
        raise RegistryError(f"невідомий контур {contour!r}; словник: {', '.join(v['contours']) or '(порожній)'}")
    if loop is not None and loop not in loops:
        hint = "" if loops else " (loops/ плагіна не знайдено)"
        raise RegistryError(f"невідома петля {loop!r}; словник: {', '.join(sorted(loops)) or '(порожній)'}{hint}")
    if kind is not None and kind not in v["kinds"]:
        raise RegistryError(f"невідомий вид {kind!r}; словник: {', '.join(v['kinds']) or '(порожній)'}")

    diag, cands = [], []
    for t in doc["tools"]:
        if task not in t["tasks"]:
            continue
        if t["status"] == "forbidden":
            diag.append(f"відкинуто {t['id']}: forbidden — {t.get('why', 'без why')}")
            continue
        if kind is not None and t["kind"] != kind:
            diag.append(f"відкинуто {t['id']}: вид {t['kind']} ≠ {kind}")
            continue
        if t.get("roles") and role not in t["roles"]:
            diag.append(f"відкинуто {t['id']}: роль {role} поза [{', '.join(t['roles'])}]")
            continue
        if contour not in t["contours"]:
            diag.append(f"відкинуто {t['id']}: контур {contour} поза [{', '.join(t['contours'])}]")
            continue
        if t.get("loops") and loop not in t["loops"]:
            diag.append(f"відкинуто {t['id']}: петля {loop or '—'} поза [{', '.join(t['loops'])}]")
            continue
        cands.append(t)
    scope = (f"задача {task} · роль {role} · контур {contour}" + (f" · петля {loop}" if loop else "")
             + (f" · вид {kind}" if kind else ""))
    if not cands:
        return 4, [f"немає інструмента в реєстрі: {scope}"], diag

    rows = []
    for t in cands:
        st, det = prober.probe(t)
        rows.append((0 if st == "available" else 1, 0 if t["status"] == "active" else 1, t["rank"], t["id"], st, det, t))
    rows.sort(key=lambda r: r[:4])
    chosen = next((r for r in rows if r[0] == 0 and r[1] == 0), None)
    out = []
    for n, (_, _, rank, tid, st, det, t) in enumerate(rows, 1):
        if chosen is not None and chosen[3] == tid:
            mark = "обрано"
        elif st != "available":
            mark = f"НЕДОСТУПНИЙ ({st})"
        elif t["status"] == "candidate":
            mark = f"кандидат, не ввімкнено — {t.get('why', 'без why')}"
        else:
            mark = "резерв"
        c = t.get("constraints") or {}
        out.append(f"{n}. {tid} · {mark} · {t['status']} · rank {rank} · {det} · "
                   f"cost {c.get('cost', '?')} · user_data {c.get('user_data', '?')}")
    if chosen:
        t = chosen[6]
        head = f"обрано: {t['id']} ({t.get('name', t['id'])}) · {scope} · rank {t['rank']} · {chosen[5]}"
        return 0, [head] + out, diag
    why = "; ".join(f"{r[3]} — {r[4]}" if r[4] != "available" else f"{r[3]} — candidate, не ввімкнено" for r in rows)
    return 3, [f"немає доступного: {len(rows)} кандидат(ів) · {scope}: {why}"] + out, diag
