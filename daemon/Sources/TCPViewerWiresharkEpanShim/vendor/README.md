# Vendored GPL file from Wireshark

`ipaddr/ipaddr.c` comes from the Wireshark source tree (pinned submodule SHA
`3a22c3e`, Wireshark 4.6.6) at `plugins/epan/dfilter/ipaddr/ipaddr.c`.

- SPDX-License-Identifier: GPL-2.0-or-later
- Copyright 2023, João Valverde <j@v6e.pt>; Wireshark/Gerald Combs

It is compiled into the embedded shim because the upstream core's
plugin-free design requires the `ip.addr` display-filter functions to be
registered in-process (see `WiresharkIPDisplayFilterPlugin.c`).

One adaptation: the include of `<epan/iana-ip.h>` was changed to
`<epan/iana-info.h>` — Wireshark 4.7 renamed the header (the
`ws_iana_ip_special_block` struct layout is byte-identical between the two
versions; verified against v4.7.3). Using the system header guarantees the
struct always matches the linked libwireshark.

This project is GPL-2.0-or-later, so embedding this file is
license-compatible. The Wireshark system libraries are used unmodified via
their public headers (`/usr/include/wireshark`).
