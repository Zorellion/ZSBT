-- TEST ONLY: forces AceLocale to load a specific locale regardless of client language.
-- To use: uncomment the "Locales\\ForceLocale.lua" line in ZSBT.toc (must stay
-- BEFORE libs\\AceLocale-3.0\\AceLocale-3.0.lua), set FORCED_LOCALE below,
-- then /reload. Re-comment the toc line to disable.
-- NOTE: while active, other AceLocale addons loaded after ZSBT may also pick
-- up the forced locale, and Blizzard UI calls to GetLocale() see the fake value.

local FORCED_LOCALE = "enUS" -- enUS deDE esES frFR itIT ptBR ruRU zhCN koKR

if FORCED_LOCALE ~= "enUS" then
    GetLocale = function() return FORCED_LOCALE end
end
