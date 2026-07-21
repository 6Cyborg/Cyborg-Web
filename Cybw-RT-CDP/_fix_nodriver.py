"""In-memory fixes for nodriver's vendored CDP — without modifying site-packages.

Installs a meta_path finder that intercepts selected `nodriver.cdp.*` modules
and compiles them from patched bytes. Must be imported BEFORE `import nodriver`.

Two families of fixes:

* `network.py` ships a corrupt \xb1 (±) byte that breaks compilation.
  Upstream tracking: https://github.com/ultrafunkamsterdam/nodriver/issues/35

* nodriver's CDP bindings are generated from a RECENT protocol where some
  fields are required — but our target browser (Chrome Android 99) predates
  them and never sends them. `from_json` then raises KeyError, nodriver's
  `process_event` drops the event and calls `logger.exception` (one full
  traceback per HTTP response → log flood), and cyborg_har never sees
  `responseReceived` → HAR entries with status 0, no headers, no timings.
  We relax exactly those reads to `json.get(..., <neutral default>)`: the
  default only kicks in when the key is ABSENT, so recent Chromes keep their
  real values. Reference cross-check: devtools-protocol r961751 (Chrome 99)
  vs nodriver's bindings — see /tmp/cyb-workbench/breakage_report.json.

Every pattern below is asserted present in the module source: if a nodriver
upgrade renames or fixes these reads, the import fails loudly instead of
silently un-patching.
"""

import importlib.abc
import importlib.util
import pathlib
import sys
import sysconfig


_PATCHES: dict[str, list[tuple[bytes, bytes]]] = {
    "nodriver.cdp.network": [
        # Corrupt source byte (see module docstring).
        (b"\xb1Inf", b"+/-Inf"),
        # Response.charset — post-99 field; kills EVERY Network.responseReceived.
        (b"charset=str(json['charset'])",
         b"charset=str(json.get('charset', ''))"),
        # ResourceTiming.receiveHeadersStart — post-99; nested in Response.timing,
        # present on nearly every response. -1 = "unknown" (CDP/HAR convention).
        (b"receive_headers_start=float(json['receiveHeadersStart'])",
         b"receive_headers_start=float(json.get('receiveHeadersStart', -1))"),
        # SecurityDetails.encryptedClientHello — post-99; nested in
        # Response.securityDetails, present on every HTTPS response.
        (b"encrypted_client_hello=bool(json['encryptedClientHello'])",
         b"encrypted_client_hello=bool(json.get('encryptedClientHello', False))"),
        # ClientSecurityState.localNetworkAccessRequestPolicy — post-99 (99 had
        # privateNetworkRequestPolicy); reached via *ExtraInfo events.
        (b"LocalNetworkAccessRequestPolicy.from_json(json['localNetworkAccessRequestPolicy'])",
         b"LocalNetworkAccessRequestPolicy.from_json(json.get('localNetworkAccessRequestPolicy', 'Allow'))"),
        # TrustTokenParams.operation — Chrome 99 sent it as 'type' (renamed since).
        (b"TrustTokenOperationType.from_json(json['operation'])",
         b"TrustTokenOperationType.from_json(json.get('operation', json.get('type', 'Issuance')))"),
        # SignedExchangeInfo.hasExtraInfo — post-99. Same byte pattern also
        # matches ResponseReceived.hasExtraInfo where Chrome 99 DOES send the
        # key, so the default is a no-op there.
        (b"has_extra_info=bool(json['hasExtraInfo'])",
         b"has_extra_info=bool(json.get('hasExtraInfo', False))"),
    ],
    "nodriver.cdp.page": [
        # NavigatedWithinDocument.navigationType — post-99; fired on every SPA
        # pushState/replaceState navigation. Second textual match belongs to an
        # event Chrome 99 does send the key for (no-op there).
        (b"navigation_type=str(json['navigationType'])",
         b"navigation_type=str(json.get('navigationType', 'other'))"),
        # JavascriptDialogOpening/Closed.frameId — post-99. Pattern is shared
        # by 17 page.py events; everywhere else Chrome 99 sends the key, so the
        # '' default never materialises there.
        (b"frame_id=FrameId.from_json(json['frameId'])",
         b"frame_id=FrameId.from_json(json.get('frameId', ''))"),
    ],
}


class _PatchedLoader(importlib.abc.Loader):
    def __init__(self, fullname: str, path: pathlib.Path) -> None:
        self.fullname = fullname
        self.path = path

    def create_module(self, spec):  # noqa: ANN001, ANN201 — importlib API
        return None

    def exec_module(self, module) -> None:  # noqa: ANN001 — importlib API
        data = self.path.read_bytes()
        for old, new in _PATCHES[self.fullname]:
            if old not in data:
                raise ImportError(
                    f"_fix_nodriver: pattern {old!r} not found in {self.path} — "
                    f"nodriver changed, update _PATCHES"
                )
            data = data.replace(old, new)
        code = compile(data, str(self.path), "exec")
        exec(code, module.__dict__)


class _Finder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path, target=None):  # noqa: ANN001, ANN201
        if fullname not in _PATCHES:
            return None
        filename = fullname.rpartition(".")[2] + ".py"
        # `path` is the parent package's __path__ (nodriver/cdp), so it locates
        # the module regardless of install layout (venv, uv cache, ...). Fall
        # back to purelib for safety.
        candidates = list(path or [])
        candidates.append(
            str(pathlib.Path(sysconfig.get_paths()["purelib"]) / "nodriver" / "cdp")
        )
        for d in candidates:
            p = pathlib.Path(d) / filename
            if p.exists():
                return importlib.util.spec_from_loader(
                    fullname, _PatchedLoader(fullname, p), origin=str(p)
                )
        return None


if not any(isinstance(f, _Finder) for f in sys.meta_path):
    sys.meta_path.insert(0, _Finder())
