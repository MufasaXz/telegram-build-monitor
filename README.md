# telegram-build-monitor

Android ROM build updates in Telegram.

Set it up once. After that, every `m` / `mka` build posts progress, uploads the
finished ROM, and sends the build log if something fails. Updates can go to your
**DM** or a **group** — you choose during setup.

```
⚙️ Build In Progress for Clover on raphael
📊 Progress: [██████░░░░] 61%
   Actions: 61234/100000
⏳ Elapsed: 00h 42m 11s
⏱️ ETA: 00h 26m 38s
```

## Setup

**1. Create a bot**

Open Telegram, message **@BotFather**, send `/newbot`, and copy the token it
gives you.

**2. Run the installer on your build server**

```bash
git clone https://github.com/MufasaXz/telegram-build-monitor.git
cd telegram-build-monitor
./install.sh
```

The installer does the rest:

- installs the Python dependency if needed
- asks for the bot token
- asks where to send: your DM or a group
- finds the chat/user automatically, or asks for the id
- sends a test message
- installs everything to `~/.ci` and hooks `~/.bashrc`
- checks that the hook loads in a new shell

If you ran the installer in the same terminal you build from, load the hook
there too:

```bash
source ~/.bashrc
```

For **DM**, open a private chat with your bot and press **Start** when the
installer asks.

For a **group**, add the bot to the group and send `/start@your_bot` when asked.
Make the bot an admin if you want the success message pinned.

If automatic detection fails, the installer asks for the id. You can get your
own id from **@userinfobot**; group ids are negative (for example
`-1001234567890`).

**3. Build normally**

Open a new shell, then:

```bash
source build/envsetup.sh
lunch <combo>
mka bacon
```

That's it.

## What gets posted

- **Progress:** one message, edited in place with percentage, actions, speed,
  elapsed time and ETA.
- **Success:** ROM name and size, then download buttons for GoFile, PixelDrain
  (if configured), `boot.img`, `vendor_boot.img` and `dtbo.img`.
- **Failure:** the ROM error log, or the full build log, sent as a file.
- **Stopped:** if the terminal or SSH session dies, the build is reported as
  stopped.
- **Nothing:** if `m`/`mka` did not actually start a build, the bot stays quiet.

## Settings

The installer creates `~/.ci/config.env` (mode `600`):

| Key | Meaning |
| --- | --- |
| `BOT_TOKEN` | Token from BotFather. |
| `SEND_TO` | `dm` or `group`. |
| `USER_ID` | Your Telegram user id, used when `SEND_TO=dm`. |
| `CHAT_ID` | Group id, used when `SEND_TO=group`. |
| `PIXELDRAIN_API` | Optional second upload mirror. Leave empty to skip. |

To switch between DM and group later, edit `SEND_TO` and the matching id in
`config.env`, or delete the file and run `./install.sh` again.

GoFile is used automatically, so no key is needed for the first mirror.

## If something does not work

- **No message at all:** a terminal that was open before installing does not
  have the hook. Run `source ~/.bashrc` in it, or open a new terminal. In a
  build tree, `type m` should contain `_ci_run`. Make sure you are not running
  with `_CI_DISABLED=1`.
- **DM not found:** open the bot in Telegram and press **Start** first. Bots
  cannot message you until you do.
- **Group not found:** add the bot to the group and send `/start@your_bot`.
- **Messages fail:** check `~/.ci/state/monitor-*.out`; Telegram errors are
  printed there.
- **Building from a script or non-interactive SSH:** source the hook after
  envsetup, or it is never installed:
  `source build/envsetup.sh && source ~/.ci/autohook.sh`
- **No pin:** the bot must be an admin with the "Pin messages" permission.
- **Disable for one shell:** `export _CI_DISABLED=1`

Build logs are in `~/.ci/state/`.

## Files

| File | Purpose |
| --- | --- |
| `install.sh` | One-step setup. |
| `autohook.sh` | Wraps `m`, `mka` and `ax`, starts the monitor. |
| `monitor.py` | Follows the build and talks to Telegram. |
| `README.md` | This file. |

## Security

`config.env` contains your bot token, is readable only by you, and is never
committed. If the token leaks, use `/revoke` in BotFather and run the installer
again.
