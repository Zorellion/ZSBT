\---

description: Release ZSBT version

\---



This skill performs a release pass for the \*\*live addon folder\*\* (`e:/Blizzard/World of Warcraft/\_retail\_/Interface/AddOns/ZSBT`).



\## Inputs

\- `VERSION`: the release version string (example: `2.2.4`)



\## Steps

1\. Verify version files match `VERSION`:

&#x20;  - `Core/Constants.lua` (`ZSBT.VERSION`)

&#x20;  - `ZSBT.toc` (`## Version:`)

&#x20;  - `CHANGELOG.md` has a top entry for `VERSION`



2\. Documentation sanity pass:

&#x20;  - Ensure docs reflect new/changed/removed options and behaviors.

&#x20;  - Minimum set to review:

&#x20;    - `Docs/06-Spam-Control.md`

&#x20;    - `Docs/07-Triggers.md`

&#x20;    - `Docs/14-Troubleshooting.md`

&#x20;    - `Docs/09-Media.md` if bundled media changed



3\. Packaging sanity pass:

&#x20;  - Confirm the `Media/` assets referenced by code are present on disk.

&#x20;  - Confirm LibSharedMedia registrations exist for bundled fonts/sounds.

&#x20;  - Confirm `ZSBT.toc` includes required files.



4\. In-game smoke test (manual):

&#x20;  - `/reload`

&#x20;  - Confirm addon loads with \*\*no Lua errors\*\*.

&#x20;  - Exercise:

&#x20;    - Incoming/Outgoing/Notifications scroll areas

&#x20;    - Triggers (at least one)

&#x20;    - Aura gain/fade suppression behaves as expected through a zoning/loading screen



5\. Release output:

&#x20;  - Ensure `CHANGELOG.md` entry for `VERSION` is accurate and user-facing.

&#x20;  - Update any release notes file if you maintain one (ex: `CurseForge-Overview.txt`) when needed.



6\. Sync live addon -> repo (Windows `robocopy`):

&#x20;  - \*\*Source\*\*: `e:\\Blizzard\\World of Warcraft\\\_retail\_\\Interface\\AddOns\\ZSBT`

&#x20;  - \*\*Dest\*\*: `e:\\REPOS\\ZSBT`

&#x20;  - Use `robocopy` mirror sync with exclusions:

&#x20;    - Exclude from \*\*dest\*\* (repo): `.git\\`, `.github\\`

&#x20;    - Exclude from \*\*sync\*\*: `.windusrf\\`, `.windsurf\\`, `Media\\`

&#x20;    - Exclude file: `.pkgmeta`

&#x20;  - Command:

&#x20;    - `robocopy "e:\\Blizzard\\World of Warcraft\\\_retail\_\\Interface\\AddOns\\ZSBT" "e:\\REPOS\\ZSBT" /MIR /XD ".git" ".github" ".windusrf" ".windsurf" "Media" /XF ".pkgmeta"`

&#x20;  - After sync, review robocopy output for unexpected deletes/copies.



7\. Git commit + tag (in `e:\\REPOS\\ZSBT`):

&#x20;  - `git status --short`

&#x20;  - `git add -A`

&#x20;  - `git commit -m "Release vVERSION"`

&#x20;  - Create annotated tag: `git tag -a vVERSION -m "vVERSION"`



8\. Push commit + tag:

&#x20;  - `git push origin main`

&#x20;  - `git push origin vVERSION`



\## Notes / Safety

\- Do not modify the repo copy (`e:/REPOS/ZSBT`) directly. Work only in the live addon folder.



