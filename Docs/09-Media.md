# Media

Media controls sound events and custom media registration.

## Where to configure
- `/zsbt` -> `Media`

## Sound events
- Choose sounds for built-in events like:
  - Low Health Warning
  - Cooldown Ready

## Custom media
If you have your own font or sound file, you can register it in the `Custom Media` section.

### Step-by-step: add a custom font
1. **Get a font file**
   - Format: `.ttf`
2. **Put the file in the ZSBT fonts folder**
   - Copy your font file to:
     - `World of Warcraft\_retail_\Interface\AddOns\ZSBT\Media\Fonts\`
   - Example:
     - `...\ZSBT\Media\Fonts\MyFont.ttf`
3. **Open the Media tab**
   - Type `/zsbt`
   - Click `Media`
4. **Register the font in ZSBT**
   - Find the `Custom Media` section.
   - Fill in:
     - `Custom Font Name`
       - This is what you will see in dropdowns.
       - Example: `My Font`
     - `Font Filename`
       - Enter the filename **without** the extension.
       - Example: if the file is `MyFont.ttf`, type `MyFont`
   - Click `Add Font`.
5. **Use the font**
   - Go to `General` (master font) or `Scroll Areas` (per-area font override).
   - Your custom font should appear in the font dropdown.

### Step-by-step: add a custom sound
1. **Get a sound file**
   - Format: `.ogg`
2. **Put the file in the ZSBT sounds folder**
   - Copy your sound file to:
     - `World of Warcraft\_retail_\Interface\AddOns\ZSBT\Media\Sounds\`
   - Example:
     - `...\ZSBT\Media\Sounds\MySound.ogg`
3. **Open the Media tab**
   - Type `/zsbt`
   - Click `Media`
4. **Register the sound in ZSBT**
   - Find the `Custom Media` section.
   - Fill in:
     - `Custom Sound Name`
       - This is what you will see in dropdowns.
       - Example: `My Alert Sound`
     - `Sound Filename`
       - Enter the filename **without** the extension.
       - Example: if the file is `MySound.ogg`, type `MySound`
   - Click `Add Sound`.
5. **Test the sound**
   - Still on the `Media` tab, pick your sound for an event like `Cooldown Ready`.
   - Click `Play Sound`.

### Do you need to /reload?
- If you **only register** media that’s already in the folders, you usually don’t need to.
- If you **add new files** while the game is running and they don’t show up, do a `/reload`.

### Common mistakes (quick checklist)
- **Wrong folder**
  - Fonts must be in `ZSBT\Media\Fonts\`
  - Sounds must be in `ZSBT\Media\Sounds\`
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
