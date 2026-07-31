#!/usr/bin/env bash
# Install or remove Firstmate's guarded Hermes crew turn-end hook.
#
# This command is the sole owner of the text-level edit to
# ${HERMES_HOME:-$HOME/.hermes}/config.yaml.
# It validates YAML through Hermes's own config loader but never serializes the
# captain's config.
# Install adds one marker-delimited Firstmate region, and remove excises only
# that region.
# Missing, malformed, symlinked, partially marked, or structurally surprising
# config is refused without a config write.
#
# The installed post_llm_call hook always exits zero and stays silent.
# It reads cwd from the hook payload, checks for a .fm-hermes-turnend pointer,
# and touches a task turn-end marker only when the pointer names a
# Firstmate-created token in the private Hermes registry.
#
# Usage:
#   fm-hermes-turnend-hook.sh install
#   fm-hermes-turnend-hook.sh remove
set -u

case "${1:-}" in
  install|remove) ACTION=$1 ;;
  -h|--help)
    sed -n '2,20{s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s install|remove\n' "${0##*/}" >&2
    exit 2
    ;;
esac

if [ -z "${HOME:-}" ]; then
  printf 'fm-hermes-turnend-hook: refused: HOME is unset.\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-hermes-turnend-hook: refused: python3 is required for safe config editing.\n' >&2
  exit 1
fi
if [ "$ACTION" = install ] && ! command -v jq >/dev/null 2>&1; then
  printf 'fm-hermes-turnend-hook: refused: jq is required by the installed Hermes turn-end hook.\n' >&2
  exit 1
fi

HERMES_BIN=${FM_HERMES_BINARY:-}
if [ -z "$HERMES_BIN" ]; then
  HERMES_BIN=$(command -v hermes 2>/dev/null || true)
fi
if [ -z "$HERMES_BIN" ] || [ ! -x "$HERMES_BIN" ]; then
  printf 'fm-hermes-turnend-hook: refused: hermes executable was not found.\n' >&2
  exit 1
fi

HERMES_CONFIG_HOME=${HERMES_HOME:-$HOME/.hermes}
python3 - "$ACTION" "$HERMES_CONFIG_HOME" "$HERMES_BIN" <<'PY'
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import tempfile

ACTION = sys.argv[1]
CONFIG_DIR = os.path.abspath(sys.argv[2])
HERMES_BINARY = os.path.abspath(sys.argv[3])
CONFIG = os.path.join(CONFIG_DIR, "config.yaml")
HOOK = os.path.join(CONFIG_DIR, "fm-turn-end.sh")
REGISTRY = os.path.join(CONFIG_DIR, "fm-turn-end.d")
IDENTIFIER = "FIRSTMATE HERMES TURN-END HOOK"
BEGIN_TEXT = f"# BEGIN {IDENTIFIER}"
BEGIN_OWNS_NEWLINE_TEXT = f"{BEGIN_TEXT} (OWNS PRECEDING NEWLINE)"
END_TEXT = f"# END {IDENTIFIER}"
TOKEN_NAME = re.compile(r"fm\.[A-Za-z0-9]{12}\Z")

def refuse(reason):
    print(f"fm-hermes-turnend-hook: refused: {reason}", file=sys.stderr)
    raise SystemExit(1)


def regular_not_symlink(path, label):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        refuse(f"{label} is missing at {path}.")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        refuse(f"{label} is not a regular non-symlink file at {path}.")
    return info


def validate_yaml(data, label, expected_command=None):
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as error:
        refuse(f"{label} is not UTF-8: {error}.")
    with tempfile.TemporaryDirectory(prefix="fm-hermes-validate-") as probe_home:
        probe_config = os.path.join(probe_home, "config.yaml")
        with open(probe_config, "wb") as stream:
            stream.write(data)
        environment = os.environ.copy()
        environment["HERMES_HOME"] = probe_home
        try:
            result = subprocess.run(
                [HERMES_BINARY, "hooks", "list"],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            refuse(f"{label} could not be validated by Hermes: {error}.")
    output = result.stdout
    if result.returncode != 0 or "Failed to parse" in output or "Falling back to default config" in output:
        refuse(f"{label} is invalid YAML according to Hermes: {output.strip()}.")
    if expected_command is not None and expected_command not in output:
        refuse(f"{label} did not load the managed post_llm_call hook.")


def atomic_write(path, data, mode):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".fm-hermes-", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def managed_hook_bytes():
    auth_dir = shlex.quote(REGISTRY)
    return f'''#!/usr/bin/env bash
# Firstmate Hermes turn-end hook.
# Managed by fm-hermes-turnend-hook.sh.
# Every path is deliberately silent and exits zero.
set +e
exec >/dev/null 2>&1
payload=
IFS= read -r payload || [ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
workspace=$(jq -er 'select(.hook_event_name == "post_llm_call") | .cwd | strings | select(length > 0)' <<< "$payload" 2>/dev/null) || exit 0
pointer="$workspace/.fm-hermes-turnend"
[ -f "$pointer" ] || exit 0
first=
IFS= read -r -n 256 first < "$pointer" 2>/dev/null || [ -n "$first" ] || exit 0
case "$first" in token=*) token=${{first#token=}} ;; *) exit 0 ;; esac
case "$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
auth_dir={auth_dir}
target=$(cat "$auth_dir/$token" 2>/dev/null) || exit 0
case "$target" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch -- "$target" 2>/dev/null || true
exit 0
'''.encode("utf-8")


def marker_state(data):
    text = data.decode("utf-8")
    begin_count = text.count(BEGIN_TEXT)
    end_count = text.count(END_TEXT)
    if begin_count == 0 and end_count == 0:
        if IDENTIFIER in text:
            refuse("config.yaml contains an unrecognized Firstmate Hermes marker.")
        return None
    if begin_count != 1 or end_count != 1:
        refuse("config.yaml has partial or duplicate Firstmate Hermes markers.")
    lines = text.splitlines(keepends=True)
    begin = next((i for i, line in enumerate(lines) if BEGIN_TEXT in line), None)
    end = next((i for i, line in enumerate(lines) if END_TEXT in line), None)
    if begin is None or end is None or end < begin:
        refuse("config.yaml has malformed Firstmate Hermes markers.")
    return lines, begin, end


def block_end(lines, start, indent):
    for index in range(start + 1, len(lines)):
        stripped = lines[index].strip()
        if not stripped or stripped.startswith("#"):
            continue
        current_indent = len(lines[index]) - len(lines[index].lstrip(" "))
        if current_indent <= indent:
            return index
    return len(lines)


def install_region(data, command):
    if marker_state(data) is not None:
        validate_yaml(data, "config.yaml", command)
        return data

    text = data.decode("utf-8")
    lines = text.splitlines(keepends=True)
    command_yaml = json.dumps(command)
    hooks_any = [
        index
        for index, line in enumerate(lines)
        if re.match(r"^hooks[ \t]*:", line)
    ]
    hooks_lines = [
        index
        for index, line in enumerate(lines)
        if re.fullmatch(r"hooks:[ \t]*(?:#.*)?(?:\r?\n)?", line)
    ]
    if not hooks_any:
        prefix = "\n"
        region = (
            f"{BEGIN_OWNS_NEWLINE_TEXT}\n"
            "hooks:\n"
            "  post_llm_call:\n"
            f"    - command: {command_yaml}\n"
            "      timeout: 1\n"
            f"{END_TEXT}\n"
        )
        return data + prefix.encode("utf-8") + region.encode("utf-8")
    if len(hooks_any) != 1 or len(hooks_lines) != 1:
        refuse("the top-level hooks mapping is not in supported block form.")
    hooks_index = hooks_lines[0]
    hooks_end = block_end(lines, hooks_index, 0)
    post_lines = []
    for index in range(hooks_index + 1, hooks_end):
        match = re.fullmatch(
            r"( +)post_llm_call:[ \t]*(?:#.*)?(?:\r?\n)?",
            lines[index],
        )
        if match:
            post_lines.append((index, len(match.group(1))))
    if len(post_lines) > 1:
        refuse("post_llm_call appears more than once in the hooks block.")

    if not post_lines:
        if any("post_llm_call" in line for line in lines[hooks_index + 1:hooks_end]):
            refuse("post_llm_call is not in supported block form.")
        region = [
            f"  {BEGIN_TEXT}\n",
            "  post_llm_call:\n",
            f"    - command: {command_yaml}\n",
            "      timeout: 1\n",
            f"  {END_TEXT}\n",
        ]
        lines[hooks_index + 1:hooks_index + 1] = region
        return "".join(lines).encode("utf-8")

    post_index, post_indent = post_lines[0]
    region_indent = " " * (post_indent + 2)
    region = [
        f"{region_indent}{BEGIN_TEXT}\n",
        f"{region_indent}- command: {command_yaml}\n",
        f"{region_indent}  timeout: 1\n",
        f"{region_indent}{END_TEXT}\n",
    ]
    lines[post_index + 1:post_index + 1] = region
    return "".join(lines).encode("utf-8")


def remove_region(data):
    state = marker_state(data)
    if state is None:
        return data
    lines, begin, end = state
    owns_preceding = BEGIN_OWNS_NEWLINE_TEXT in lines[begin]
    del lines[begin:end + 1]
    result = "".join(lines).encode("utf-8")
    if owns_preceding and result.endswith(b"\n"):
        result = result[:-1]
    return result


config_info = regular_not_symlink(CONFIG, "config.yaml")
with open(CONFIG, "rb") as stream:
    original = stream.read()
hook_bytes = managed_hook_bytes()
command = HOOK

if ACTION == "install":
    validate_yaml(original, "config.yaml")
    candidate = install_region(original, command)
    validate_yaml(candidate, "candidate config.yaml", command)
    if os.path.lexists(REGISTRY) and (
        os.path.islink(REGISTRY) or not os.path.isdir(REGISTRY)
    ):
        refuse(f"registry is not a regular directory at {REGISTRY}.")
    if os.path.lexists(HOOK):
        hook_info = regular_not_symlink(HOOK, "managed hook")
        with open(HOOK, "rb") as stream:
            if stream.read() != hook_bytes:
                refuse(f"managed hook path contains foreign content at {HOOK}.")
        if stat.S_IMODE(hook_info.st_mode) != 0o700:
            os.chmod(HOOK, 0o700)
    if not os.path.lexists(HOOK):
        atomic_write(HOOK, hook_bytes, 0o700)
    os.makedirs(REGISTRY, mode=0o700, exist_ok=True)
    os.chmod(REGISTRY, 0o700)
    if candidate != original:
        atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
else:
    candidate = remove_region(original)
    validate_yaml(candidate, "candidate config.yaml")
    if candidate != original:
        atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
    if os.path.lexists(HOOK):
        regular_not_symlink(HOOK, "managed hook")
        with open(HOOK, "rb") as stream:
            if stream.read() != hook_bytes:
                refuse(f"managed hook path contains foreign content at {HOOK}.")
        os.unlink(HOOK)
    if os.path.isdir(REGISTRY) and not os.path.islink(REGISTRY):
        try:
            os.rmdir(REGISTRY)
        except OSError:
            pass
PY
