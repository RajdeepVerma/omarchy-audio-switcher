# Sound Switcher

An [Omarchy](https://omarchy.org/) Quattro shell plugin that switches between **audio profiles**. Each profile selects an output sink and an input source, and can be activated with its own hotkey. The bar icon cycles through profiles on right-click.

## Features

- **Profiles** — each has a name, an icon, an output sink, an optional input source, and a hotkey.
- **Bar widget** — left-click opens the panel; right-click cycles to the next profile.
- **Global keybinds** — assign *Previous profile*, *Next profile*, *Toggle sound mute*, and *Toggle mic mute*.
- **Per-profile hotkeys** — jump straight to a profile.
- **Mute indicators** — profile rows show sound and microphone mute state; click to toggle.
- **Notifications** — optional; bottom-center, top-right, or off.
- **Persistence** — the last active profile is restored after a reboot.

## Requirements

- Omarchy Quattro (the Quickshell-based shell).
- PipeWire + WirePlumber (the standard Omarchy audio stack).
- Uses Omarchy-provided helpers: `omarchy-audio-output-set-default`, `omarchy-audio-input-set-default`, `omarchy-osd`, and `omarchy-notification-send`.

## Install

```sh
omarchy plugin add https://github.com/solkkku/omarchy-audio-switcher.git --enable
```

Optionally move the widget in the bar:

```sh
omarchy bar move io.github.solkkku.audio-switcher --section right
```

## Usage

Left-click the bar icon to open the panel.

- **Add a profile** — click the **+** in the header and fill in name, icon, output source, input source (optional), and hotkey.
- **Edit / delete** — use the pencil and X buttons on a row; deletion asks for confirmation.
- **Reorder** — click and hold a row, then drag it to a new position.
- **Global keybinds** — open the **Options** (cog) page and assign key combos. While capturing a key, press `Esc` to cancel or `Del` to clear it.
- **Notifications** — choose off, top-right, or bottom-center on the Options page.

Hotkeys are written to a managed block in `~/.config/hypr/bindings.lua` and applied automatically.

## Configuration

Settings are stored inline on the plugin's entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "io.github.solkkku.audio-switcher",
  "cycleHotkey": "SUPER + F11",
  "previousHotkey": "SUPER + F10",
  "micMuteHotkey": "",
  "outputMuteHotkey": "",
  "notificationPosition": "off",
  "profiles": [
    {
      "name": "Headphones",
      "output": "alsa_output.pci-0000_00_1f.3.analog-stereo",
      "input": "alsa_input.pci-0000_00_1f.3.analog-stereo",
      "hotkey": "SUPER + F9",
      "icon": "󰋋"
    }
  ]
}
```

## Notes

- Silencing a sink owned by an external software mixer (e.g. GoXLR/OpenXLR) can be reverted by that mixer, so muting such a sink is best-effort. This affects any tool on the system, including Omarchy's own volume keys.
- The plugin is a `service` (logic, persistence, hotkey sync), a `bar-widget` (the panel), and a `panel` (the notification toast).

## Remove

```sh
omarchy plugin remove io.github.solkkku.audio-switcher
```

## License

MIT
