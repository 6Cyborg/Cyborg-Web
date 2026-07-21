#!/usr/bin/env python3
# Invoqué via `uv run --script` (cf. apply-device-config.fish) — Amazon
# Linux 2 a un coreutils trop vieux pour `env -S`, donc pas de shebang
# `#!/usr/bin/env -S uv run --script`.
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "Appium-Python-Client>=3.0",
# ]
# ///
"""chrome.py — relance Chrome après pm clear via Appium et dismiss le
first-run. Appelé en fin d'apply-device-config.fish.
Crée une nouvelle session Appium à chaque invocation puis la ferme.
"""

import re
import subprocess
import sys
import time
from appium import webdriver
from appium.options.android import UiAutomator2Options
from appium.webdriver.common.appiumby import AppiumBy
from selenium.common.exceptions import WebDriverException, NoSuchElementException

CHROME_PACKAGE = "com.android.chrome"
LAUNCHER_PREFERENCES = ["com.google.android.apps.chrome.Main"]

CONNECT_DEADLINE_S = 30
CONNECT_INTERVAL_S = 0.5

# Activity Resolver Table block dans `dumpsys package <pkg>` :
#         <hex> <pkg>/<Activity> filter <hex>
#           Action: "android.intent.action.MAIN"
#           Category: "android.intent.category.LAUNCHER"
# Le bloc se termine quand l'indentation revient au niveau du header (filter
# suivant) ou en-dessous (nouvelle section).
_DUMPSYS_FILTER_RE = re.compile(
    rf"^(?P<indent>[ \t]+)\S+[ \t]+{re.escape(CHROME_PACKAGE)}/(?P<activity>\S+)"
    rf"[ \t]+filter[ \t]+\S+[ \t]*$\n"
    rf"(?P<block>(?:(?P=indent)[ \t]+.*$\n)+)",
    re.MULTILINE,
)


def resolve_chrome_activity():
    # dumpsys package <pkg> est scopé au manifest installé : pas de filtrage
    # par user courant ni par état enabled/default (contrairement à `cmd
    # package query-activities` qui rendait vide pour Chrome sur Pixel 6).
    # stderr non capturé → forwardé directement au stderr du script.
    out = subprocess.run(
        ["adb", "shell", "dumpsys", "package", CHROME_PACKAGE],
        stdout=subprocess.PIPE, check=True, text=True,
    ).stdout
    candidates = []
    seen = set()
    for m in _DUMPSYS_FILTER_RE.finditer(out):
        activity = m.group("activity")
        block = m.group("block")
        if (activity not in seen
                and 'Action: "android.intent.action.MAIN"' in block
                and 'Category: "android.intent.category.LAUNCHER"' in block):
            seen.add(activity)
            candidates.append(activity)
    print(f"[chrome] LAUNCHER activities for {CHROME_PACKAGE}: {candidates}")
    if not candidates:
        raise RuntimeError(
            f"no MAIN+LAUNCHER activity found in dumpsys for {CHROME_PACKAGE}"
        )
    for pref in LAUNCHER_PREFERENCES:
        if pref in candidates:
            return pref
    raise RuntimeError(
        f"none of {LAUNCHER_PREFERENCES} present in {candidates} for {CHROME_PACKAGE}"
    )


def connect_chrome():
    activity = resolve_chrome_activity()
    opts = UiAutomator2Options().load_capabilities({
        "platformName": "Android",
        "appium:automationName": "UiAutomator2",
        "appium:appPackage": CHROME_PACKAGE,
        # Activity résolue dynamiquement : sur ~10-20% des devices
        # (Samsung, Xiaomi) `com.google.android.apps.chrome.Main` n'existe
        # pas, et certains exposent plusieurs LAUNCHER → `am start -a MAIN
        # -c LAUNCHER -S` plante avec "Intent matches multiple activities".
        # Passer appActivity explicite force le `am start -n pkg/activity`
        # qui est non-ambigu.
        "appium:appActivity": activity,
        # Le wipe complet est fait via `adb shell pm clear` dans
        # apply-device-config.fish AVANT cet appel — donc Chrome est vierge
        # à la session start. Avec noReset:true + dontStopAppOnReset:
        # true, Appium ne force-stop pas Chrome au deleteSession ⇒
        # Chrome reste vivant avec sa CDP socket bound, le tunnel
        # pointe sur un process actif (sinon 502 Bad Gateway).
        "appium:noReset": True,
        "appium:dontStopAppOnReset": True,
        # `pm clear` (côté apply-device-config.fish) tue Chrome hors d'Appium ;
        # sans forceAppLaunch, UiAutomator2 considère sa session active
        # et ne relance pas Chrome à partir de la 2ème invocation.
        "appium:forceAppLaunch": True,
        "appium:newCommandTimeout": 300,
    })

    deadline = time.monotonic() + CONNECT_DEADLINE_S
    attempt = 0
    last_err = None
    while time.monotonic() < deadline:
        attempt += 1
        print(f"[wd] connect attempt {attempt}")
        try:
            return webdriver.Remote("http://127.0.0.1:4723/wd/hub", options=opts)
        except WebDriverException as e:
            last_err = e
            print(f"[wd] attempt {attempt} failed: {e.msg}")
            time.sleep(CONNECT_INTERVAL_S)
    raise RuntimeError(
        f"connect webdriverio failed after {attempt} attempts "
        f"({CONNECT_DEADLINE_S}s deadline): {last_err}"
    )


CLICK_DEADLINE_S = 10
CLICK_INTERVAL_S = 0.5


def click(driver, candidates, timeout=CLICK_DEADLINE_S, optional=False):
    deadline = time.monotonic() + timeout
    attempt = 0
    while True:
        attempt += 1
        for sel in candidates:
            try:
                el = driver.find_element(AppiumBy.XPATH, sel)
                el.click()
                print(f"clicked {sel!r} after {attempt} attempt(s).")
                return True
            except NoSuchElementException:
                continue
        if time.monotonic() >= deadline:
            break
        time.sleep(CLICK_INTERVAL_S)
    if optional:
        print(f"skipped {candidates!r} (not found within {timeout}s, {attempt} attempts).")
        return False
    raise RuntimeError(
        f"element to click not found through {candidates!r} "
        f"after {attempt} attempts ({timeout}s deadline)"
    )


def chrome_first_run(driver):
    # TODO: traductions des labels de boutons selon la locale
    print("[fre] dismissing first-run prompts")

    click(driver, [
        '//android.widget.Button[@text="Stay signed out"]',
        '//*[@text="Stay signed out"]',
    ])

    # "No thanks" : present on Pixel, absent on S21 Ultra & Xiaomi Redmi
    # Note 10 5G — skip if not seen.
    click(driver, [
        '//android.widget.Button[@text="No thanks"]',
        '//*[@text="No thanks"]',
    ], timeout=5, optional=True)

    print("[fre] done")


def main():
    driver = connect_chrome()
    print(f"[chrome] session={driver.session_id}")
    try:
        chrome_first_run(driver)
    finally:
        driver.quit()
    print("[chrome] done")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[chrome] fatal: {e}", file=sys.stderr)
        sys.exit(1)
