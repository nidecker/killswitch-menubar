# Kill Switch for WireGuard (macOS)

A menu bar icon that turns on a pf kill switch around the tunnel of the
[WireGuard](https://www.wireguard.com/) macOS app, and keeps checking that it works.

While the kill switch is on, nothing leaves outside the tunnel, neither traffic nor DNS. Only the
WireGuard server stays reachable, so the tunnel can come back up.

> Independent project, not affiliated with the WireGuard project. "WireGuard" is a registered
> trademark of Jason A. Donenfeld.

## How it works

- **Nothing to configure.** The connected tunnel, its server (`Endpoint`) and its `utunN`
  interface are read from the system VPN configuration (`scutil --nc`), where the WireGuard app
  declares them. Private keys are never read.
- **Isolated pf rules.** They are loaded into a dedicated anchor (`com.apple/000.wgks`), and pf is
  enabled by reference (`pfctl -E` / `-X`). The macOS ruleset and other tools that use pf are left
  untouched.
- **Measured, not assumed.** Every 5 s and on every network change, the app attempts a TCP
  connection forced through Wi-Fi/Ethernet, outside the tunnel. If it succeeds, the icon turns red.
- **Unobtrusive.** The icon only shows while the WireGuard app is running, or while the kill switch
  is on (so it can always be turned off).

What still gets out outside the tunnel while the kill switch is on:

| Traffic | Why |
|---|---|
| UDP to the WireGuard server's IP, on its port | establishing the tunnel |
| DHCP, IPv6 neighbor discovery | configuring Wi-Fi/Ethernet |
| Loopback (`lo0`) | traffic internal to the Mac |

Everything else is rejected, DNS included.

## Icon

| Icon | Meaning |
|---|---|
| full **green** ring | protected: traffic only leaves through the VPN |
| full **orange** ring | VPN down, or another tunnel connected: internet blocked |
| two red **quarter** rings | kill switch off: traffic can leave outside the VPN |

## Installation

Requires the Xcode command line tools (`xcode-select --install`) and macOS 14 or later.

```bash
git clone https://github.com/nidecker/killswitch-menubar.git
cd killswitch-menubar
./build.sh
cp -R "build/Kill Switch.app" /Applications/
open "/Applications/Kill Switch.app"
```

The app is not signed with an Apple certificate: when you build it yourself, Gatekeeper does not
block it.

## Usage

1. Connect the tunnel you want in the WireGuard app.
2. Icon → **Turn On Kill Switch**, then enter an administrator password (pfctl needs root).
3. To keep the icon ready at all times: **Open at Login**.

To check the state from the terminal:

```bash
"/Applications/Kill Switch.app/Contents/MacOS/KillSwitch" --status
```

## Limitations

- **Use an IP as the Endpoint.** If the WireGuard config uses a host name, WireGuard cannot resolve
  it to reconnect, since DNS is blocked. The app flags this in its menu.
- **Reboot.** pf rules do not survive a reboot: turn the kill switch back on.
- **Tunnel or interface change.** Everything stays blocked (no leak) until you click **Reapply**.
- **Local network** (printers, AirDrop, NAS) is blocked while the kill switch is on.

To remove everything by hand if something goes wrong:

```bash
sudo pfctl -a com.apple/000.wgks -F rules
```

## Development

```bash
./build.sh                          # builds build/Kill Switch.app
./tools/make-icon.sh                # regenerates Resources/AppIcon.icns
"build/Kill Switch.app/Contents/MacOS/KillSwitch" --export-icons /tmp/icons   # menu bar icon previews
```

## Credits

Inspired by the [Alexandrshy/wireguard-killswitch](https://github.com/Alexandrshy/wireguard-killswitch)
script (MIT). The pf rules were reworked: dedicated anchor, DNS blocked outside the tunnel, only the
server's IP allowed, automatic interface detection.

## License

MIT, see [LICENSE](LICENSE).
