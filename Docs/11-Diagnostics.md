# Diagnostics

Diagnostics controls debug logging.

## Where to configure
- `/zsbt` -> `Diagnostics`
- Or open the dedicated Debug UI from `/zsbt` -> `Help and Support` -> `Troubleshooting` -> `Open Debug UI`.

## Debug levels (0-5)
- Use higher levels only when troubleshooting.
- Higher values produce more chat spam.

Levels:
- `0` Off
- `1` Error
- `2` Warn
- `3` Info
- `4` Debug
- `5` Trace

## Debug channels
ZSBT supports per-feature debug channels so you can turn on logging for only the subsystem you’re debugging.

Common channels:
- `cooldowns`
- `outgoing`
- `incoming`
- `triggers`
- `notifications`
- `core`
- `ui`
- `diagnostics`
- `safety`
- `perf`

## Recommended bug report flow
- Set debug level for the relevant channel.
- Reproduce the issue once.
- Copy/paste the relevant `ZSBT:` lines.
- Set debug level back to `0`.

## Helpful commands
- `/zsbt debug show` Show current default + per-channel levels
- `/zsbt debug <0-5>` Set global default debug level
- `/zsbt debug <channel> <0-5>` Set a per-channel debug level
- `/zsbt cddebug <0-5>` Alias for `/zsbt debug cooldowns <0-5>`

Examples:
- Cooldowns trace: `/zsbt debug cooldowns 5`
- Outgoing attribution debug: `/zsbt debug outgoing 4`
- Turn everything off: `/zsbt debug 0`

## Tips
- If you’re reporting a bug, set debug level higher, reproduce once, then copy the relevant `ZSBT:` lines.
- Reset debug level back to `0` after troubleshooting.
