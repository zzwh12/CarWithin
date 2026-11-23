# CarWithin

**English** · [简体中文](README.md)

[![Platform: iOS 16.0+](https://img.shields.io/badge/iOS-16.0%2B-blue)](#download-and-install) [![Status: released](https://img.shields.io/badge/status-released-brightgreen)](#quick-start) [![Release](https://img.shields.io/github/v/release/xmz28/CarWithin?label=release)](https://github.com/xmz28/CarWithin/releases/latest)

CarWithin runs CarPlay on the same iPhone that generates its interface. Use CarPlay directly on your iPhone for navigation and music, or send the display to a head unit, tablet, computer, or another phone on the local network. A receiving browser can send touch input back to CarPlay.

![CarWithin connection diagram showing playback on iPhone and output to a browser, wireless CarLife, compatible dashboards, or experimental AirPlay.](docs/images/carwithin-connections-en.png)

## Download and install

- [Download from GitHub Releases](https://github.com/xmz28/CarWithin/releases/latest). The current version is **1.0.3 (build 15)**.
- Download `CarWithin-1.0.3-unsigned.ipa` and sign and install it with an IPA sideloading tool using your own signing setup. Follow any iOS prompts for developer trust or Developer Mode.
- The minimum installation target is iOS/iPadOS 16.0 on arm64; iOS 15 is not supported. Same-device CarPlay, audio, and background behavior still need testing on iOS 16.x hardware. CarWithin uses private iOS interfaces. Compatibility depends on the device, OS version, and signing setup, and OS updates can affect it.

- If an IPA built from source reports a missing MFi identity, tap **导入 MFi 身份文件夹** on the home screen. In Files, select the folder containing the `certificate.p7b`, `leaf.cer` and `private.x963` files you are authorized to use. Once the app verifies and stores them, you can start local CarPlay.
- When upgrading from a working build, keep the original signing team and App ID to retain access to its Keychain items. An identity loaded solely from the old app bundle was available only to that build.

## Quick start

1. **Use CarPlay on the iPhone.** Open CarWithin, save your Wi-Fi details in the app if prompted, and start CarPlay. Once the display appears, you can use touch controls or switch to fullscreen.
2. **Use another device as the display.** Under Settings → Current output, choose Browser. Open Output settings and enable the local receiver page. Connect the iPhone and receiver to the same Wi-Fi. The network can be offline or provided by another device's hotspot. The iPhone running CarWithin must itself join Wi-Fi. Start CarPlay and open the HTTP address displayed by the app in the receiving browser.
3. **Use Safari on the same iPhone.** After starting CarPlay, use the option to open the receiver in the local browser under the app's output settings. If the page prompts you to start playback, tap it.
4. **Stop sharing when finished.** Stop CarPlay from the iPhone. The browser receiver has no sign-in. A device that can reach its address can view and control the CarPlay session, so use a trusted network.

## Browser playback and audio

| Mode | When to use it | Default port |
| --- | --- | --- |
| HTTP | First connection, network troubleshooting, or MSE compatibility playback | 9888 |
| HTTPS | Lower-latency playback in browsers with WebCodecs support | 9889 |

Set the HTTP port under Settings → Output settings. Set the HTTPS port and certificate under Settings → HTTPS settings. A blank HTTPS port typically uses the HTTP port plus one. Use the full address shown in the app.

### Set up HTTPS

1. Open the HTTP receiver page on the **receiving device**, then choose HTTPS setup. Check its certificate fingerprint against the iPhone app log.
2. On **iPhone or iPad**, download and install the profile, then enable full trust for its certificate under **General → About → Certificate Trust Settings**. On **Android**, download the Android certificate and follow the setup page to install it as a CA certificate. Menu names vary by device and OS.
3. Open the HTTPS address shown in the app. Browsers without WebCodecs use compatibility playback.

### Use a domain name

Choose an address mode under HTTPS settings:

- **Local IP:** use the iPhone's LAN address and trust its local certificate as described above.
- **sslip.io:** generate a hostname from the current IP without registering an account. The receiver still needs to trust the local certificate, and DNS resolution generally needs internet access. Use the new address displayed by the app after the IP changes.
- **DuckDNS:** enter a dedicated `name.duckdns.org` hostname and Token, then update it to the current IP. Obtain a domain certificate with an external ACME tool and import a P12/PFX containing its private key and full certificate chain. CarWithin does not issue or renew certificates automatically. Update DNS when the IP changes and replace the certificate before it expires. The Token, certificate, and file password stay in the device Keychain.

These modes do not create an internet tunnel or guarantee access through a head unit's private-network restrictions. The complete DuckDNS/public-certificate/head-unit path has not been verified; Tesla compatibility is not claimed.

### Choose where audio plays

- **iPhone output** is the default. Sound follows the speaker or Bluetooth device currently selected by iOS, including a paired head unit.
- **Wi-Fi audio** sends sound to the browser. Select it in the app's audio settings, then restart CarPlay. The page starts video and attempts to play audio automatically. If the browser blocks autoplay, use the on-page button to enable audio. Calls and Siri stay on the iPhone.
- On a computer, press Esc to exit browser fullscreen. The statistics control shows the decoder, dropped frames, and audio buffering.

## Display settings and the vehicle button

- **Follow the receiving display.** The browser reports its viewport. When several receiver pages connect, the first one determines the stream settings and the others receive the same video stream. If the first page closes, a remaining page can take over.
- **Use a fixed size.** If a head unit stretches the picture, shows a black screen, or stutters, try a fixed lower resolution, 30 FPS, or H.264 in the display settings. Applying a new display configuration may require restarting CarPlay.
- **Customize the vehicle button.** Use the vehicle settings to enable the button, pick a photo as its icon, or restore the default. Changes take effect when CarPlay starts again. In app fullscreen, use the vehicle button on the CarPlay home screen to exit. If the vehicle button is disabled, use the upper-left exit button.
- **Picture in Picture and background playback.** Choose when PiP should start in the Background and PiP section on the settings home page. The default is When leaving the app; you can also choose immediately after video appears or turn off automatic activation. For lock-screen use, enable **Allow CarPlay While Locked** under **Settings → General → CarPlay → CarWithin** on the iPhone. PiP shows live video. Use the app or browser for touch input.

## Wi-Fi presets and common settings

The top settings group includes User guide, Wi-Fi and network, Wi-Fi presets, Current output and Output settings. HTTPS settings appears when Browser output is selected.

Enter Wi-Fi credentials and go back to save them automatically. Enable the open-network option for a network without a password. Each SSID has one preset; editing its password updates that preset. Tap a saved preset when changing networks. Swipe to delete, then confirm; this also removes its saved password. The Wi-Fi form no longer rebuilds repeatedly while typing, reducing input stalls.

Some connection settings are locked while CarPlay is running; stop the session before editing them. Appearance, driving side, and audio are available on the settings home page. Logs are under Diagnostics and experiments; versions and updates are under About.

## Other output methods

- **Wireless CarLife.** For compatible head units, connect the head unit and iPhone to the same Wi-Fi. Select CarLife in CarWithin, open CarLife on the head unit, then start CarPlay. CarWithin can discover the head unit or use an IP address you enter. CarLife carries video and touch input, with H.264 up to 1080p at 30 FPS. Audio can play through the head unit's Bluetooth connection.
- **AirPlay (experimental).** Select AirPlay and start CarPlay. When the display is ready, use the AirPlay picker on the main screen to select a video receiver on the same network. AirPlay video is buffered. Touch input stays on the iPhone, and audio follows the iPhone or head unit Bluetooth route.

Fixed display sizes support common landscape and portrait aspect ratios.

### CarbitLink direct output (experimental)

1. Open the QR connection screen in the head unit's CarbitLink app. On iPhone, select **Settings → Current output → 亿连直连（实验）** in CarWithin. Open **Output settings → 扫描车机二维码** and tap the QR code in the camera view.
2. Join a Wi-Fi network that allows the iPhone and head unit to reach each other and select or save the matching Wi-Fi preset in CarWithin. Scanning fills in the head unit IP when the code contains a private IPv4 address. If it contains only a network name, download link or pairing token, use **查找局域网车机** to select an advertised head unit or enter its known IP.
3. Start local CarPlay. Once the head unit accepts the iOS PXC session and requests video, the connection card shows the resolution being sent. Video uses H.264 at up to 1920×1080 and 30 fps. Use the iPhone for touch and route audio through the iPhone or car Bluetooth.

CarWithin connects with its own application identity and sends the local CarPlay picture. QR codes are processed on the iPhone. This mode requires local network projection support. Firmware that requires cloud pairing is unsupported. The factory Ford Mondeo head unit still needs an in-car test. [Carbit connectivity overview](https://carbit.com.cn/new/connect)

### ZEEHO AE4 MAX2+ 6.2-inch display

Connect the iPhone to the instrument Wi-Fi, select the matching preset and choose ZEEHO 6.2-inch under Current output. Open projection on the instrument, then start CarPlay. The default instrument IP is 192.168.0.1. Video uses H.264 at 1024×480 and up to 25 fps. Audio plays through the iPhone or Bluetooth. Operate CarPlay on the phone.

One instrument was tested successfully, including screen lock. Other models and long sessions require further testing.

### Ninebot 5-inch display

Connect the iPhone to the instrument Wi-Fi, select its saved Wi-Fi preset, and choose Ninebot 5-inch under Current output. Enable screen projection on the instrument, then start CarPlay. The default instrument IP is `192.168.1.1`, configurable under Output settings. Audio plays through the iPhone or Bluetooth; control CarPlay on the phone.

One instrument was tested with repeated backgrounding and screen locks. Perceived latency was approximately 500–600 ms. Other instrument versions need testing.

### Tailing 4.3-inch display

This mode targets the **TL-DASH-V2** instrument display. Other models and firmware still need testing.

1. Connect the iPhone to the instrument's Wi-Fi and enter that network's credentials in Wi-Fi and network.
2. Select Tailing 4.3-inch under Current output. The instrument IP defaults to `192.168.1.1`; change it under Output settings if needed.
3. Enable mirroring on the instrument, exit other mirroring apps, and start local CarPlay in CarWithin. The connection card on the main screen shows its status.

The instrument receives 480×272 video at up to 20 FPS. Audio uses the iPhone's current speaker or Bluetooth route. The instrument does not send touch input back; operate CarPlay on the iPhone. Matching display parameters are applied automatically; switching to another output restores its previous settings.

Video and recovery after locking the iPhone have been confirmed on one instrument. If locking invalidates the decoder, CarWithin rebuilds it from a keyframe and resumes; a brief pause may occur. Extended playback, repeated locking, network-loss recovery, and other instruments have not all been verified.

## Check for updates and install a newer version

- About → Check for updates shows the latest release, including when your installed version is already current. Expand the full release notes or use Version history for older releases.
- Automatic checks run while the app is idle in the foreground, with a 24-hour interval after success and a 15-minute retry after failure. A new-version prompt offers Download, Later, and Ignore this version. Checks are deferred and package downloads restricted during a CarPlay session.
- After downloading and verifying the IPA, CarWithin opens the system share sheet. Open it in a compatible signing tool or save it to a folder you choose. Signing and installation are completed in that tool; CarWithin does not install the IPA itself.
- When upgrading from 1.0.0, its older updater opens the GitHub release page. Download, sign, and install this version there; in-app downloading and sharing become available after upgrading.

## Troubleshooting

- **CarPlay stays on Connecting.** After about five seconds, the app shows a small hint. Try turning the iPhone Wi-Fi off and on and check the saved credentials. The hint does not interrupt startup.
- **The page will not open.** Check that CarPlay is running and the local receiver page is enabled. Confirm that the devices can reach each other and try the HTTP address first. If HTTPS shows a certificate error, follow the setup steps on the receiving device.
- **The page connects but shows no picture.** Try a different browser, H.264, a lower resolution, or a lower frame rate. X Browser played HTTP and HTTPS on a Redmi K30 5G in testing. Chrome 109 on the same device showed an H.265 decoding error. If switching pages exhausts the hardware decoder, restart the browser and try again.
- **The picture plays without sound.** Select Wi-Fi audio in the app, restart CarPlay, and use the browser's enable-audio button if it appears. Check the volume on the receiving device.
- **Check your version or report a problem.** Open **Settings → About** for the installed version, update check, and release history. For a bug report, include the device models, OS and browser versions, HTTP or HTTPS, codec and resolution, and any relevant lines from the app's diagnostic log. [Report an issue](https://github.com/xmz28/CarWithin/issues)

## How it works and license

A virtual accessory lets the iPhone connect to its local CarPlay receiver. CarWithin presents video and audio generated by iOS and sends touch events back. The browser receives the video over WebSocket, using MSE for compatibility or WebCodecs for low-latency decoding where supported.

CarWithin is based on tds-car-kit. The combined distribution is licensed under AGPL-3.0-only; underlying GPL-3.0-or-later code and third-party components retain their own licenses. See LICENSE and THIRD_PARTY_NOTICES.txt. The CarLife implementation is adapted from [OpenXPlay-Stream](https://github.com/OpenXPlay/OpenXPlay-Stream) under AGPL-3.0-only. Protocol work draws on [PlayPort](https://github.com/youcci/playport), [DiPlay](https://github.com/shihabal3amri/DiPlay), and [xcertplay](https://github.com/shilapi/xcertplay). The project also uses the MIT-licensed [BigInt](https://github.com/attaswift/BigInt) library. CarWithin is an independent project and has no official affiliation with Apple.


## Author and support

### ☕ Buy me a coffee

CarWithin started as a small side project. Thank you to everyone who shared their experience and helped me spot device compatibility and display issues. If CarWithin has been useful to you, you're welcome to buy me a coffee to support ongoing development, testing, and maintenance.

| Alipay QR code | WeChat appreciation code |
| :---: | :---: |
| <img src="docs/support/alipay.png" alt="Alipay QR code" width="156"> | <img src="docs/support/wechat.png" alt="WeChat appreciation code" width="156"> |
| [Open the Alipay link](https://qr.alipay.com/fkx16608y1puemmltuocze0) | [View the full-size WeChat code](docs/support/wechat.png) |

Contributions are entirely optional. Downloads, features, and updates are available to everyone. Starring the project, sharing it, and reporting issues are also ways to help.

[Follow the author on Douyin](https://v.douyin.com/x64M2NbYj0A/)

Copyright © 2026 xmz28
