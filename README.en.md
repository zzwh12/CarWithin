# CarWithin

**English** · [简体中文](README.md)

[![Platform: iOS 16.0+](https://img.shields.io/badge/iOS-16.0%2B-blue)](#download-and-install) [![Build iOS IPA](https://github.com/zzwh12/CarWithin/actions/workflows/build-ios.yml/badge.svg)](https://github.com/zzwh12/CarWithin/actions/workflows/build-ios.yml)

CarWithin runs CarPlay on the same iPhone that generates its interface. Use CarPlay directly on your iPhone for navigation and music, or send the display to a head unit, tablet, computer, or another phone on the local network. A receiving browser can send touch input back to CarPlay.

![CarWithin connection diagram showing playback on iPhone and output to a browser, wireless CarLife, compatible dashboards, or experimental AirPlay.](docs/images/carwithin-connections-en.png)

## Download and install

- Open a successful build for this branch and download the `CarWithin-iOS-unsigned` artifact. [Build iOS IPA](https://github.com/zzwh12/CarWithin/actions/workflows/build-ios.yml)
- Extract `CarWithin-unsigned.ipa` from the artifact and sign and install it with an IPA sideloading tool using your own signing setup. Follow any iOS prompts for developer trust or Developer Mode.
- The minimum installation target is iOS/iPadOS 16.0 on arm64; iOS 15 is not supported. Same-device CarPlay, audio, and background behavior still need testing on iOS 16.x hardware. CarWithin uses private iOS interfaces. Compatibility depends on the device, OS version, and signing setup, and OS updates can affect it.

## What is new in 1.0.5

- Added output profiles for ZEEHO SE+ 5/5.5-inch, AE2 Pro 5-inch, and CFMOTO 5/6.2-inch dashboards, with a reorganized output menu.
- Added optional ANT BMS telemetry and battery cards, disabled by default.
- Added English app and browser-receiver interfaces; some new dashboard messages still fall back to Chinese.
- Improved saved Wi-Fi passwords, CarLife discovery and AirPlay recovery, and added supporter and contributor views.

The maintainer checked existing functionality for regressions. The new ZEEHO, CFMOTO and ANT BMS paths still need corresponding hardware testing by the maintainer; builds and simulated protocol tests do not establish compatibility with every model.

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
- **Enter a custom size.** In Settings → Display → Screen size, choose **Custom Size**, enter the width and height in pixels (for example, 1920 × 720), and save. The next CarPlay session uses these dimensions. For CarbitLink this sets the local CarPlay picture size. The head unit negotiates the outgoing video dimensions separately.
- **Customize the vehicle button.** Use the vehicle settings to enable the button, pick a photo as its icon, or restore the default. Changes take effect when CarPlay starts again. In app fullscreen, use the vehicle button on the CarPlay home screen to exit. If the vehicle button is disabled, use the upper-left exit button.
- **Picture in Picture and background playback.** Choose when PiP should start in the Background and PiP section on the settings home page. The default is When leaving the app; you can also choose immediately after video appears or turn off automatic activation. For lock-screen use, enable **Allow CarPlay While Locked** under **Settings → General → CarPlay → CarWithin** on the iPhone. PiP shows live video. Use the app or browser for touch input. CarbitLink direct output uses its low-frame-rate preview in PiP.

## Wi-Fi presets and common settings

The top settings group includes User guide, Wi-Fi and network, Wi-Fi presets, Current output and Output settings. HTTPS settings appears when Browser output is selected.

Enter Wi-Fi credentials and go back to save them automatically. Enable the open-network option for a network without a password. Each SSID has one preset; editing its password updates that preset. Tap a saved preset when changing networks. Swipe to delete, then confirm; this also removes its saved password. The Wi-Fi form no longer rebuilds repeatedly while typing, reducing input stalls.

Some connection settings are locked while CarPlay is running; stop the session before editing them. Appearance, driving side, and audio are available on the settings home page. Logs are under Diagnostics and experiments; versions and updates are under About.

## Other output methods

- **Wireless CarLife.** For compatible head units, connect the head unit and iPhone to the same Wi-Fi. Select CarLife in CarWithin, open CarLife on the head unit, then start CarPlay. CarWithin can discover the head unit or use an IP address you enter. CarLife carries video and touch input, with H.264 up to 1080p at 30 FPS. Audio can play through the head unit's Bluetooth connection.
- **AirPlay (experimental).** Select AirPlay and start CarPlay. When the display is ready, use the AirPlay picker on the main screen to select a video receiver on the same network. AirPlay video is buffered. Touch input stays on the iPhone, and audio follows the iPhone or head unit Bluetooth route.

Fixed display sizes support common landscape and portrait aspect ratios.

### CarbitLink direct output (experimental)

1. Open the QR connection screen in the head unit's CarbitLink app. On iPhone, select **Settings → Current Output → CarbitLink Direct (Experimental)** in CarWithin. Open **Output Settings → Scan Head Unit QR Code** and tap the QR code in the camera view.
2. Join a Wi-Fi network that allows the iPhone and head unit to reach each other and select or save the matching Wi-Fi preset in CarWithin. Scanning fills in the head unit IP when the code contains a private IPv4 address. If it contains only a network name, download link or pairing token, use **Find Head Units on Wi-Fi** to select an advertised head unit or enter its known IP.
3. Start local CarPlay. Once the head unit accepts the iOS PXC session and requests video, the connection card shows the agreed resolution and format (H.264 or JPEG). Video is limited to 1920×1080; the default is 30 fps, and Settings → Display → CarbitLink Display → Frame rate can switch to 60 fps. CarbitLink 7.0.1 checks the H.264 macroblock dimensions for iOS connections, so CarWithin rounds both AVC dimensions down to multiples of 16. A 1440×3200 receiver gets a 480×1072 stream. On head units with touch return support, tap, drag, or use two fingers on the CarPlay picture. The iPhone also shows a touch-enabled low-frame-rate preview at up to 8 fps, and Picture in Picture can keep the session alive in the background. Audio plays through the iPhone or car Bluetooth.
4. If the receiver stays black, open **Settings → Output Settings → Send test bars for 5 seconds**. The bars fill the negotiated video frame, then CarPlay resumes. The **Carbit pixel sample** entry in the diagnostics log shows the size of the CarPlay content area and its peak pixel value before encoding.
5. If the head unit stutters, pan the map for about 10 seconds while parked and open **Diagnostics & Experiments → Logs**. Every five seconds, **Carbit sent** reports the reply rate, replies using a new source frame, video payload bitrate, and longest gap between sends. A static screen produces repeat replies. The longest pull wait, preparation time, and socket write help locate stalls.

An in-car test confirmed projection on a factory Ford Mondeo head unit. CarWithin connects with its own application identity and sends the local CarPlay picture. QR codes are processed on the iPhone. This mode requires local network projection support. Firmware that requires cloud pairing is unsupported. [Carbit connectivity overview](https://carbit.com.cn/new/connect)

### ZEEHO AE4 MAX2+ 6.2-inch display

Connect the iPhone to the instrument Wi-Fi, select the matching preset and choose ZEEHO 6.2-inch under Current output. Open projection on the instrument, then start CarPlay. Instrument IP discovery is enabled by default; turn it off under Output settings to use the retained manual address. Video uses H.264 at 1024×480 and up to 25 fps. Audio plays through the iPhone or Bluetooth. Operate CarPlay on the phone.

One instrument was tested successfully, including screen lock. Other models and long sessions require further testing.

### ZEEHO AE2 Pro 5-inch display

Connect the iPhone to the dashboard Wi-Fi, select the matching preset, then choose `极核 AE2 Pro 5 寸` under Current output. Start projection on the dashboard and start CarPlay in the app. The default dashboard address is `192.168.0.1`, configurable in Output settings. Video uses H.264 at the size reported by the dashboard, up to 25 fps. Projection was confirmed on one AE2 Pro.

### Additional dashboard support

- **Ninebot 7-inch:** Connect to the dashboard Wi-Fi, select this output, start CarPlay, then enable navigation casting in Ninebot app and keep it running in the background. Display was confirmed on one dashboard.
- **Ninebot 4.3-inch:** Uses the N1 90 protocol, with default address `192.168.169.1`. Follow the same startup order. Physical dashboard testing is pending.
- **AirPlay (experimental):** Startup and reconnection may fail, and the receiver may retain the last picture after stopping.

### ZEEHO SE+ 5/5.5-inch display

Choose the separate SE+ output. The 5/5.5-inch label names the intended profile family: one profile negotiates the reported pixel dimensions, rather than two independently verified physical-size implementations. Both ZEEHO modes offer automatic IP discovery and retain manual addresses. The 6.2-inch mode keeps its isolated original handshake/output at 1024×480 and 25 FPS.

SE+ offers a 1600×770 wide canvas or 800×480 compatibility canvas, plus 25/30/60 FPS targets. Start with 30 FPS and default compatibility transcoding. H.264 passthrough is opt-in and still needs instrument testing, as do sustained 60 FPS and lock-screen stability. Sent FPS is not panel refresh. The sound page provides the system audio route picker. See [implementation and validation scope](docs/zeeho-seplus-experimental.md).

### Ninebot 5-inch display

Connect the iPhone to the instrument Wi-Fi, select its saved Wi-Fi preset, and choose Ninebot 5-inch under Current output. Start CarPlay. If the dashboard has no picture, keep CarWithin running, enable projection navigation in the Ninebot app, then close the Ninebot app from the app switcher after the dashboard shows a picture and return to CarWithin. The default instrument IP is `192.168.1.1`, configurable under Output settings. Audio plays through the iPhone or Bluetooth; control CarPlay on the phone.

One instrument was tested with repeated backgrounding and screen locks. Perceived latency was approximately 500–600 ms. Other instrument versions need testing.

**Startup order: start local CarPlay in CarWithin first, then enable navigation casting in the Ninebot app.** Starting Ninebot casting first can occupy the local casting port. If you see `bind …:5012 failed: Address already in use (errno 48)`, stop CarWithin, exit navigation casting in the Ninebot app and other casting apps, then retry in that order. This error means a local port is occupied; if Wi-Fi also disconnects, include the startup log so it can be investigated separately. Whether the Ninebot app must remain running for a 5-inch dashboard varies by model. For 7-inch and 4.3-inch dashboards, keep it in the background as described in their sections.

### Tailing 4.3-inch display

This mode targets the **TL-DASH-V2** instrument display. Other models and firmware still need testing.

1. Connect the iPhone to the instrument's Wi-Fi and enter that network's credentials in Wi-Fi and network.
2. Select Tailing 4.3-inch under Current output. The instrument IP defaults to `192.168.1.1`; change it under Output settings if needed.
3. Enable mirroring on the instrument, exit other mirroring apps, and start local CarPlay in CarWithin. The connection card on the main screen shows its status.

The instrument receives 480×272 video at up to 20 FPS. Audio uses the iPhone's current speaker or Bluetooth route. The instrument does not send touch input back; operate CarPlay on the iPhone. Matching display parameters are applied automatically; switching to another output restores its previous settings.

Video and recovery after locking the iPhone have been confirmed on one instrument. If locking invalidates the decoder, CarWithin rebuilds it from a keyframe and resumes; a brief pause may occur. Extended playback, repeated locking, network-loss recovery, and other instruments have not all been verified.

### CFMOTO 5-inch and 6.2-inch dashboards

Join the dashboard Wi-Fi on the iPhone, select the corresponding CFMOTO output, enable dashboard projection and start CarPlay. Set the dashboard address in Output settings. Leaving it blank tries `.1` on the local subnet; this is a guess, not a discovered DHCP gateway. Enter the real address if it fails. A separate PXC session uses TCP 10920/10921/10922 and probe port 10930, with negotiated, aligned video dimensions. Audio and controls remain on the iPhone or its Bluetooth device. The maintainer has no CFMOTO dashboard, so connection, video and background behavior need hardware testing.

### ANT BMS battery cards

Enable reading under Settings → Battery & BMS and explicitly select the Bluetooth device. The feature is off by default and only queries telemetry; it does not change battery parameters. Configure fields, position, size and transparency for charge level, voltage, current, power, temperature and cell-voltage spread. Old values are hidden after five seconds without valid new data.

Cards currently appear in the phone CarPlay preview and Ninebot 5/7-inch video. Ninebot 4.3-inch, browser and other dashboard outputs do not include the card in this version. The maintainer has no ANT BMS hardware; connectivity, background behavior and model compatibility need testing. See [implementation scope](docs/ant-bms-display.md).

## Feedback, support and contributors

The Support section in Settings contains Diagnostics and experiments and About. Copy diagnostic logs from Diagnostics and experiments → Logs → Copy logs, and check for unrelated personal information before submitting them.

About → Appreciation & Support lists supporters and development/testing contributions. Support is optional and does not affect features, updates or adaptation priorities.

Code contributions in this release: [yiquchangge1](https://github.com/yiquchangge1) (SE+), [武汉 / yuliang-shuji](https://github.com/yuliang-shuji) (AE2 Pro), [Boos4721](https://github.com/Boos4721) (ANT BMS), and [扫毒单位 / SDDW007](https://github.com/SDDW007) (CFMOTO). Original commits and GitHub authorship are preserved.

## Release history

Open **Settings → About → Version history** to browse releases published by this fork. After stopping CarPlay, you can download an attached IPA, then share it with your signing tool or save it to Files.

## Troubleshooting

- **CarPlay stays on Connecting.** After about five seconds, the app shows a small hint. Try turning the iPhone Wi-Fi off and on and check the saved credentials. The hint does not interrupt startup.
- **The page will not open.** Check that CarPlay is running and the local receiver page is enabled. Confirm that the devices can reach each other and try the HTTP address first. If HTTPS shows a certificate error, follow the setup steps on the receiving device.
- **The page connects but shows no picture.** Try a different browser, H.264, a lower resolution, or a lower frame rate. X Browser played HTTP and HTTPS on a Redmi K30 5G in testing. Chrome 109 on the same device showed an H.265 decoding error. If switching pages exhausts the hardware decoder, restart the browser and try again.
- **The picture plays without sound.** Select Wi-Fi audio in the app, restart CarPlay, and use the browser's enable-audio button if it appears. Check the volume on the receiving device.
- **Check your version or report a problem.** Open **Settings → About** for the installed version and release history. For a bug report, include the device models, OS and browser versions, HTTP or HTTPS, codec and resolution, and any relevant lines from the app's diagnostic log. [Report an issue](https://github.com/xmz28/CarWithin/issues)

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
