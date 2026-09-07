#!/usr/bin/env python3
"""Small fail-closed AT-SPI controller for the Ubuntu release-test browser.

No credentials are accepted by this helper. The caller focuses an exact field
or invokes an exact visible control, then streams protected typing through the
Parallels virtual keyboard channel.
"""

import sys
import time
from urllib.parse import urlparse

try:
    import gi

    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi
except Exception as error:  # pragma: no cover - exercised in the guest
    print(f"Ubuntu UI action failed: AT-SPI is unavailable ({error})", file=sys.stderr)
    sys.exit(2)


def fail(message: str, status: int = 1) -> None:
    print(f"Ubuntu UI action failed: {message}", file=sys.stderr)
    sys.exit(status)


def normalized(value: object) -> str:
    return " ".join(str(value or "").split()).casefold()


def browser_nodes():
    desktop = Atspi.get_desktop(0)
    stack = []
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app is not None and "firefox" in normalized(app.get_name()):
            stack.append(app)
    seen = 0
    while stack and seen < 30000:
        node = stack.pop()
        seen += 1
        yield node
        try:
            count = node.get_child_count()
        except Exception:
            continue
        for index in range(count - 1, -1, -1):
            try:
                child = node.get_child_at_index(index)
            except Exception:
                child = None
            if child is not None:
                stack.append(child)


def has_state(node, state) -> bool:
    try:
        return bool(node.get_state_set().contains(state))
    except Exception:
        return False


def is_in_active_browser_window(node) -> bool:
    """Accept only showing objects in Firefox's active top-level window."""
    current = node
    for _ in range(48):
        try:
            role = normalized(current.get_role_name()).replace(" ", "_")
        except Exception:
            return False
        if role in {"frame", "window"}:
            return has_state(current, Atspi.StateType.ACTIVE) and has_state(
                current, Atspi.StateType.SHOWING
            )
        try:
            current = current.get_parent()
        except Exception:
            return False
        if current is None:
            return False
    return False


def matching_nodes(label: str, roles: set[str] | None = None):
    expected = normalized(label)
    for node in browser_nodes():
        try:
            name = normalized(node.get_name())
            role = normalized(node.get_role_name()).replace(" ", "_")
        except Exception:
            continue
        if expected and expected not in name:
            continue
        if roles is not None and role not in roles:
            continue
        if not has_state(node, Atspi.StateType.SHOWING) or not is_in_active_browser_window(node):
            continue
        yield node


def active_document_urls():
    """Yield full URLs only from the showing document in the active Firefox window."""
    for node in browser_nodes():
        try:
            role = normalized(node.get_role_name()).replace(" ", "_")
        except Exception:
            continue
        if role != "document_web" or not has_state(node, Atspi.StateType.SHOWING):
            continue
        if not is_in_active_browser_window(node):
            continue
        try:
            document = node.get_document_iface()
            value = document.get_document_attribute_value("DocURL").strip()
        except Exception:
            continue
        if value:
            yield value


def wait_for(label: str, roles: set[str] | None, timeout: int):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        match = next(matching_nodes(label, roles), None)
        if match is not None:
            return match
        time.sleep(0.25)
    return None


def invoke(node) -> bool:
    try:
        action = node.get_action_iface()
    except Exception:
        action = None
    if action is None:
        return False
    preferred = ("click", "press", "activate", "jump")
    names = []
    try:
        for index in range(action.get_n_actions()):
            names.append(normalized(action.get_action_name(index)))
    except Exception:
        return False
    for wanted in preferred:
        for index, name in enumerate(names):
            if wanted in name:
                return bool(action.do_action(index))
    return bool(names and action.do_action(0))


def focus(node) -> bool:
    try:
        component = node.get_component_iface()
    except Exception:
        component = None
    return bool(component is not None and component.grab_focus())


def parse_timeout(value: str) -> int:
    try:
        timeout = int(value)
    except ValueError:
        fail("timeout must be an integer")
    if timeout < 1 or timeout > 180:
        fail("timeout must be from 1 to 180 seconds")
    return timeout


if len(sys.argv) not in (3, 4):
    fail("usage: ubuntu-ui-action.py <wait|invoke|focus|assert-origin> <label-or-hosts> [timeout]")

command = sys.argv[1]
label = sys.argv[2]
timeout = parse_timeout(sys.argv[3] if len(sys.argv) == 4 else "60")
if not label or len(label) > 160:
    fail("visible label is missing or too long")

Atspi.init()
if command == "assert-origin":
    allowed_hosts = {normalized(host) for host in label.split(",") if normalized(host)}
    if not allowed_hosts:
        fail("assert-origin requires at least one allowed host")
    deadline = time.monotonic() + timeout
    saw_other_origin = False
    while time.monotonic() < deadline:
        for value in active_document_urls():
            parsed = urlparse(value)
            try:
                exact_https_origin = (
                    parsed.scheme.casefold() == "https"
                    and normalized(parsed.hostname) in allowed_hosts
                    and parsed.port in (None, 443)
                    and parsed.username is None
                    and parsed.password is None
                )
            except ValueError:
                exact_https_origin = False
            if exact_https_origin:
                print("UBUNTU_UI_ORIGIN_OK")
                sys.exit(0)
            if parsed.scheme and parsed.hostname:
                saw_other_origin = True
        time.sleep(0.25)
    if saw_other_origin:
        fail("Firefox did not settle on an allowed HTTPS origin")
    fail("the active Firefox HTTPS origin could not be verified")
elif command == "invoke":
    roles = {"push_button", "link"}
elif command == "focus":
    roles = {"entry", "password_text"}
elif command == "wait":
    roles = None
else:
    fail("unknown action")

node = wait_for(label, roles, timeout)
if node is None:
    fail(f"the visible Firefox element '{label}' was not found")
if command == "invoke" and not invoke(node):
    fail(f"the visible Firefox control '{label}' could not be invoked")
if command == "focus" and not focus(node):
    fail(f"the visible Firefox field '{label}' could not be focused")
print("UBUNTU_UI_ACTION_OK")
