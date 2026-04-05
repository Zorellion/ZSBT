------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - Default Configuration Values
-- Every user-configurable setting with its factory default.
-- Structure mirrors the AceDB profile schema.
------------------------------------------------------------------------

local ADDON_NAME, ZSBT = ...

ZSBT.DEFAULTS = {
    profile = {
        ------------------------------------------------------------------------
        -- Tab 1: General
        ------------------------------------------------------------------------
        general = {
            enabled       = true,       -- Master enable/disable
            combatOnly    = false,      -- Only show text during combat
            perCharacterProfile = false,
			numberFormat = "none",
            notificationsEnabled = true,
            instanceAwareOutgoing = true,
            strictOutgoingCombatLogOnly = false,
            quietOutgoingWhenIdle = true,
            quietOutgoingAutoAttacks = true,
			pvpStrictEnabled = true,
			pvpStrictDisableAutoAttackFallback = true,
			damageMeterOutgoingFallback = true,
			damageMeterIncomingFallback = true,
			autoAttackRestrictFallback = true,
			quickControlBarEnabled = false,
			quickControlBarPos = { x = 0, y = 220 },

			-- Minimap button (simple native button, no LDB libs)
			minimap = {
                hide  = false,
                angle = 220,
            },

            -- Master font settings
            font = {
                face    = "Friz Quadrata TT",   -- Default WoW font
                size    = 18,
                outline = "Thin",               -- None / Thin / Thick / Monochrome
                alpha   = 1.0,                  -- 0.0 - 1.0
            },

            -- Crit font overrides (falls back to master font if nil)
            critFont = {
                face    = nil,                  -- nil = use master font face
                size    = 28,                   -- Bigger for crits
                outline = "Thick",              -- Bolder outline
                scale   = 1.5,                  -- Scale multiplier vs normal
                useScale = false,
                anim = "Pow",
            },

            -- Suppress Blizzard's floating combat text on load
            suppressBlizzardFCT = true,
        },

        notifications = {
            combatState = false,
            enterCombat = true,
            leaveCombat = true,
			progress = true,
			lootItems = true,
			lootMoney = true,
			lootCurrency = true,
			tradeskillUps = true,
			tradeskillLearned = true,
			interrupts = true,
			caststops = false,
            cooldowns = true,
            auras = true,
            power = true,
            procs = true,
            triggers = true,
        },

		notificationsRouting = {
			combatState = "Notifications",
			enterCombat = "Notifications",
			leaveCombat = "Notifications",
			progress = "Notifications",
			lootItems = "Notifications",
			lootMoney = "Notifications",
			lootCurrency = "Notifications",
			tradeskillUps = "Notifications",
			tradeskillLearned = "Notifications",
			interrupts = "Notifications",
			caststops = "Notifications",
			cooldowns = "Notifications",
			auras = "Notifications",
			power = "Notifications",
			procs = "Notifications",
			triggers = "Notifications",
		},

		notificationsTemplates = {
			combatState = "%e",
			enterCombat = "%e",
			leaveCombat = "%e",
			progress = "%e",
			lootItems = "+%a %e (%t)",
			lootMoney = "+%e",
			lootCurrency = "+%a %e (%t)",
			tradeskillUps = "%e +%a (%t)",
			tradeskillLearned = "Learned: %e",
			interrupts = "%t Interrupted!",
			caststops = "%t Interrupted!",
			cooldowns = "%e",
			auras = "%e",
			power = "%e",
			procs = "%e",
			triggers = "%e",
		},

		notificationsPerType = {
			combatState = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
			enterCombat = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None", stopOnLeaveCombat = false } },
			leaveCombat = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
			progress = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
			lootItems = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
			lootMoney = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
			lootCurrency = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
			tradeskillUps = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
			tradeskillLearned = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
			cooldowns = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
			auras = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
			power = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
			procs = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
			triggers = { style = { fontOverride = false }, sound = { enabled = false, soundKey = "None" } },
		},

		interruptAlerts = {
			scrollArea = "Notifications",
			color = { r = 1.0, g = 0.6, b = 0.0 },
			fontOverride = false,
			fontFace = "Friz Quadrata TT",
			fontOutline = "Thin",
			fontSize = 18,
			soundEnabled = false,
			sound = "None",
			chatEnabled = false,
			chatChannel = "SAY",
			chatTemplate = "%p %s interrupted %t!",
		},

		loot = {
			alwaysShowQuestItems = true,
			showCreated = false,
			qualityExclusions = {},
			itemExclusions = {},
			itemsAllowed = {},
		},

        ------------------------------------------------------------------------
        -- Tab 2: Scroll Areas
        ------------------------------------------------------------------------
        scrollAreas = {
            ["Outgoing"] = {
                xOffset   = 250,
                yOffset   = -10,
                width     = 100,
                height    = 300,
                alignment = "Center",
                direction = "Up",
                animation = "Parabola",
                parabolaSide = "Right",
                animSpeed = 1.0,
            },
            ["Incoming"] = {
                xOffset   = -250,
                yOffset   = -10,
                width     = 100,
                height    = 300,
                alignment = "Center",
                direction = "Up",
                animation = "Parabola",
                parabolaSide = "Left",
                animSpeed = 1.0,
            },
            ["Notifications"] = {
                xOffset   = 0,
                yOffset   = 200,
                width     = 300,
                height    = 100,
                alignment = "Center",
                direction = "Up",
                animation = "Straight",
                animSpeed = 1.0,
            },
        },

        ------------------------------------------------------------------------
        -- Tab 3: Incoming
        ------------------------------------------------------------------------
        incoming = {
            damage = {
                enabled       = true,
                scrollArea    = "Incoming",
				critScrollArea = nil,
                showFlags     = true,
                minThreshold  = 0,
                showMisses    = true,
            },
            healing = {
                enabled       = true,
                scrollArea    = "Incoming",
				critScrollArea = nil,
                showHoTTicks  = true,
                showOverheal  = false,
                minThreshold  = 0,
            },
            showSpellIcons  = false,
            useSchoolColors = true,
            customDamageColor  = { r = 1, g = 1, b = 1 },
            customHealingColor = { r = 1, g = 1, b = 1 },
            customColor     = { r = 1, g = 1, b = 1 },
        },

        ------------------------------------------------------------------------
        -- Tab 4: Outgoing
        ------------------------------------------------------------------------
        outgoing = {
            useBlizzardFCTInstead = false,
            damage = {
                enabled        = true,
                scrollArea     = "Outgoing",
                showTargets    = false,
                autoAttackMode = "Show All",
                minThreshold   = 0,
                showMisses     = true,
            },
            healing = {
                enabled       = true,
                scrollArea    = "Outgoing",
                showOverheal  = false,
                minThreshold  = 0,
            },
            crits = {
                enabled = false,
                scrollArea = "Outgoing",
                sticky = true,
                color = { r = 1.00, g = 1.00, b = 0.00 },
                soundEnabled = false,
                sound = "None",
                minSoundAmount = 0,
                instanceSoundMode = "Only when amount is known",
            },
            showSpellNames = false,
            showSpellIcons = false,
            useSchoolColors = true,
            customDamageColor  = { r = 1, g = 1, b = 1 },
            customHealingColor = { r = 1, g = 1, b = 1 },
        },

        ------------------------------------------------------------------------
        -- Tab 5: Pets
        ------------------------------------------------------------------------
        pets = {
            enabled       = true,
            scrollArea    = "Outgoing",
            aggregation   = "Generic (\"Pet Hit X\")",
            minThreshold  = 0,
            mergeWindowSec = 0,
            showCount = true,
			outgoingDamageColor = { r = 1.00, g = 1.00, b = 1.00 },
			outgoingCritColor = { r = 1.00, g = 1.00, b = 0.00 },
            showHealing = false,
            healScrollArea = "Outgoing",
            healMinThreshold = 0,
			incomingHealColor = { r = 0.60, g = 0.80, b = 0.60 },
			incomingHealCritColor = { r = 0.80, g = 1.00, b = 0.00 },
			showIncomingDamage = false,
			incomingDamageScrollArea = "Pet Incoming",
			incomingDamageMinThreshold = 0,
			incomingDamageColor = { r = 1.00, g = 0.30, b = 0.30 },
			incomingDamageCritColor = { r = 1.00, g = 0.80, b = 0.20 },
        },

        ------------------------------------------------------------------------
        -- Tab 6: Spam Control
        ------------------------------------------------------------------------
        spamControl = {
            merging = {
                enabled     = true,
                window      = 1.5,
                showCount   = true,
            },
            whirlwindAggregate = {
                enabled = true,
                window = 0.60,
                showCount = true,
            },
            auraGlobal = {
                showUnconfiguredGains = true,
                showUnconfiguredFades = true,
            },
            routing = {
                spellRulesDefaultArea = "Outgoing",
                auraRulesDefaultArea = "Notifications",
            },
            templates = {
                autoApplyOnSpecChange = false,
                applyAllSpecs = true,
            },
            throttling = {
                minDamage     = 0,
                minHealing    = 0,
                hideAutoBelow = 0,
            },
            pulseEngine = {
                maxBucketSize   = 120,
                maxWorkPerPulse = 80,
            },
            suppressDummyDamage = false,
        },

        ------------------------------------------------------------------------
        -- Tab 7: Cooldowns
        ------------------------------------------------------------------------
        cooldowns = {
            enabled    = true,
            scrollArea = "Notifications",
            format     = "%s Ready!",
            sound      = "None",
			showSpellIcon = false,
            tracked    = {},
        },

        ------------------------------------------------------------------------
        -- Tab 8: Media
        ------------------------------------------------------------------------
        media = {
            sounds = {
                lowHealth     = "None",
                cooldownReady = "None",
            },
            custom = {
                fonts = {
                    -- [displayName] = "path"
                },
                sounds = {
                    -- [displayName] = "path"
                },
            },
            schoolColors = {
                physical = { r = 1.00, g = 1.00, b = 0.00 },
                holy     = { r = 1.00, g = 0.90, b = 0.50 },
                fire     = { r = 1.00, g = 0.30, b = 0.00 },
                nature   = { r = 0.30, g = 1.00, b = 0.30 },
                frost    = { r = 0.40, g = 0.80, b = 1.00 },
                shadow   = { r = 0.60, g = 0.20, b = 1.00 },
                arcane   = { r = 1.00, g = 0.50, b = 1.00 },
            },
        },

        ------------------------------------------------------------------------
        -- Diagnostics
        ------------------------------------------------------------------------
        diagnostics = {
            debugLevel     = 0,
            cooldownsDebugLevel = 0,
            captureEnabled = false,
            maxEntries     = 1000,
            qHead          = 1,
            qTail          = 0,
            qCount         = 0,
            log            = {},
        },
    },
    char = {
        ui = {
            help = {
                expanded = false,
                selected = "gettingStarted",
            },
            configWindow = {
                width = 900,
                height = 820,
            },
        },
        spamControl = {
            spellRules = {
                -- [spellID] = { enabled=true, throttleSec=0.20 }
            },
            auraRules = {
                -- [spellID] = { enabled=true, throttleSec=0.00, suppressGain=false, suppressFade=false }
            },
        },
        cooldowns = {
            tracked = {},
        },
        triggers = {
            enabled = true,
            items = {
                -- { id="...", enabled=true, eventType="AURA_GAIN", spellId=123, throttleSec=0, action={text="{spell}!", scrollArea="Notifications", sound="None", color={r=1,g=1,b=1}} }
            },
        },
    },
    global = {
        migrations = {
            rulesToChar_v1 = false,
        },
    },
}
