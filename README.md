<p align="center">
  <img src="docs/logo.png" alt="Reminders Spotlight" width="128">
</p>

<h1 align="center">Reminders Spotlight</h1>

<p align="center"><em>A Spotlight-style quick-entry app for Apple Reminders and Calendar on macOS. Press ⌥Space, make a note, and get back to the real work.</em></p>

<p align="center">
  <img src="docs/demo.gif" alt="Reminders Spotlight in action" width="640">
</p>

## Features

- **Spotlight-style entry**: A centered floating panel on '⌥Space', with access to Reminders mode or Calendar mode.
- **Reminders Mode** (default): Type Reminders in plain English and hit 'ENTER' to save your entry to Apple Reminders.
- **Calendar Mode**: With the '⌥Space' menu open, press 'UP' on your keyboard. This will switch the app to *Calendar Mode*. In Calendar Mode, type new Events in plain English and hit 'ENTER' to save your entry to Apple Calendar.
- **Natural language**: "Call X tomorrow 9am !!" sets the due date, time, and priority automatically; tags are recognized too.
- **`@` list shortcuts**: Define your own in *Settings → Shortcuts* (e.g. `@p` → Personal). Typing the shortcut routes the Reminder to that List (or the Event to that Calendar) and disappears from the text.
- **Move to browse, type to write**: Nudge the mouse and the panel expands to show all your Reminders or upcoming Events. Start typing and it collapses back so you can focus on what you're writing next.
- **Menu-bar dropdown** allows you to toggle which lists are shown, open various settings, or quit the application.
- **Quick checkmark** confirmation when a Reminder or Event is saved.

## Building

This project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
open RemindersSpotlight.xcodeproj
```

Or build, sign, and install to `/Applications` in one step:

```sh
./build_install.sh
```

(The script auto-detects your "Apple Development" signing identity; override with `RMB_SIGN_IDENTITY` if needed.)

## Credits & license

Reminders Spotlight is a fork of [**reminders-menubar**](https://github.com/DamascenoRafael/reminders-menubar) by Rafael Damasceno, reworked into a Spotlight-style quick-entry tool. Like the original, it is licensed under the **GNU General Public License v3** — see [LICENSE](LICENSE).
Reminders Spotlight was developed in part via Claude Code.
