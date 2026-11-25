#!/usr/bin/env bash
# The CI workflow file must be one GitHub accepts, and keep the safety shape this kit promises. GitHub validates the
# whole file BEFORE any job starts: one illegal expression or key and every job is skipped ("This run likely failed
# because of a workflow file issue"). Checked here without a network: the YAML parses; only known job and step keys;
# every step is exactly one of run or uses; every `uses` is pinned to a 40-hex commit; the token is read-only and no
# secret is used; a job-level env holds no expression from a context GitHub does not offer there (runner, env, steps,
# job: the exact mistake that once sank the Station job). Needs python3 with PyYAML (ubuntu runners have it).
# Run: bash tests/workflow-shape.test.sh
set -u
unset TMUX TMUX_PANE   # never reach the caller's real tmux (tests/no-real-tmux.test.sh)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="${WORKFLOW_FILE:-$ROOT/.github/workflows/test.yml}"
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP workflow-shape: python3 has no PyYAML module (CI's ubuntu runner does)"; echo "workflow-shape: 0 passed, 0 failed (skipped)"; exit 0; }
python3 - "$W" <<'PY'
import re, sys, yaml
path = sys.argv[1]
passed = failed = 0
def check(cond, msg):
    global passed, failed
    if cond: passed += 1
    else: failed += 1; print("FAIL " + msg)
def done():
    print("workflow-shape: %d passed, %d failed" % (passed, failed)); sys.exit(1 if failed else 0)
try:
    d = yaml.safe_load(open(path))
except Exception as e:
    check(False, "the workflow does not parse as YAML: %s" % e); done()
check(True, "")
JOB_KEYS = {"name","runs-on","timeout-minutes","env","steps","needs","permissions","if","concurrency","strategy","defaults","outputs","container","services","environment","continue-on-error"}
STEP_KEYS = {"name","uses","with","run","shell","env","if","id","working-directory","continue-on-error","timeout-minutes"}
# contexts GitHub does NOT offer in a job-level env (it offers github, needs, strategy, matrix, vars, secrets, inputs)
BAD_IN_JOB_ENV = re.compile(r"\$\{\{[^}]*\b(runner|env|steps|job)\.")
INJECT = re.compile(r"\$\{\{\s*(github\.event\.(pull_request|issue|comment|head_commit)|github\.head_ref)")
trig = d.get("on", d.get(True))   # PyYAML reads the key `on` as boolean True
check(trig is not None, "no 'on' trigger")
check(not (isinstance(trig, dict) and "pull_request_target" in trig), "pull_request_target is used (a fork's code would run with the token)")
check(d.get("permissions") == {"contents": "read"}, "top-level permissions must be exactly contents: read, got %r" % (d.get("permissions"),))
jobs = d.get("jobs") or {}
for want in ("test", "station", "gitleaks"):
    check(want in jobs, "job '%s' is missing" % want)
for jn, job in jobs.items():
    extra = set(job) - JOB_KEYS
    check(not extra, "job %s has unknown keys %s" % (jn, sorted(extra)))
    check("runs-on" in job, "job %s has no runs-on" % jn)
    check("timeout-minutes" in job, "job %s has no timeout-minutes" % jn)
    for k, v in (job.get("env") or {}).items():
        check(not BAD_IN_JOB_ENV.search(str(v)), "job %s env %s uses a context a job-level env does not get: %s" % (jn, k, v))
    steps = job.get("steps") or []
    check(bool(steps), "job %s has no steps" % jn)
    for i, st in enumerate(steps):
        label = "job %s step %d (%s)" % (jn, i + 1, st.get("name") or st.get("uses") or "run")
        extra = set(st) - STEP_KEYS
        check(not extra, "%s has unknown keys %s" % (label, sorted(extra)))
        check(("run" in st) != ("uses" in st), "%s must have exactly one of run or uses" % label)
        if "uses" in st:
            check(re.search(r"@[0-9a-f]{40}$", st["uses"]) is not None, "%s: uses is not pinned to a 40-hex commit: %s" % (label, st["uses"]))
        if "run" in st:
            check(not INJECT.search(st["run"]), "%s puts event text in a run script (injection)" % label)
check(not re.search(r"\$\{\{\s*secrets\.", open(path).read()), "a secret is used in the workflow")
rv = str(((jobs.get("station") or {}).get("env") or {}).get("RUST_VERSION", ""))
check(re.fullmatch(r"1\.\d+\.\d+", rv) is not None, "the station job has no pinned RUST_VERSION")
done()
PY
