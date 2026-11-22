# Media

Media controls sound events and custom media registration.

## Where to configure
- `/zsbt` -> `Display` -> `Media`

## Sound events
- Choose sounds for built-in events like:
  - Low Health Warning
  - Cooldown Ready

## Custom media
If you have your own font or sound file, you can register it in the `Custom Media` section.

**Important:** store your custom files in `Interface\CustomMedia\` — a folder
inside `Interface`, next to `Interface\AddOns`. Addon updaters wipe the `ZSBT`
folder on every update, so files inside `Interface\AddOns\ZSBT\Media\` can be
deleted. `Interface\CustomMedia\` is never touched by any addon manager.

Create it once and your files are safe forever:
- `Interface\CustomMedia\Fonts\` — font files (`.ttf`)
- `Interface\CustomMedia\Sounds\` — sound files (`.ogg`)

### Step-by-step: add a custom font
1. **Get a font file**
   - Format: `.ttf`
2. **Put the file in your custom fonts folder**
   - Copy your font file to:
     - `World of Warcraft\_retail_\Interface\CustomMedia\Fonts\`
   - Example:
     - `...\Interface\CustomMedia\Fonts\MyFont.ttf`
3. **Open the Media tab**
   - Type `/zsbt`
   - Click `Display` -> `Media`
4. **Register the font in ZSBT**
   - Find the `Custom Media` section.
   - Fill in:
     - `Custom Font Name`
       - This is what you will see in dropdowns.
       - Example: `My Font`
     - `Font Filename`
       - Enter the filename **without** the extension.
       - Example: if the file is `MyFont.ttf`, type `MyFont`
       - You can also enter any full `Interface\...` path if your file
         lives somewhere else.
   - Click `Add Font`.
5. **Use the font**
   - Go to `General` (master font) or `Display` -> `Scroll Areas` (per-area font override).
   - Your custom font should appear in the font dropdown.

### Step-by-step: add a custom sound
1. **Get a sound file**
   - Format: `.ogg`
2. **Put the file in your custom sounds folder**
   - Copy your sound file to:
     - `World of Warcraft\_retail_\Interface\CustomMedia\Sounds\`
   - Example:
     - `...\Interface\CustomMedia\Sounds\MySound.ogg`
3. **Open the Media tab**
   - Type `/zsbt`
   - Click `Display` -> `Media`
4. **Register the sound in ZSBT**
   - Find the `Custom Media` section.
   - Fill in:
     - `Custom Sound Name`
       - This is what you will see in dropdowns.
       - Example: `My Alert Sound`
     - `Sound Filename`
       - Enter the filename **without** the extension.
       - Example: if the file is `MySound.ogg`, type `MySound`
       - You can also enter any full `Interface\...` path if your file
         lives somewhere else.
   - Click `Add Sound`.
5. **Test the sound**
   - Still on the `Media` tab, pick your sound for an event like `Cooldown Ready`.
   - Click `Play Sound`.

### Do you need to /reload?
- If you **only register** media that’s already in the folders, you usually don’t need to.
- If you **add new files** while the game is running and they don’t show up, do a `/reload`.

### Common mistakes (quick checklist)
- **Wrong folder**
  - Fonts go in `Interface\CustomMedia\Fonts\`
  - Sounds go in `Interface\CustomMedia\Sounds\`
- **Typed the extension**
  - In `Font Filename` / `Sound Filename`, do **not** type `.ttf` or `.ogg`.
- **Filename mismatch**
  - Windows sometimes hides file extensions, so double-check the real filename.
- **Unsupported format**
  - Fonts: use `.ttf`
  - Sounds: use `.ogg`

### Troubleshooting
- If it doesn’t show up in dropdowns:
  - Confirm the file path and spelling.
  - `/reload`
  - Use `Currently Registered Media` on the `Media` tab to confirm it registered.

## Tips
- Keep custom media file names simple.
- Use `.ogg` for sounds.
