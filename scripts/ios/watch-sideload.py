#!/usr/bin/env python3
"""
Puts openGym's Apple Watch app on a watch when the app is signed with a free Apple ID.

A watch app signed with a free ("Personal Team") profile is refused when it reaches the watch the
usual way, through the iPhone's Watch app: the watch says the app's integrity could not be verified
(MIInstallerErrorDomain 111, "authorized by a free provisioning profile, but apps validated by those
are not allowed to be installed from this source"). Installed straight onto the watch as a developer
app, the way Xcode does it, it is accepted. This script does that from any computer the iPhone is
plugged into, Windows included, without a Mac and without Xcode:

    watch      the watch paired with the iPhone: its UDID, to register on the Apple ID
    reveal     shows the Developer Mode switch on the watch (Settings > Privacy & Security)
    install    installs the watch app of a signed .ipa directly on the watch

It talks to the watch through the iPhone (the iPhone's companion proxy forwards the watch's ports),
with pymobiledevice3 (GPL-3.0, pip install pymobiledevice3). The iPhone is reached through the Apple
Mobile Device Service (iTunes on Windows) or, when that does not offer the proxy, through the iOS 17+
tunnel pymobiledevice3 builds itself.

The whole sequence, signing included, is in docs/WATCH_SIDELOAD.md. Written from the pymobiledevice3
sources and one report of the same approach working (carcaret/gym-companion-ios#2); keep it small.
"""

import argparse
import asyncio
import sys
import tempfile
import zipfile
from pathlib import Path

try:
    from pymobiledevice3.exceptions import PyMobileDevice3Exception
    from pymobiledevice3.lockdown import LockdownClient, create_using_usbmux
    from pymobiledevice3.service_connection import ServiceConnection
    from pymobiledevice3.services.amfi import AmfiService
    from pymobiledevice3.services.companion import CompanionProxyService
    from pymobiledevice3.services.streaming_zip_conduit import StreamingZipConduitService
except ImportError:
    sys.exit("pymobiledevice3 is missing: run  python -m pip install -U pymobiledevice3")

LOCKDOWN_PORT = 62078


class Phone:
    """The iPhone, and a way to open a connection to one of its ports."""

    def __init__(self, provider, how, closer=None):
        self.provider = provider
        self.how = how
        self._closer = closer

    async def connect(self, port, ssl_context=None, strip_ssl=False):
        if self.how == "usb":
            return await self.provider.create_service_connection(port, ssl_context=ssl_context, strip_ssl=strip_ssl)
        # Over the tunnel: a plain TCP connection to the iPhone's address, through the tunnel's dialer.
        return await ServiceConnection.create_using_tcp(
            self.provider.service.address[0], port,
            open_connection=getattr(self.provider, "open_connection", None),
            ssl_context=ssl_context, strip_ssl=strip_ssl,
        )

    async def close(self):
        if self._closer is not None:
            await self._closer()
        else:
            await self.provider.close()


async def open_phone(udid=None, transport="auto"):
    if transport in ("auto", "usb"):
        try:
            lockdown = await create_using_usbmux(serial=udid)
            # The proxy is not offered through every route: try it before settling on this one.
            await CompanionProxyService(lockdown).list()
            return Phone(lockdown, "usb")
        except Exception as e:  # noqa: BLE001 (any failure here means: try the tunnel)
            if transport == "usb":
                raise
            print(f"(USB route without the companion proxy: {e!r}; using the tunnel)")
    from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel

    tunnel = UserspaceRsdTunnel(serial=udid)
    rsd = await tunnel.aopen()
    return Phone(rsd, "tunnel", tunnel.aclose)


class WatchLockdown(LockdownClient):
    """The watch's lockdownd, every connection forwarded by the iPhone's companion proxy."""

    def __init__(self, service, host_id, phone=None, proxy=None, **kwargs):
        super().__init__(service, host_id, **kwargs)
        self.phone = phone
        self.proxy = proxy

    async def create_service_connection(self, port, ssl_context=None, strip_ssl=False):
        local = await self.proxy.start_forwarding_service_port(port)
        return await self.phone.connect(local, ssl_context=ssl_context, strip_ssl=strip_ssl)


async def paired_watches(phone):
    proxy = CompanionProxyService(phone.provider)
    found = []
    for entry in await proxy.list():
        udid = entry if isinstance(entry, str) else (entry.get("UniqueDeviceID") or entry.get("udid") or str(entry))
        info = {"udid": udid}
        for key in ("Name", "ProductType", "ProductVersion"):
            try:
                value = await proxy.get_value(udid, key)
                info[key] = value.get(key, value) if isinstance(value, dict) else value
            except PyMobileDevice3Exception:
                pass
        found.append(info)
    return found


async def open_watch(phone, watch_udid):
    proxy = CompanionProxyService(phone.provider)
    local = await proxy.start_forwarding_service_port(LOCKDOWN_PORT)
    service = await phone.connect(local)
    # Pairs with the watch on first use; the watch trusts what its iPhone trusts, no dialog expected.
    return await WatchLockdown.create(service, identifier=watch_udid, port=LOCKDOWN_PORT, phone=phone, proxy=proxy)


async def pick_watch(phone, udid=None):
    watches = await paired_watches(phone)
    if not watches:
        sys.exit("No watch paired with this iPhone was found. Is the watch on, near the iPhone and unlocked?")
    if udid:
        return udid
    if len(watches) > 1:
        sys.exit("Several watches: name one with --watch <UDID> (see the 'watch' command).")
    return watches[0]["udid"]


def watch_app_from(ipa, into):
    """Unpacks the watch app (.app inside Payload/<phone app>.app/Watch/) of a signed .ipa."""
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        roots = sorted({n.split("/Watch/")[0] + "/Watch/" + n.split("/Watch/")[1].split("/")[0]
                        for n in names if "/Watch/" in n and n.split("/Watch/")[1].split("/")[0].endswith(".app")})
        if not roots:
            sys.exit(f"{ipa} holds no watch app (Payload/*.app/Watch/*.app).")
        root = roots[0]
        for name in names:
            if name.startswith(root + "/"):
                archive.extract(name, into)
    app = Path(into) / root
    if not (app / "embedded.mobileprovision").exists():
        sys.exit("The watch app in this .ipa is not signed with a profile. Sign the .ipa first (docs/WATCH_SIDELOAD.md).")
    return app


async def main():
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("--iphone", help="UDID of the iPhone (when several are connected)")
    parser.add_argument("--watch", help="UDID of the watch (when several are paired)")
    parser.add_argument("--via", choices=["auto", "usb", "tunnel"], default="auto", help="how to reach the iPhone")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("watch", help="show the paired watch and its UDID")
    sub.add_parser("reveal", help="show the Developer Mode switch on the watch")
    install = sub.add_parser("install", help="install the watch app of a signed .ipa on the watch")
    install.add_argument("ipa", type=Path)
    args = parser.parse_args()

    phone = await open_phone(args.iphone, args.via)
    try:
        if args.command == "watch":
            for w in await paired_watches(phone):
                print(f"UDID: {w['udid']}")
                for key in ("Name", "ProductType", "ProductVersion"):
                    if key in w:
                        print(f"  {key}: {w[key]}")
            return
        udid = await pick_watch(phone, args.watch)
        watch = await open_watch(phone, udid)
        try:
            if args.command == "reveal":
                await AmfiService(watch).reveal_developer_mode_option_in_ui()
                print("Done: the watch now shows Settings > Privacy & Security > Developer Mode.")
                print("Turn it on there; the watch restarts and asks to confirm.")
            elif args.command == "install":
                with tempfile.TemporaryDirectory() as tmp:
                    app = watch_app_from(args.ipa, tmp)
                    print(f"Installing {app.name} on the watch {udid} ...")
                    await StreamingZipConduitService(watch).install(app, developer=True)
                print("Installed. Open openGym from the watch's app list.")
        finally:
            await watch.close()
    finally:
        await phone.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except PyMobileDevice3Exception as e:
        sys.exit(f"Failed: {e}")
