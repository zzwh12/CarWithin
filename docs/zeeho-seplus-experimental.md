# ZEEHO SE+ experimental output

This adds a separate SE+ 5/5.5-inch output to the existing ZEEHO 6.2-inch mode. Existing output IDs 0–7 remain unchanged; SE+ is appended as ID 8.

## Behavior

- Both ZEEHO modes can discover the instrument IPv4 address. Discovery prioritizes a previously successful address in the current subnet, likely gateway addresses, then the local /24. Probes have bounded concurrency and timeouts. Successful media negotiation is required before remembering an address. Each mode has its own automatic/manual switch, and existing manual addresses are retained.
- SE+ responds with the valid even dimensions reported by the instrument, bounded to 1920×1080 landscape. The reported 1600×770 resolution is included in the tests.
- The SE+ source canvas can be 1600×770 or the previous 800×480. The wider source avoids adding side bars solely because the original source and instrument have different aspect ratios. Instrument firmware status bars are outside this setting.
- SE+ supports 25/30/60 FPS targets. New settings default to 30 FPS; saved choices are retained. Compatibility transcoding uses 2.5/3/6 Mbit/s respectively. 60 FPS also requests a 60 FPS source from CarPlay.
- Compatibility transcoding remains the default. H.264 passthrough is an explicit experiment. It preserves the source coding profile and bitrate, checks parameter sets and dimensions, and sends compressed frames in order. On buffer overflow it discards the dependent group and requests IDR, rather than dropping arbitrary P-frames. A 25 FPS target uses transcoding because CarPlay advertises a minimum 30 FPS source. A source/instrument size mismatch falls back to transcoding.
- Five observed MotoPlay notifications receive identifier-preserving empty acknowledgements in SE+ only. Semantic commands and replies retain their existing handlers.
- While SE+ is inactive, local preview and automatic PiP are paused before local decoder recovery can repeatedly request keyframes. Instrument forwarding and the existing background keep-alive continue. Returning to the foreground restores preview.
- The sound page exposes the current iOS output route and the system route picker. It does not force output to the phone speaker or claim to repair an earphone connection that also fails during normal music playback.

## Preserving the 6.2-inch path

The 6.2-inch connection, wire codec, and video output from v1.0.3 are isolated in `App/Zeeho62Legacy.swift`. The output and wire codec bodies are unchanged. The connection only adds the optional IP-discovery prelude, reuses the discovered announcement socket, and remembers an address after successful negotiation. Its video settings remain 1024×480, 25 FPS, 2.5 Mbit/s.

`Legacy62Original` retains the original source snapshots and Git blob/SHA-256 references. `Tools/verify_legacy62.py` checks the restored bodies, allows only those discovery changes in the connection, and checks the unchanged shared socket/identity and byte helpers. Existing upstream shared video codec helpers are retained.

## Evidence and limits

A user has confirmed an image on a CFDL29 instrument after the SE+ media handshake reported 1600×770. A later 60 FPS transcoding log reported roughly 33–52 sent FPS initially, then much lower rates around repeated keyframe recovery and a `-12903` encoder-session failure during background/lock transitions, followed by a pull-request timeout.

Those observations validate the earlier handshake and an image, not the newer passthrough or lock-screen behavior. Full-width presentation, sustained 60 FPS, passthrough compatibility, long runs, and earphone playback still need physical-device testing. The source H.264 profile and bitrate may exceed what an instrument accepts; switch back to compatibility transcoding if passthrough fails. Check that **Allow CarPlay While Locked** is enabled on the source iPhone.

Sent FPS describes network throughput, not panel refresh. Transcoding may repeat a static image. Passthrough logs source FPS, sent FPS, pull wait, write time, and dropped groups to distinguish source, network, and instrument backpressure.

## Validation

```sh
python3 Tools/verify_legacy62.py
bash Tools/test_zeeho_seplus.sh
bash Tools/test_tailing_discovery.sh
bash Tools/test_zeeho_control.sh
```

The portable tests cover canvas/FPS settings, the 25 FPS fallback, frame order, frame/byte bounds, IDR recovery, 1,000 sequential frames, instrument dimensions, media reply bytes, aspect fitting, discovery candidate boundaries, and SE+-only acknowledgements. Apple-platform integration tests and actual instrument tests are separate.

This contribution includes no accessory private keys, certificates, signing material, IPAs, or personal logs. Configure runtime authentication through the project's existing local workflow.
