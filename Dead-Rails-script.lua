--// Dead Rails - Silent Aim with extendable FOV
--// Targets NPCs only (zombies, werewolves, outlaws, etc.), never players.
--// Your camera is never moved: the game's own shot is redirected to the target.
--// Press RightControl to hide/show the GUI.

----------------------------------------------------------------
-- (added) unload older builds from the generator so their hooks go quiet
----------------------------------------------------------------
do
    local e = (getgenv and getgenv()) or _G
    if e.DR_SilentAim then pcall(e.DR_SilentAim.Unload, true) e.DR_SilentAim = nil end
    if e.DR_ShopHelper then pcall(e.DR_ShopHelper.Unload, true) e.DR_ShopHelper = nil end
end

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService       = game:GetService("GuiService")
local Workspace        = game:GetService("Workspace")
local Stats            = game:GetService("Stats")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

-- All console output in this script goes through print / warn below, which are
-- SILENT by default. Turn "Console output" on in the Settings tab if you ever
-- want the debug text (vault codes, reports, remote logs) in the console again.
local Console = { on = false }
local rawprint, rawwarn = print, warn
local function print(...) if Console.on then rawprint(...) end end
local function warn(...) if Console.on then rawwarn(...) end end

----------------------------------------------------------------
-- UNLOAD SYSTEM
-- If an older copy of this script is still running, it is unloaded first,
-- then this copy takes its place. The Quit button calls the same function.
----------------------------------------------------------------
local env = (getgenv and getgenv()) or _G
if env.DeadRailsAimUnload then
    pcall(env.DeadRailsAimUnload)
end

-- Shared state read by the (single) silent-aim hooks. Lives in env so re-running the
-- script reuses the same hooks instead of stacking new ones.
env.DeadRailsSilent = env.DeadRailsSilent or {}
local Silent = env.DeadRailsSilent
Silent.active, Silent.point, Silent.part, Silent.log = false, nil, nil, false

local Running = true
local Connections = {}
local Gui -- assigned in the GUI section
local VaultFolder -- assigned in the VAULT ESP section

local function Unload()
    Running = false
    Silent.active, Silent.point, Silent.part, Silent.log = false, nil, nil, false
    pcall(function() RunService:UnbindFromRenderStep("DeadRailsAim") end) -- from older versions
    for _, c in pairs(Connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(Connections)
    if Gui then
        pcall(function() Gui:Destroy() end)
        Gui = nil
    end
    if VaultFolder then
        pcall(function() VaultFolder:Destroy() end)
        VaultFolder = nil
    end
    if env.DRCollect then env.DRCollect.part = nil end
    if env.DRReach then
        env.DRReach.on = false
        if env.DRReach.restore then pcall(env.DRReach.restore) end
    end
    if env.DRAirWeld then
        local a = env.DRAirWeld
        a.on, a.log, a.held, a.heldPos, a.train = false, false, nil, nil, nil
    end
    if env.DRVisual and env.DRVisual.restore then pcall(env.DRVisual.restore) end
    if env.DRReload and env.DRReload.restore then pcall(env.DRReload.restore) end
    if env.DeadRailsAimUnload == Unload then
        env.DeadRailsAimUnload = nil
    end
end
env.DeadRailsAimUnload = Unload

----------------------------------------------------------------
-- SILENT AIM HOOKS
-- Redirects the game's own shot (remote args / raycasts / mouse.Hit) to the target
-- WITHOUT moving your camera. Needs an executor with hookmetamethod support.
-- The remote-argument rewrite is heuristic: use "Log Gun Remotes" to see what the
-- game actually sends if shots don't land.
----------------------------------------------------------------
local HooksSupported = (hookmetamethod and getnamecallmethod and setnamecallmethod
    and checkcaller and newcclosure) and true or false

local IsA, IsDescendantOf, GetFullName = game.IsA, game.IsDescendantOf, game.GetFullName
local GUN_WORDS = { "shoot", "fire", "gun", "bullet", "hit", "weapon", "damage", "attack", "shot" }

local function looksLikeGunRemote(name)
    name = name:lower()
    for _, w in ipairs(GUN_WORDS) do
        if name:find(w, 1, true) then return true end
    end
    return false
end

-- Where the target will be at the moment the shot is fired: last known head position
-- pushed forward by the enemy's velocity over (time since sampled + lead).
local function getPoint()
    local base = Silent.base or Silent.point
    local vel  = Silent.vel or Vector3.zero
    local dt   = (os.clock() - (Silent.t or os.clock())) + (Silent.lead or 0)
    local shift = vel * dt
    if shift.Magnitude > 10 then shift = shift.Unit * 10 end -- sanity cap (studs)
    return base + shift
end

local function rewriteArgs(args)
    local camPos = Workspace.CurrentCamera.CFrame.Position
    local point, part = getPoint(), Silent.part
    local char = LocalPlayer.Character
    for i = 1, args.n do
        local a = args[i]
        local t = typeof(a)
        if t == "Vector3" then
            if math.abs(a.Magnitude - 1) < 0.02 then
                args[i] = (point - camPos).Unit                 -- looks like a direction
            elseif (a - camPos).Magnitude > 12 then
                args[i] = point                                 -- looks like a hit position
            end                                                 -- else: origin, leave it
        elseif t == "CFrame" then
            if (a.Position - camPos).Magnitude > 12 then
                args[i] = CFrame.new(point)
            else
                args[i] = CFrame.new(a.Position, point)
            end
        elseif t == "Instance" and IsA(a, "BasePart") and not (char and IsDescendantOf(a, char)) then
            args[i] = part                                      -- the "what did I hit" part
        end
    end
end

if HooksSupported and not env.DeadRailsHooked then
    env.DeadRailsHooked = true
    local mouse = LocalPlayer:GetMouse()
    local lastLog = {}

    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if (Silent.active or Silent.log) and not checkcaller() then
            if method == "FireServer" and IsA(self, "RemoteEvent") then
                local args = table.pack(...)
                local name = self.Name
                if Silent.log then
                    local now = os.clock()
                    if not lastLog[name] or now - lastLog[name] > 0.5 then
                        lastLog[name] = now
                        local parts = {}
                        for i = 1, args.n do
                            parts[i] = typeof(args[i]) .. ":" .. tostring(args[i])
                        end
                        print("[DeadRailsAim] FireServer " .. GetFullName(self) .. "(" .. table.concat(parts, ", ") .. ")")
                    end
                end
                if Silent.active and Silent.point and looksLikeGunRemote(name) then
                    pcall(rewriteArgs, args)
                    setnamecallmethod(method)
                    return oldNamecall(self, table.unpack(args, 1, args.n))
                end
                setnamecallmethod(method)
            elseif method == "Raycast" and Silent.active and Silent.point and self == Workspace then
                local origin, direction, params = ...
                if typeof(origin) == "Vector3" and typeof(direction) == "Vector3"
                    and direction.Magnitude >= 80
                    and (origin - Workspace.CurrentCamera.CFrame.Position).Magnitude < 25 then
                    setnamecallmethod(method)
                    return oldNamecall(self, origin, (getPoint() - origin).Unit * direction.Magnitude, params)
                end
            end
        end
        return oldNamecall(self, ...)
    end))

    local oldIndex
    oldIndex = hookmetamethod(game, "__index", newcclosure(function(self, key)
        if Silent.active and Silent.point and self == mouse and not checkcaller() then
            if key == "Hit" then
                return CFrame.new(getPoint())
            elseif key == "Target" then
                return Silent.part
            end
        end
        return oldIndex(self, key)
    end))
end

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local Config = {
    Silent      = false,   -- master toggle
    AimPart     = "Head",  -- "Head" or "Torso"
    FOV         = 400,     -- px radius around the crosshair (extendable up to 3000)
    Unlimited   = false,   -- ignore the circle: pick the enemy closest to where you look,
                           -- even off-screen or behind you (range limited by MaxDistance)
    MaxDistance = 400,     -- studs, enemies farther than this are ignored
    WallCheck   = true,
    Lead        = true,    -- lead moving enemies (fast ones like werewolves)
    AutoLead    = true,    -- pick the lead automatically from your live ping
    LeadTime    = 0.02,    -- extra seconds of lead added on top of the auto lead
    ShowFOV     = true,
    LogRemotes  = false,   -- print gun remotes + args to the console (F9)
    Targets     = {        -- which enemy types to target
        Zombie   = true,
        Werewolf = true,
        Outlaw   = true,
        Other    = true,
    },
}

-- Name keywords used to classify an NPC. Edit these if enemy names differ.
local Keywords = {
    Zombie   = { "zombie", "runner", "walker", "undead", "ghoul" },
    Werewolf = { "werewolf", "wolf" },
    Outlaw   = { "outlaw", "bandit", "sniper", "turret", "gunman", "cowboy" },
}

local function classify(name)
    name = name:lower()
    for category, words in pairs(Keywords) do
        for _, w in ipairs(words) do
            if name:find(w, 1, true) then return category end
        end
    end
    return "Other"
end

----------------------------------------------------------------
-- NPC CACHE (rescanned periodically so it stays cheap)
----------------------------------------------------------------
local NPCs = {}
local NPCMap = {} -- [model] = entry  (lag fix: no more full-map rescans)

local function isPlayerCharacter(model)
    return Players:GetPlayerFromCharacter(model) ~= nil
end

local function addHumanoid(inst)
    local model = inst.Parent
    if model and model:IsA("Model") and not NPCMap[model] and not isPlayerCharacter(model) then
        local e = { model = model, humanoid = inst, kind = classify(model.Name) }
        NPCMap[model] = e
        table.insert(NPCs, e)
    end
end

-- drop dead/removed NPCs from the list (cheap, no workspace scan)
local function cleanup()
    local i = 1
    while i <= #NPCs do
        local e = NPCs[i]
        if not e.model.Parent or not e.humanoid.Parent or isPlayerCharacter(e.model) then
            NPCMap[e.model] = nil
            NPCs[i] = NPCs[#NPCs]
            NPCs[#NPCs] = nil
        else
            i = i + 1
        end
    end
end

-- ONE full scan at load, spread over several frames so it doesn't hitch
task.spawn(function()
    local all = Workspace:GetDescendants()
    for i, inst in ipairs(all) do
        if not Running then return end
        if inst:IsA("Humanoid") then addHumanoid(inst) end
        if i % 4000 == 0 then task.wait() end
    end
end)

-- after that, only react to things that spawn
Connections.added = Workspace.DescendantAdded:Connect(function(inst)
    if inst.ClassName == "Humanoid" then
        task.defer(addHumanoid, inst)
    end
end)

task.spawn(function()
    while Running do
        pcall(cleanup)
        task.wait(1)
    end
end)

-- Live ping, sampled every frame and smoothed (so it is checked 24/7).
local PingMs = 0
local function samplePing()
    local ms
    local ok, v = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
    if ok and type(v) == "number" and v > 0 then
        ms = v
    else
        local ok2, p = pcall(function() return LocalPlayer:GetNetworkPing() end)
        if ok2 and type(p) == "number" then ms = p * 1000 end
    end
    if ms then
        PingMs = (PingMs == 0) and ms or (PingMs + (ms - PingMs) * 0.1)
    end
end

-- Auto lead from ping: at low ping (<= ~40 ms) lead barely matters so only about half
-- the ping is compensated; as ping climbs toward ~150 ms it ramps up to the full ping.
local function autoLead()
    local t = math.clamp((PingMs - 40) / 110, 0, 1)
    return math.min((PingMs / 1000) * (0.5 + 0.5 * t), 0.3)
end

-- Enemy velocity measured from how far their root moved between frames. (The built-in
-- AssemblyLinearVelocity is often 0 for network-driven NPCs.) Keyed by model so it
-- survives the periodic rescan.
local Track = setmetatable({}, { __mode = "k" })

local function trackVelocities()
    local now = os.clock()
    for _, npc in ipairs(NPCs) do
        local root = npc.model:FindFirstChild("HumanoidRootPart") or npc.model.PrimaryPart
        if root then
            local st = Track[npc.model]
            if not st then
                st = { pos = root.Position, t = now, vel = Vector3.zero }
                Track[npc.model] = st
            else
                local dt = now - st.t
                if dt >= 0.25 then
                    st.pos, st.t, st.vel = root.Position, now, Vector3.zero
                elseif dt > 1e-3 then
                    local v = (root.Position - st.pos) / dt
                    if v.Magnitude > 120 then v = v.Unit * 120 end
                    st.vel = st.vel:Lerp(v, 0.5)
                    st.pos, st.t = root.Position, now
                end
            end
        end
    end
end

----------------------------------------------------------------
-- TARGETING
----------------------------------------------------------------
local function getAimPart(model)
    if Config.AimPart == "Head" then
        return model:FindFirstChild("Head")
    end
    return model:FindFirstChild("UpperTorso")
        or model:FindFirstChild("Torso")
        or model:FindFirstChild("HumanoidRootPart")
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function isVisible(point, model)
    if not Config.WallCheck then return true end
    local origin = Camera.CFrame.Position
    local filter = { model }
    if LocalPlayer.Character then table.insert(filter, LocalPlayer.Character) end
    rayParams.FilterDescendantsInstances = filter
    local hit = Workspace:Raycast(origin, point - origin, rayParams)
    -- ignore hits right next to the target (props/hitboxes hugging the enemy)
    return hit == nil or (hit.Position - point).Magnitude < 1.5
end

-- Picks the best enemy part. Normal mode: nearest to the crosshair inside the FOV circle.
-- Unlimited mode: nearest (by angle) to where you're looking, anywhere around you.
local function pickTarget(mouse)
    local camPos = Camera.CFrame.Position
    local look = Camera:ViewportPointToRay(mouse.X, mouse.Y).Direction.Unit
    local list = {}

    for _, npc in ipairs(NPCs) do
        if Config.Targets[npc.kind] and npc.model.Parent and npc.humanoid.Health > 0 then
            local part = getAimPart(npc.model)
            if part then
                local point  = part.Position
                local offset = point - camPos
                if offset.Magnitude <= Config.MaxDistance and offset.Magnitude > 0.01 then
                    local score
                    if Config.Unlimited then
                        score = math.acos(math.clamp(look:Dot(offset.Unit), -1, 1))
                    else
                        local pos, onScreen = Camera:WorldToViewportPoint(point)
                        if onScreen then
                            local d = (Vector2.new(pos.X, pos.Y) - mouse).Magnitude
                            if d <= Config.FOV then score = d end
                        end
                    end
                    if score then
                        table.insert(list, { part = part, model = npc.model, npc = npc, score = score })
                    end
                end
            end
        end
    end

    table.sort(list, function(a, b) return a.score < b.score end)
    -- only wall-check the few best candidates (keeps it cheap with big FOV)
    for i = 1, math.min(#list, 3) do
        if isVisible(list[i].part.Position, list[i].model) then
            return list[i].part, list[i].npc
        end
    end
    return nil
end

----------------------------------------------------------------
-- VAULT ESP (added)
-- Marks every bank vault and shows its code IF the code exists anywhere on
-- your client: attributes / values / sign or note text on the vault, the bank
-- building, the Banker zombie (black top hat) or a dropped "Bank Combo" note.
-- If the server keeps the code secret until the banker dies, it shows "?"
-- and points you at the banker instead. Lag-free: tracks things as they
-- spawn, refreshes twice a second, searches for codes every 2 seconds.
----------------------------------------------------------------
Config.VaultESP = true

local Vaults, Bankers, Notes = {}, {}, {} -- [instance] = entry
local CODE_WORDS = { "code", "combo", "combination", "pin", "password", "passcode" }

local function hasWord(s, list)
    s = string.lower(tostring(s))
    for _, w in ipairs(list) do
        if string.find(s, w, 1, true) then return true end
    end
    return false
end

local function digitsFrom(v, loose)
    if type(v) == "number" then
        if v >= 100 and v < 100000000 and v == math.floor(v) then return tostring(v) end
        return nil
    end
    if type(v) ~= "string" then return nil end
    local d = string.match(v, "%d%d%d%d%d?%d?%d?%d?")
    if d then return d end
    if loose then -- "1 2 3 4 5" / "12-34-5" style
        local all = string.gsub(v, "%D", "")
        if #all >= 3 and #all <= 8 then return all end
    end
    return nil
end

local function checkInst(d, trusted)
    local ok, attrs = pcall(function() return d:GetAttributes() end)
    if ok then
        for k, v in pairs(attrs) do
            if hasWord(k, CODE_WORDS) then
                local c = digitsFrom(v, true)
                if c then return c, "attribute '" .. k .. "' on " .. d.Name end
            end
        end
    end
    if d:IsA("ValueBase") and (trusted or hasWord(d.Name, CODE_WORDS)) then
        local okv, val = pcall(function() return d.Value end)
        local c = okv and digitsFrom(val, true)
        if c then return c, "value '" .. d.Name .. "'" end
    end
    if d:IsA("TextLabel") or d:IsA("TextBox") or d:IsA("TextButton") then
        local t = d.Text
        if t and t ~= "" then
            local hint = trusted or hasWord(t, CODE_WORDS) or hasWord(d.Name, CODE_WORDS)
                or (d.Parent and hasWord(d.Parent.Name, CODE_WORDS))
            if hint then
                local c = digitsFrom(t, true)
                if c then return c, "text on " .. d.Name end
            end
        end
    end
    return nil
end

local function findCode(root, trusted)
    if not root or not root.Parent then return nil end
    local c, src = checkInst(root, trusted)
    if c then return c, src end
    local ok, desc = pcall(function() return root:GetDescendants() end)
    if not ok then return nil end
    for i = 1, math.min(#desc, 1500) do
        c, src = checkInst(desc[i], trusted)
        if c then return c, src end
    end
    return nil
end

local function posPart(inst)
    if inst:IsA("BasePart") then return inst end
    if inst:IsA("Model") then
        return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
    end
    return inst:FindFirstChildWhichIsA("BasePart", true)
end

local function bankOf(vault)
    local a = vault.Parent
    for _ = 1, 4 do
        if not a or a == Workspace then return nil end
        if hasWord(a.Name, { "bank" }) then return a end
        a = a.Parent
    end
    return nil
end

local function insideTracked(inst)
    local a = inst.Parent
    for _ = 1, 3 do
        if not a then return false end
        if Vaults[a] or Notes[a] or Bankers[a] then return true end
        a = a.Parent
    end
    return false
end

local function trackThing(inst)
    local n = string.lower(inst.Name)
    local isModel = inst:IsA("Model")
    if isModel and string.find(n, "vault", 1, true) then
        if not Vaults[inst] and not insideTracked(inst) then Vaults[inst] = {} end
    elseif isModel and string.find(n, "banker", 1, true) then
        if not Bankers[inst] then Bankers[inst] = {} end
    elseif (string.find(n, "combo", 1, true) or string.find(n, "combination", 1, true))
        and (isModel or inst:IsA("BasePart") or inst:IsA("Tool")) then
        if not Notes[inst] and not insideTracked(inst) then Notes[inst] = {} end
    elseif (string.find(n, "note", 1, true) or string.find(n, "letter", 1, true)
        or (string.find(n, "paper", 1, true) and not string.find(n, "newspaper", 1, true)))
        and (isModel or inst:IsA("Tool")) then
        -- generic note/paper: only shown if a code-looking text is found on it
        if not Notes[inst] and not insideTracked(inst) then Notes[inst] = { weak = true } end
    end
end

-- ESP container (separate from the menu so hiding the menu keeps the ESP)
do
    local espParent = (gethui and gethui()) or game:GetService("CoreGui")
    local oldF = espParent:FindFirstChild("DRVaultESP")
    if oldF then oldF:Destroy() end
    VaultFolder = Instance.new("Folder")
    VaultFolder.Name = "DRVaultESP"
    VaultFolder.Parent = espParent
end

local function makeTag(adornee, color)
    local b = Instance.new("BillboardGui")
    b.Adornee = adornee
    b.Size = UDim2.fromOffset(240, 46)
    b.StudsOffset = Vector3.new(0, 4, 0)
    b.AlwaysOnTop = true
    b.LightInfluence = 0
    local t = Instance.new("TextLabel")
    t.Size = UDim2.fromScale(1, 1)
    t.BackgroundTransparency = 1
    t.Font = Enum.Font.GothamBold
    t.TextSize = 14
    t.TextColor3 = color
    t.TextStrokeTransparency = 0.3
    t.TextWrapped = true
    t.Parent = b
    b.Parent = VaultFolder
    return b, t
end

local function nearest(list, pos, maxDist)
    local best, bestD = nil, maxDist
    for inst in pairs(list) do
        local p = inst.Parent and posPart(inst)
        if p then
            local d = (p.Position - pos).Magnitude
            if d < bestD then best, bestD = inst, d end
        end
    end
    return best
end

local function dropDead(list)
    for inst, e in pairs(list) do
        if not inst.Parent then
            if e.tag then pcall(function() e.tag:Destroy() end) end
            if e.hl then pcall(function() e.hl:Destroy() end) end
            list[inst] = nil
        end
    end
end

local function dumpVaults()
    local lines = 0
    local function dump(label, root)
        print("[VaultESP] ---- " .. label .. ": " .. GetFullName(root))
        local all = { root }
        for _, d in ipairs(root:GetDescendants()) do table.insert(all, d) end
        for _, d in ipairs(all) do
            if lines > 120 then return end
            local ok, attrs = pcall(function() return d:GetAttributes() end)
            if ok then
                for k, v in pairs(attrs) do
                    print(("   attr  %s.%s = %s"):format(d.Name, k, tostring(v))); lines = lines + 1
                end
            end
            if d:IsA("ValueBase") then
                print(("   value %s = %s"):format(d.Name, tostring(d.Value))); lines = lines + 1
            elseif d:IsA("TextLabel") or d:IsA("TextBox") then
                if d.Text ~= "" then print(("   text  %s = %q"):format(d.Name, d.Text)); lines = lines + 1 end
            end
        end
    end
    local n = 0
    for v in pairs(Vaults) do n = n + 1 pcall(dump, "VAULT", v) end
    for b in pairs(Bankers) do pcall(dump, "BANKER", b) end
    for no in pairs(Notes) do pcall(dump, "NOTE", no) end
    print(("[VaultESP] %d vault(s) tracked. Send this output if no code shows up."):format(n))
end

-- One line per vault for the menu: "Town 4: 34335" (? = code not known yet).
local function vaultText()
    local rows = {}
    for inst, e in pairs(Vaults) do
        if inst.Parent then
            local full = GetFullName(inst)
            local town = tonumber(string.match(full, "[Tt]own_(%d+)"))
            local destroyed = string.find(full, "Destroyed", 1, true) ~= nil
            rows[#rows + 1] = {
                town = town or 999,
                name = full,
                text = ("Town %s%s:  %s"):format(
                    town and tostring(town) or "?",
                    destroyed and " (destroyed bank)" or "",
                    e.code and tostring(e.code) or "?"),
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.town ~= b.town then return a.town < b.town end
        return a.name < b.name
    end)
    local lines = {}
    for i, r in ipairs(rows) do lines[i] = r.text end
    if #lines == 0 then return "No vaults found yet" end
    return table.concat(lines, "\n")
end

----------------------------------------------------------------
-- (v2) extra code sources outside the bank: ReplicatedStorage, your
-- player/PlayerGui, messages the server sends you, and a memory deep scan.
----------------------------------------------------------------
local STRICT_WORDS = { "vault", "bank", "combo", "combination", "safe" }
local GlobalCode, GlobalSrc = nil, nil

local function setGlobal(c, src)
    if c and c ~= GlobalCode then
        GlobalCode, GlobalSrc = c, src
        print(("[VaultESP] code found: %s  (from %s)"):format(c, tostring(src)))
    end
end

-- strict check: the name/text must mention vault/bank/combo, so random
-- numbers elsewhere in the game don't get shown as a fake code
local function strictCheck(d)
    local nameHit = hasWord(d.Name, STRICT_WORDS)
    local ok, attrs = pcall(function() return d:GetAttributes() end)
    if ok then
        for k, v in pairs(attrs) do
            if hasWord(k, STRICT_WORDS) or (nameHit and hasWord(k, CODE_WORDS)) then
                local c = digitsFrom(v, true)
                if c then return c, "attribute " .. GetFullName(d) .. "." .. k end
            end
        end
    end
    if nameHit and d:IsA("ValueBase") then
        local okv, val = pcall(function() return d.Value end)
        local c = okv and digitsFrom(val, true)
        if c then return c, "value " .. GetFullName(d) end
    end
    if d:IsA("TextLabel") or d:IsA("TextBox") then
        local t = d.Text
        if t and t ~= "" and (nameHit or hasWord(t, STRICT_WORDS)) then
            local c = digitsFrom(t, false)
            if c then return c, "text " .. GetFullName(d) end
        end
    end
    return nil
end

local function scanGlobals()
    local roots = { LocalPlayer }
    pcall(function() table.insert(roots, 1, game:GetService("ReplicatedStorage")) end)
    for _, r in ipairs(roots) do
        local c, src = strictCheck(r)
        if c then setGlobal(c, src) return end
        local ok, desc = pcall(function() return r:GetDescendants() end)
        if ok then
            for i, d in ipairs(desc) do
                if not Running then return end
                c, src = strictCheck(d)
                if c then setGlobal(c, src) return end
                if i % 1500 == 0 then task.wait() end
            end
        end
    end
    local c, src = strictCheck(Workspace)
    if c then setGlobal(c, src) end
end

task.spawn(function()
    while Running do
        if Config.VaultESP and not GlobalCode then pcall(scanGlobals) end
        task.wait(10)
    end
end)

-- listen to what the server sends you (e.g. a "Bank combo: 12345" message)
local function argCode(remoteName, ...)
    local nameHit = hasWord(remoteName, STRICT_WORDS)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" then
            if nameHit or hasWord(v, STRICT_WORDS) then
                local c = digitsFrom(v, false)
                if c then return c end
            end
        elseif type(v) == "number" and nameHit then
            local c = digitsFrom(v, false)
            if c then return c end
        elseif type(v) == "table" then
            local okp, res = pcall(function()
                for k, val in pairs(v) do
                    if type(k) == "string" and (hasWord(k, STRICT_WORDS)
                        or (nameHit and hasWord(k, CODE_WORDS))) then
                        local c = digitsFrom(val, true)
                        if c then return c end
                    end
                end
            end)
            if okp and res then return res end
        end
    end
    return nil
end

local sniffed = setmetatable({}, { __mode = "k" })
local function sniff(r)
    if sniffed[r] or r.ClassName ~= "RemoteEvent" then return end
    sniffed[r] = true
    table.insert(Connections, r.OnClientEvent:Connect(function(...)
        if not Running then return end
        local c = argCode(r.Name, ...)
        if c then setGlobal(c, "server message via " .. r.Name) end
    end))
end

task.spawn(function()
    local ok, desc = pcall(function() return game:GetService("ReplicatedStorage"):GetDescendants() end)
    if not ok then return end
    for i, d in ipairs(desc) do
        if not Running then return end
        if d.ClassName == "RemoteEvent" then sniff(d) end
        if i % 2000 == 0 then task.wait() end
    end
end)
pcall(function()
    Connections.sniffAdded = game:GetService("ReplicatedStorage").DescendantAdded:Connect(function(d)
        if d.ClassName == "RemoteEvent" then sniff(d) end
    end)
end)

-- a code popping up on your screen (picking up the note etc.)
pcall(function()
    local pg = LocalPlayer:WaitForChild("PlayerGui", 5)
    if pg then
        Connections.pgAdded = pg.DescendantAdded:Connect(function(d)
            if d.ClassName == "TextLabel" or d.ClassName == "TextBox" then
                task.delay(0.15, function()
                    if Running and d.Parent then
                        local c, src = strictCheck(d)
                        if c then setGlobal(c, src) end
                    end
                end)
            end
        end)
    end
end)

-- memory deep scan (button only, it is heavy): looks through the game's
-- loaded script tables for keys like VaultCode / Combination
local GC_WORDS = { "vaultcode", "bankcode", "vault_code", "bank_code", "combo",
    "combination", "safecode", "vaultcombo" }

local function deepScan()
    if not getgc then
        print("[VaultESP] your executor has no getgc - deep scan unavailable")
        return
    end
    print("[VaultESP] deep scan started...")
    local ok, gc = pcall(getgc, true)
    if not ok or type(gc) ~= "table" then print("[VaultESP] getgc failed") return end
    local hits = 0
    for i = 1, #gc do
        if not Running then return end
        local v = gc[i]
        if type(v) == "table" then
            pcall(function()
                for k, val in next, v do
                    if type(k) == "string" then
                        local lk = string.lower(k)
                        local strong = hasWord(lk, GC_WORDS)
                        local weak = (lk == "code" or lk == "vault" or lk == "pin")
                        if strong or weak then
                            local c = digitsFrom(val, false)
                            if c and #c >= 4 and #c <= 6 then
                                hits = hits + 1
                                print(("[VaultESP] deep hit: %s = %s%s"):format(k, c, strong and "" or " (weak)"))
                                if strong then setGlobal(c, "memory key '" .. k .. "'") end
                            end
                        end
                    end
                end
            end)
        end
        if i % 15000 == 0 then task.wait() end
    end
    print(("[VaultESP] deep scan done, %d candidate(s)"):format(hits))
    if not GlobalCode then
        print("[VaultESP] nothing found: the code is most likely kept on the server until the banker drops the note")
    end
end

-- one chunked scan at load (no freeze), then only react to spawns
task.spawn(function()
    local all = Workspace:GetDescendants()
    for i, inst in ipairs(all) do
        if not Running then return end
        local cn = inst.ClassName
        if cn == "Model" or cn == "Part" or cn == "MeshPart" or cn == "Tool" or cn == "UnionOperation" then
            trackThing(inst)
        end
        if i % 4000 == 0 then task.wait() end
    end
end)

Connections.vaultAdded = Workspace.DescendantAdded:Connect(function(inst)
    local cn = inst.ClassName
    if cn == "Model" or cn == "Part" or cn == "MeshPart" or cn == "Tool" or cn == "UnionOperation" then
        trackThing(inst)
    end
end)

task.spawn(function()
    local step = 0
    while Running do
        step = step + 1
        pcall(function()
            dropDead(Vaults); dropDead(Bankers); dropDead(Notes)
            local on = Config.VaultESP
            local camPos = Workspace.CurrentCamera.CFrame.Position
            local searchNow = (step % 4 == 1)

            -- notes first: a dropped "Bank Combo" note is the most direct source
            for inst, e in pairs(Notes) do
                local p = posPart(inst)
                if p then
                    if searchNow and not e.code then
                        e.code, e.src = findCode(inst, not e.weak)
                        if e.code then setGlobal(e.code, "note " .. inst.Name) end
                    end
                    if e.weak and not e.code then
                        if e.tag then e.tag.Enabled = false end
                    else
                        if not e.tag then e.tag, e.label = makeTag(p, Color3.fromRGB(120, 255, 160)) end
                        e.tag.Enabled = on
                        e.label.Text = ("BANK COMBO NOTE  %s\n%d st"):format(
                            e.code and ("[" .. e.code .. "]") or "[?]", (p.Position - camPos).Magnitude)
                    end
                end
            end

            for inst, e in pairs(Bankers) do
                local p = posPart(inst)
                if p then
                    if searchNow and not e.code then e.code, e.src = findCode(inst, false) end
                    if not e.tag then e.tag, e.label = makeTag(p, Color3.fromRGB(255, 140, 90)) end
                    e.tag.Enabled = on
                    e.label.Text = ("BANKER (drops code)  %s\n%d st"):format(
                        e.code and ("[" .. e.code .. "]") or "", (p.Position - camPos).Magnitude)
                end
            end

            for inst, e in pairs(Vaults) do
                local p = posPart(inst)
                if p then
                    if searchNow and not e.code then
                        local c, src = findCode(inst, false)
                        if not c then c, src = findCode(bankOf(inst), false) end
                        if not c then
                            local nb = nearest(Bankers, p.Position, 250)
                            if nb and Bankers[nb].code then c, src = Bankers[nb].code, "banker" end
                        end
                        if not c then
                            local nn = nearest(Notes, p.Position, 400)
                            if nn and Notes[nn].code then c, src = Notes[nn].code, "combo note" end
                        end
                        if not c and GlobalCode then c, src = GlobalCode, GlobalSrc end
                        if c and c ~= e.code then
                            print(("[VaultESP] %s code = %s  (from %s)"):format(GetFullName(inst), c, tostring(src)))
                        end
                        e.code, e.src = c, src
                    end
                    if not e.tag then
                        e.tag, e.label = makeTag(p, Color3.fromRGB(255, 210, 60))
                        local h = Instance.new("Highlight")
                        h.Adornee = inst
                        h.FillColor = Color3.fromRGB(255, 200, 40)
                        h.FillTransparency = 0.75
                        h.OutlineColor = Color3.fromRGB(255, 230, 120)
                        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                        h.Parent = VaultFolder
                        e.hl = h
                    end
                    e.tag.Enabled = on
                    e.hl.Enabled = on
                    local dist = (p.Position - camPos).Magnitude
                    if e.code then
                        e.label.Text = ("VAULT  CODE: %s\n%d st"):format(e.code, dist)
                    else
                        e.label.Text = ("VAULT  code: ?\nkill the banker / grab the note · %d st"):format(dist)
                    end
                end
            end
        end)
        task.wait(0.5)
    end
end)

----------------------------------------------------------------
-- AMMO AURA (v2)
-- Picks up ammo lying around you (hover + E, prompts or click detectors).
-- v2 fixes:
--  * shop stock is skipped: items inside shop buildings, near shopkeepers,
--    with price tags / "Buy" prompts, AND any spot where a pickup cost you
--    money gets remembered and never touched again
--  * no more "stops after a while": every sweep is error-protected and
--    items that failed are retried later instead of being ignored forever
--  * fast: up to AuraBurst items per sweep, prompts fired all at once,
--    a sweep every 0.1 s
----------------------------------------------------------------
Config.AmmoAura     = true
Config.SkipShop     = true
Config.CollectMoney = false
Config.AuraRadius   = 14
Config.AuraBurst    = 6
Config.AuraDebug    = false

local AMMO_WORDS     = { "ammo", "shell", "bullet", "cartridge", "rounds" }
local MONEY_WORDS    = { "money", "cash" }
local SHOP_WORDS     = { "shop", "store", "gunsmith", "doctor", "merchant", "vendor", "trader",
    "shelf", "counter", "forsale", "for sale" }
local SHOP_NPC_WORDS = { "shopkeeper", "gunsmith", "doctor", "merchant", "clerk", "vendor", "trader" }

env.DRCollect = env.DRCollect or {}
local Collect = env.DRCollect
Collect.part = nil

-- hover spoof hooks (installed once per session, idle unless Collect.part is set)
if HooksSupported and not env.DRCollectHooked then
    env.DRCollectHooked = true
    local mouse = LocalPlayer:GetMouse()
    local oldIdx
    oldIdx = hookmetamethod(game, "__index", newcclosure(function(self, key)
        local p = Collect.part
        if p and self == mouse and not checkcaller() then
            if key == "Target" then return p end
            if key == "Hit" then return CFrame.new(p.Position) end
        end
        return oldIdx(self, key)
    end))
    local oldNc
    oldNc = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local p = Collect.part
        if p and self == Workspace and not checkcaller() then
            local method = getnamecallmethod()
            if method == "Raycast" then
                local origin, dir, params = ...
                if typeof(origin) == "Vector3" and typeof(dir) == "Vector3"
                    and (origin - Workspace.CurrentCamera.CFrame.Position).Magnitude < 3 then
                    local to = p.Position - origin
                    setnamecallmethod(method)
                    return oldNc(self, origin, to.Unit * math.max(dir.Magnitude, to.Magnitude + 5), params)
                end
            end
            setnamecallmethod(method)
        end
        return oldNc(self, ...)
    end))
end

local Pickups   = {} -- [inst] = { kind, part, shop, shopT, tries, next }
local ShopZones = {} -- [model] = { cf, size } (shop buildings)
local ShopNPCs  = {} -- [model] = true (shopkeepers)
local ShopSpots = {} -- learned positions where a pickup cost money
local CollectedCount = 0
local CollectLabel -- set in the GUI

local function kindOf(inst)
    local n = string.lower(inst.Name)
    if hasWord(n, AMMO_WORDS) then return "ammo" end
    if hasWord(n, MONEY_WORDS) then return "money" end
    return nil
end

local function insidePickup(inst)
    local a = inst.Parent
    for _ = 1, 3 do
        if not a then return false end
        if Pickups[a] then return true end
        a = a.Parent
    end
    return false
end

local function trackPickup(inst)
    local cn = inst.ClassName
    if cn == "Model" then
        local n = string.lower(inst.Name)
        if hasWord(n, SHOP_NPC_WORDS) then ShopNPCs[inst] = true end
        if hasWord(n, SHOP_WORDS) then ShopZones[inst] = ShopZones[inst] or {} end
    end
    if cn ~= "Model" and cn ~= "Part" and cn ~= "MeshPart" and cn ~= "Tool" and cn ~= "UnionOperation" then
        return
    end
    if Pickups[inst] then return end
    local k = kindOf(inst)
    if k and not insidePickup(inst) then
        Pickups[inst] = { kind = k, tries = 0, next = 0 }
    end
end

local function inShopZone(pos)
    for m, z in pairs(ShopZones) do
        if not m.Parent then
            ShopZones[m] = nil
        else
            if not z.cf then
                local ok, cf, size = pcall(function() return m:GetBoundingBox() end)
                if ok then z.cf, z.size = cf, size else z.cf, z.size = CFrame.new(), Vector3.zero end
            end
            if z.size.Magnitude > 0 and z.size.Magnitude < 400 then
                local lp = z.cf:PointToObjectSpace(pos)
                local h = z.size / 2 + Vector3.new(6, 6, 6)
                if math.abs(lp.X) <= h.X and math.abs(lp.Y) <= h.Y and math.abs(lp.Z) <= h.Z then
                    return true
                end
            end
        end
    end
    for m in pairs(ShopNPCs) do
        if not m.Parent then
            ShopNPCs[m] = nil
        else
            local p = posPart(m)
            if p and (p.Position - pos).Magnitude < 22 then return true end
        end
    end
    for _, s in ipairs(ShopSpots) do
        if (s - pos).Magnitude < 6 then return true end
    end
    return false
end

local function priceText(s)
    return type(s) == "string" and string.find(s, "%$%s*%d") ~= nil
end

local function isShopItem(inst, part)
    if part and inShopZone(part.Position) then return true end
    local a = inst
    for _ = 1, 6 do
        if not a or a == Workspace then break end
        if hasWord(a.Name, SHOP_WORDS) then return true end
        local okA, attrs = pcall(function() return a:GetAttributes() end)
        if okA then
            for k in pairs(attrs) do
                local lk = string.lower(k)
                if string.find(lk, "price", 1, true) or lk == "cost" or lk == "buyable" or lk == "forsale" then
                    return true
                end
            end
        end
        a = a.Parent
    end
    local ok, desc = pcall(function() return inst:GetDescendants() end)
    if ok then
        for _, d in ipairs(desc) do
            local cn = d.ClassName
            if cn == "ProximityPrompt" then
                local t = string.lower(d.ActionText .. " " .. d.ObjectText)
                if string.find(t, "buy", 1, true) or string.find(t, "purchase", 1, true) or priceText(t) then
                    return true
                end
            elseif cn == "TextLabel" then
                if priceText(d.Text) then return true end
            elseif cn == "NumberValue" or cn == "IntValue" then
                local ln = string.lower(d.Name)
                if string.find(ln, "price", 1, true) or ln == "cost" then return true end
            end
        end
    end
    return false
end

local function isHeld(inst)
    for _, plr in ipairs(Players:GetPlayers()) do
        local c = plr.Character
        if c and inst:IsDescendantOf(c) then return true end
    end
    return false
end

local function getMoney()
    local v
    pcall(function()
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        local m = ls and (ls:FindFirstChild("Money") or ls:FindFirstChild("Cash"))
        if m then v = m.Value end
        if v == nil then v = LocalPlayer:GetAttribute("Money") or LocalPlayer:GetAttribute("Cash") end
    end)
    return tonumber(v)
end

local function pressE(hold)
    -- never type "e" into the chat
    local focused = nil
    pcall(function() focused = UserInputService:GetFocusedTextBox() end)
    if focused then return false end
    hold = hold or 0.04
    if keypress and keyrelease then
        if pcall(function() keypress(0x45); task.wait(hold); keyrelease(0x45) end) then return true end
    end
    return pcall(function()
        local vim = game:GetService("VirtualInputManager")
        vim:SendKeyEvent(true, Enum.KeyCode.E, false, game)
        task.wait(hold)
        vim:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    end)
end

local function firePrompt(pp)
    if fireproximityprompt then
        pcall(fireproximityprompt, pp)
    else
        pcall(function()
            pp.HoldDuration = 0
            pp:InputHoldBegin()
            task.wait()
            pp:InputHoldEnd()
        end)
    end
end

local function methodFor(inst)
    local prompts = {}
    for _, d in ipairs(inst:GetDescendants()) do
        if d.ClassName == "ProximityPrompt" and d.Enabled then prompts[#prompts + 1] = d end
    end
    if #prompts > 0 then return "prompt", prompts end
    local cd = inst:FindFirstChildWhichIsA("ClickDetector", true)
    if cd and fireclickdetector then return "click", cd end
    return "hover"
end

-- one chunked scan at load (no freeze), then only react to spawns
task.spawn(function()
    local all = Workspace:GetDescendants()
    for i, inst in ipairs(all) do
        if not Running then return end
        trackPickup(inst)
        if i % 4000 == 0 then task.wait() end
    end
end)
Connections.pickAdded = Workspace.DescendantAdded:Connect(trackPickup)

local function sweep()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local now = os.clock()
    local cands = {}
    for inst, e in pairs(Pickups) do
        if not inst.Parent then
            Pickups[inst] = nil
        elseif (e.kind == "ammo" or (e.kind == "money" and Config.CollectMoney)) and now >= e.next then
            if not (e.part and e.part.Parent) then e.part = posPart(inst) end
            local p = e.part
            if p then
                local d = (p.Position - root.Position).Magnitude
                if d <= Config.AuraRadius and not isHeld(inst) then
                    -- shop check is re-done every 4 s (price tags can load late)
                    if Config.SkipShop and not e.shop and (not e.shopT or now - e.shopT > 4) then
                        e.shop = isShopItem(inst, p)
                        e.shopT = now
                    end
                    if not (Config.SkipShop and e.shop) then
                        cands[#cands + 1] = { inst = inst, e = e, part = p, d = d }
                    end
                end
            end
        end
    end
    if #cands == 0 then return end
    table.sort(cands, function(a, b) return a.d < b.d end)

    local moneyBefore = getMoney()
    local done = {}
    for i = 1, math.min(#cands, Config.AuraBurst) do
        local c = cands[i]
        if c.inst.Parent then
            c.e.tries = c.e.tries + 1
            if c.e.tries >= 6 then
                c.e.tries = 0
                c.e.next = now + 6 -- rest, then try again (never ignored forever)
            else
                c.e.next = now + 0.6
            end
            local okM, how, data = pcall(methodFor, c.inst)
            if okM then
                if how == "prompt" then
                    for _, pp in ipairs(data) do task.spawn(firePrompt, pp) end
                elseif how == "click" then
                    task.spawn(pcall, fireclickdetector, data)
                elseif HooksSupported then
                    Collect.part = c.part
                    task.wait()
                    pressE(0.03)
                    task.wait(0.03)
                    Collect.part = nil
                else
                    how = "no hooks"
                end
                CollectedCount = CollectedCount + 1
                done[#done + 1] = c
                if Config.AuraDebug then
                    print(("[Aura] %s (%s) %d st -> %s"):format(c.inst.Name, c.e.kind, math.floor(c.d), tostring(how)))
                end
                if CollectLabel then
                    CollectLabel.Text = ("Aura: %d pickup(s), last: %s"):format(CollectedCount, tostring(how))
                end
            end
        end
    end

    -- safety net: if your money went down, those were shop items -> remember the spots
    if moneyBefore and #done > 0 then
        task.delay(0.7, function()
            local after = getMoney()
            if after and after < moneyBefore then
                for _, c in ipairs(done) do
                    c.e.shop = true
                    if #ShopSpots < 300 then table.insert(ShopSpots, c.part.Position) end
                end
                print(("[Aura] money dropped %s -> %s: marked %d spot(s) as shop, they won't be touched again"):format(
                    tostring(moneyBefore), tostring(after), #done))
            end
        end)
    end
end

local sweeping = false
task.spawn(function()
    while Running do
        if Config.AmmoAura and not sweeping then
            sweeping = true
            local ok, err = pcall(sweep) -- an error can no longer kill the aura
            Collect.part = nil
            sweeping = false
            if not ok and Config.AuraDebug then warn("[Aura] sweep error: " .. tostring(err)) end
        end
        task.wait(0.1)
    end
end)

local function listPickups()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then print("[Aura] no character") return end
    local n, zones, npcs = 0, 0, 0
    for _ in pairs(ShopZones) do zones = zones + 1 end
    for _ in pairs(ShopNPCs) do npcs = npcs + 1 end
    for inst, e in pairs(Pickups) do
        local p = inst.Parent and posPart(inst)
        if p then
            local d = (p.Position - root.Position).Magnitude
            if d <= 60 then
                n = n + 1
                e.tries, e.next = 0, 0
                e.shop = isShopItem(inst, p)
                e.shopT = os.clock()
                local hasPrompt = inst:FindFirstChildWhichIsA("ProximityPrompt", true) ~= nil
                print(("[Aura] %s | %s | shop=%s | prompt=%s | %d st | %s"):format(
                    inst.Name, e.kind, tostring(e.shop), tostring(hasPrompt), math.floor(d), GetFullName(inst)))
            end
        end
    end
    print(("[Aura] %d pickup(s) within 60 st | shop buildings %d, shopkeepers %d, learned shop spots %d | money=%s"):format(
        n, zones, npcs, #ShopSpots, tostring(getMoney())))
end

----------------------------------------------------------------
-- REACH (added)
-- Lets you grab / drag items from farther away.
--  1) the game's "what am I pointing at" ray from your camera is made longer
--     (only short camera rays, never gun rays; silent aim is paused for it)
--  2) item prompts (E) and click detectors get a bigger activation distance
--  3) drag/grab distance settings found in the game's scripts are raised
-- If Dead Rails also checks the distance on the server, very long grabs can
-- still be rejected: raise it step by step to find what the server allows.
-- Hook is installed once per session and does nothing while Reach is off.
----------------------------------------------------------------
Config.Reach     = false
Config.ReachDist = 30

env.DRReach = env.DRReach or {}
local Reach = env.DRReach
Reach.on, Reach.dist, Reach.silent = false, Config.ReachDist, Silent

Connections.reachCam = RunService.RenderStepped:Connect(function()
    local cam = Workspace.CurrentCamera
    if cam then Reach.camPos = cam.CFrame.Position end
end)

if HooksSupported and not env.DRReachHooked then
    env.DRReachHooked = true
    local oldNc
    oldNc = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if Reach.on and self == Workspace and not checkcaller() then
            local method = getnamecallmethod()
            local camPos = Reach.camPos
            if camPos then
                if method == "Raycast" then
                    local origin, dir, params = ...
                    if typeof(origin) == "Vector3" and typeof(dir) == "Vector3" then
                        local len = dir.Magnitude
                        if len > 2 and len < 60 and len < Reach.dist
                            and (origin - camPos).Magnitude < 1.5 then
                            local S = Reach.silent
                            local sa = S and S.active
                            if S then S.active = false end -- don't let silent aim take this ray
                            setnamecallmethod(method)
                            local ok, res = pcall(oldNc, self, origin, dir.Unit * Reach.dist, params)
                            if S then S.active = sa end
                            if ok then return res end
                        end
                    end
                elseif method == "FindPartOnRay" or method == "FindPartOnRayWithIgnoreList"
                    or method == "FindPartOnRayWithWhitelist" then
                    local args = table.pack(...)
                    local ray = args[1]
                    if typeof(ray) == "Ray" then
                        local len = ray.Direction.Magnitude
                        if len > 2 and len < 60 and len < Reach.dist
                            and (ray.Origin - camPos).Magnitude < 1.5 then
                            args[1] = Ray.new(ray.Origin, ray.Direction.Unit * Reach.dist)
                            setnamecallmethod(method)
                            local ok, a, b, c, d = pcall(oldNc, self, table.unpack(args, 1, args.n))
                            if ok then return a, b, c, d end
                        end
                    end
                end
            end
            setnamecallmethod(method)
        end
        return oldNc(self, ...)
    end))
end

-- prompts / click detectors.
-- (fix) originals are kept for the whole session (shared between re-runs), and
-- anything that shows up already raised (the game CLONES items, so a copy made
-- while Reach was on inherits the raised distance) is treated as raised, not
-- as its normal value - so turning Reach off really goes back to normal.
Reach.promptOrig = Reach.promptOrig or setmetatable({}, { __mode = "k" })
Reach.tableOrig  = Reach.tableOrig  or setmetatable({}, { __mode = "k" })
Reach.raisedTo   = Reach.raisedTo or {} -- every reach distance used this session
local PromptOrig, TableOrig = Reach.promptOrig, Reach.tableOrig
local DEFAULT_PROMPT, DEFAULT_CLICK = 10, 32
local ReachLabel -- set in the GUI

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function looksRaised(v)
    if Reach.on and v == Reach.dist then return true end
    return Reach.raisedTo[v] == true
end

local function trackReachObj(d)
    local cn = d.ClassName
    if cn ~= "ProximityPrompt" and cn ~= "ClickDetector" then return end
    if PromptOrig[d] == nil then
        local ok, v = pcall(function() return d.MaxActivationDistance end)
        if not (ok and type(v) == "number") then return end
        if looksRaised(v) then
            v = (cn == "ProximityPrompt") and DEFAULT_PROMPT or DEFAULT_CLICK
        end
        PromptOrig[d] = v
    end
    local orig = PromptOrig[d]
    local want = (Reach.on and math.max(orig, Reach.dist)) or orig
    pcall(function()
        if d.MaxActivationDistance ~= want then d.MaxActivationDistance = want end
    end)
end

task.spawn(function()
    local all = Workspace:GetDescendants()
    for i, d in ipairs(all) do
        if not Running then return end
        trackReachObj(d)
        if i % 4000 == 0 then task.wait() end
    end
end)
Connections.reachAdded = Workspace.DescendantAdded:Connect(trackReachObj)

local function applyPrompts()
    for d, orig in pairs(PromptOrig) do
        if d.Parent then
            local want = (Reach.on and math.max(orig, Reach.dist)) or orig
            pcall(function()
                if d.MaxActivationDistance ~= want then d.MaxActivationDistance = want end
            end)
        end
    end
end

-- drag/grab distance settings inside the game's scripts (needs getgc)
local REACH_KEY_A = { "drag", "grab", "carry", "pickup", "interact" }
local REACH_KEY_B = { "dist", "range", "reach", "length" }

local function isReachKey(k)
    if type(k) ~= "string" then return false end
    local lk = string.lower(k)
    if lk == "reach" or lk == "maxreach" then return true end
    return hasWord(lk, REACH_KEY_A) and hasWord(lk, REACH_KEY_B)
end

local function reachScan()
    if not getgc then return end
    local ok, gc = pcall(getgc, true)
    if not ok or type(gc) ~= "table" then return end
    -- the normal value of each setting name, learned from tables we already know
    local normalOf = {}
    for _, rec in pairs(TableOrig) do
        for k, v in pairs(rec) do normalOf[k] = normalOf[k] or v end
    end
    for i = 1, #gc do
        if not Running then return end
        local t = gc[i]
        if type(t) == "table" and t ~= Config and t ~= Reach then
            pcall(function()
                for k, v in next, t do
                    if type(v) == "number" and v >= 3 and v <= 200 and isReachKey(k) then
                        local rec = TableOrig[t]
                        if not (rec and rec[k] ~= nil) then
                            local orig = v
                            if looksRaised(v) then
                                orig = normalOf[k] -- (fix) a copy of a raised value
                            end
                            if orig then
                                if not rec then rec = {} TableOrig[t] = rec end
                                rec[k] = orig
                                normalOf[k] = normalOf[k] or orig
                                print(("[Reach] found drag setting %s = %s"):format(tostring(k), tostring(orig)))
                            end
                        end
                    end
                end
            end)
        end
        if i % 20000 == 0 then task.wait() end
    end
end

local function applyTables()
    for t, rec in pairs(TableOrig) do
        for k, orig in pairs(rec) do
            pcall(function()
                local want = (Reach.on and math.max(orig, Reach.dist)) or orig
                if t[k] ~= want then t[k] = want end
            end)
        end
    end
end

local function applyReach()
    Reach.on = Config.Reach and Running
    Reach.dist = Config.ReachDist
    if Reach.on then Reach.raisedTo[Reach.dist] = true end
    applyPrompts()
    applyTables()
end

Reach.restore = function()
    Reach.on = false
    pcall(applyPrompts)
    pcall(applyTables)
end

-- reacts when you change the toggle or the distance
task.spawn(function()
    local lastOn, lastDist = nil, nil
    while Running do
        if Config.Reach ~= lastOn or Config.ReachDist ~= lastDist then
            local turningOn = Config.Reach and not lastOn
            local turningOff = (not Config.Reach) and lastOn
            if turningOn and countKeys(TableOrig) == 0 then pcall(reachScan) end
            lastOn, lastDist = Config.Reach, Config.ReachDist
            pcall(applyReach)
            if turningOff then
                -- (fix) the game can re-apply values a moment later: rescan for
                -- copies and force the normal values again a few times
                task.spawn(function()
                    pcall(reachScan)
                    for _, w in ipairs({ 0.3, 0.7, 1.5 }) do
                        task.wait(w)
                        if Config.Reach or not Running then return end
                        pcall(applyReach)
                    end
                end)
            end
        end
        if ReachLabel then
            local txt = Config.Reach
                and ("Reach: ON (%d studs)"):format(Config.ReachDist)
                or "Reach: OFF (normal distance)"
            if ReachLabel.Text ~= txt then ReachLabel.Text = txt end
        end
        task.wait(0.2)
    end
end)

----------------------------------------------------------------
-- AIR WELD (added)
-- Normally Weld (Z) only shows / works while the item you're holding touches
-- the train. This makes the game's touch checks report the nearest train part
-- as touching the item you're holding, so you can weld it where it is.
-- Client-side only: if Dead Rails re-checks the touch on the server, the weld
-- gets refused. "Log weld remote" prints what the game sends when you weld.
-- Hook is installed once per session and does nothing while Air weld is off.
----------------------------------------------------------------
Config.AirWeld      = false
Config.LogWeld      = false
Config.AirWeldRange = 80 -- studs: the train must be this close to the item

env.DRAirWeld = env.DRAirWeld or {}
local AW = env.DRAirWeld
AW.on, AW.log, AW.held, AW.heldPos, AW.train = false, false, nil, nil, nil
local AirLabel -- set in the GUI

local TRAIN_WORDS = { "train", "locomotive", "wagon", "caboose" }
local TrainModels = {} -- [model] = { parts, t }

local function trackTrain(inst)
    if inst.ClassName ~= "Model" or not hasWord(inst.Name, TRAIN_WORDS) then return end
    if isPlayerCharacter(inst) then return end
    local a = inst.Parent
    for _ = 1, 4 do -- skip models nested inside a train we already track
        if not a then break end
        if TrainModels[a] then return end
        a = a.Parent
    end
    TrainModels[inst] = TrainModels[inst] or {}
end

task.spawn(function()
    local all = Workspace:GetDescendants()
    for i, d in ipairs(all) do
        if not Running then return end
        trackTrain(d)
        if i % 4000 == 0 then task.wait() end
    end
end)
Connections.trainAdded = Workspace.DescendantAdded:Connect(trackTrain)

local function isHeldPart(p)
    local h = AW.held
    return h ~= nil and (p == h or p:IsDescendantOf(h))
end

local function nearestTrainPart(pos)
    local best, bestD = nil, Config.AirWeldRange
    local now = os.clock()
    for m, e in pairs(TrainModels) do
        if not m.Parent then
            TrainModels[m] = nil
        else
            if not e.parts or now - (e.t or 0) > 5 then
                e.parts, e.t = {}, now
                local ok, desc = pcall(function() return m:GetDescendants() end)
                if ok then
                    for _, d in ipairs(desc) do
                        if d:IsA("BasePart") and d.Size.Magnitude >= 3 then
                            e.parts[#e.parts + 1] = d
                            if #e.parts >= 80 then break end
                        end
                    end
                end
            end
            for _, p in ipairs(e.parts) do
                if p.Parent and not isHeldPart(p) then
                    local d = (p.Position - pos).Magnitude
                    if d < bestD then best, bestD = p, d end
                end
            end
        end
    end
    return best, bestD
end

-- what you're holding = the unanchored item you clicked on
Connections.awDown = UserInputService.InputBegan:Connect(function(input)
    local it = input.UserInputType
    if it ~= Enum.UserInputType.MouseButton1 and it ~= Enum.UserInputType.Touch then return end
    if not Config.AirWeld then return end
    task.defer(function()
        local ok, t = pcall(function() return LocalPlayer:GetMouse().Target end)
        if not (ok and t) or t.Anchored then return end
        local m = t:FindFirstAncestorOfClass("Model")
        if m and isPlayerCharacter(m) then return end
        if m and not TrainModels[m] then AW.held = m else AW.held = t end
    end)
end)
Connections.awUp = UserInputService.InputEnded:Connect(function(input)
    local it = input.UserInputType
    if it ~= Enum.UserInputType.MouseButton1 and it ~= Enum.UserInputType.Touch then return end
    local h = AW.held
    task.delay(0.6, function()
        local still = false
        pcall(function() still = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end)
        if AW.held == h and not still then AW.held = nil end
    end)
end)

-- 5x per second: find the train part nearest to what you're holding
task.spawn(function()
    while Running do
        AW.on = Config.AirWeld and Running
        AW.log = Config.LogWeld and Running
        if AW.held and not AW.held.Parent then AW.held = nil end
        local dist
        if AW.on and AW.held then
            local p = AW.held:IsA("BasePart") and AW.held or posPart(AW.held)
            if p then
                AW.heldPos = p.Position
                AW.train, dist = nearestTrainPart(p.Position)
            end
        else
            AW.train, AW.heldPos = nil, nil
        end
        if AirLabel then
            local txt
            if not Config.AirWeld then
                txt = "Air weld: off"
            elseif not AW.held then
                txt = "Air weld: hold an item"
            elseif AW.train then
                txt = ("Air weld: READY - press Z (train %d st)"):format(math.floor(dist or 0))
            else
                txt = ("Air weld: no train within %d st"):format(Config.AirWeldRange)
            end
            if AirLabel.Text ~= txt then AirLabel.Text = txt end
        end
        task.wait(0.2)
    end
end)

if HooksSupported and not env.DRAirWeldHooked then
    env.DRAirWeldHooked = true
    local oldNc
    oldNc = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if (AW.on or AW.log) and not checkcaller() then
            local method = getnamecallmethod()

            -- log what the game sends when you weld
            if AW.log and method == "FireServer" and typeof(self) == "Instance"
                and IsA(self, "RemoteEvent") and string.find(string.lower(self.Name), "weld", 1, true) then
                local args = table.pack(...)
                pcall(function()
                    local parts = {}
                    for i = 1, args.n do
                        local v = args[i]
                        parts[i] = typeof(v) == "Instance" and (v.Name .. " <" .. v.ClassName .. ">")
                            or (typeof(v) .. ":" .. tostring(v))
                    end
                    print("[AirWeld] " .. GetFullName(self) .. ":FireServer(" .. table.concat(parts, ", ") .. ")")
                end)
                setnamecallmethod(method)
                return oldNc(self, table.unpack(args, 1, args.n))
            end

            local h, train = AW.held, AW.train
            if AW.on and h and train and train.Parent then
                local hit = false
                if method == "GetTouchingParts" and typeof(self) == "Instance"
                    and IsA(self, "BasePart") and (self == h or IsDescendantOf(self, h)) then
                    hit = true
                elseif self == Workspace and method == "GetPartsInPart" then
                    local p = ...
                    if typeof(p) == "Instance" and (p == h or IsDescendantOf(p, h)) then hit = true end
                elseif self == Workspace and (method == "GetPartBoundsInBox" or method == "GetPartBoundsInRadius") then
                    local a = ...
                    local pos = (typeof(a) == "CFrame" and a.Position) or (typeof(a) == "Vector3" and a) or nil
                    if pos and AW.heldPos and (pos - AW.heldPos).Magnitude < 8 then hit = true end
                end
                if hit then
                    setnamecallmethod(method)
                    local ok, res = pcall(oldNc, self, ...)
                    if ok and type(res) == "table" then
                        table.insert(res, train) -- "the train is touching this item"
                        return res
                    end
                    setnamecallmethod(method)
                    return oldNc(self, ...)
                end
            end
            setnamecallmethod(method)
        end
        return oldNc(self, ...)
    end))
end

----------------------------------------------------------------
-- FULLBRIGHT + NO FOG (added)
-- No per-frame work: lighting is only touched when you flip a toggle, or when
-- the game itself changes a lighting value (its new value is remembered and
-- yours is put back). Turning a toggle off restores the game's real values.
----------------------------------------------------------------
Config.Fullbright = false
Config.NoFog      = false

local Lighting = game:GetService("Lighting")
env.DRVisual = env.DRVisual or {}
local Vis = env.DRVisual
Vis.saved = Vis.saved or setmetatable({}, { __mode = "k" }) -- [obj] = { prop = game value }
local VisAppliers = {}
local visBusy = false

local function same(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-3 end
    if typeof(a) == "Color3" and typeof(b) == "Color3" then
        return math.abs(a.R - b.R) < 0.005 and math.abs(a.G - b.G) < 0.005 and math.abs(a.B - b.B) < 0.005
    end
    return a == b
end

local function visGroupOn(group)
    if not Running then return false end
    if group == "fb" then return Config.Fullbright end
    if group == "fog" then return Config.NoFog end
    return false
end

local function enforce(obj, prop, want, group)
    local saved = Vis.saved[obj]
    if not saved then saved = {} Vis.saved[obj] = saved end
    local function apply()
        if visBusy or not obj.Parent then return end
        local ok, cur = pcall(function() return obj[prop] end)
        if not ok then return end
        if visGroupOn(group) then
            if not same(cur, want) then
                saved[prop] = cur -- the game's latest real value
                visBusy = true
                pcall(function() obj[prop] = want end)
                visBusy = false
            end
        elseif saved[prop] ~= nil then
            local back = saved[prop]
            saved[prop] = nil
            visBusy = true
            pcall(function() obj[prop] = back end)
            visBusy = false
        end
    end
    local ok, sig = pcall(function() return obj:GetPropertyChangedSignal(prop) end)
    if ok and sig then table.insert(Connections, sig:Connect(apply)) end
    table.insert(VisAppliers, apply)
    apply()
end

local FB_GRAY = Color3.fromRGB(178, 178, 178)
enforce(Lighting, "Brightness", 2, "fb")
enforce(Lighting, "GlobalShadows", false, "fb")
enforce(Lighting, "Ambient", FB_GRAY, "fb")
enforce(Lighting, "OutdoorAmbient", FB_GRAY, "fb")
enforce(Lighting, "ExposureCompensation", 0, "fb")
enforce(Lighting, "FogEnd", 100000, "fog")
enforce(Lighting, "FogStart", 100000, "fog")

local function hookLightingChild(c)
    if c.ClassName == "Atmosphere" then
        enforce(c, "Density", 0, "fog")
        enforce(c, "Haze", 0, "fog")
    end
end
for _, c in ipairs(Lighting:GetChildren()) do hookLightingChild(c) end
Connections.lightAdded = Lighting.ChildAdded:Connect(hookLightingChild)

Vis.restore = function()
    for _, f in ipairs(VisAppliers) do pcall(f) end
end

task.spawn(function()
    local lastFb, lastFog = nil, nil
    while Running do
        if Config.Fullbright ~= lastFb or Config.NoFog ~= lastFog then
            lastFb, lastFog = Config.Fullbright, Config.NoFog
            for _, f in ipairs(VisAppliers) do pcall(f) end
        end
        task.wait(0.25)
    end
end)

----------------------------------------------------------------
-- AUTO RELOAD + FAST RELOAD (added)
-- Works with any gun (revolver, rifle, shotgun...):
--  * finds the gun's ammo counter (a value/attribute named Ammo, Mag, Clip...
--    or, if there is none, the "6/6" ammo text on your screen after one shot)
--  * the moment it hits 0 it presses R for you; "Top up" also reloads when
--    the gun isn't full and you stopped shooting for a moment
--  * Fast reload: reload-time settings on the gun and in the game's scripts
--    are cut to almost nothing and the reload animation plays faster
-- If the server enforces its own reload time, the reload can't go below that.
-- Event-driven: no per-frame work, one small check 5x per second.
----------------------------------------------------------------
Config.AutoReload      = false
Config.ReloadTopUp     = true
Config.FastReload      = false
Config.ReloadAnimSpeed = 5
Config.ReloadDebug     = false

env.DRReload = env.DRReload or {}
local RL = env.DRReload
RL.valOrig   = RL.valOrig   or setmetatable({}, { __mode = "k" }) -- [ValueBase] = original
RL.attrOrig  = RL.attrOrig  or setmetatable({}, { __mode = "k" }) -- [inst] = { attr = original }
RL.tableOrig = RL.tableOrig or setmetatable({}, { __mode = "k" }) -- [table] = { key = original }
RL.normal    = RL.normal    or {} -- normal value per setting name (for copies made while fast)

local FAST_RELOAD = 0.05
local Gun = { tool = nil, src = nil, max = 0, conns = {}, lastShot = 0, lastReload = 0, label = nil }
local ReloadLabel -- set in the GUI

local AMMO_YES = { "ammo", "mag", "clip", "bullet", "round", "loaded", "shots" }
local AMMO_NO  = { "max", "reserve", "stored", "total", "spare", "capacity", "size", "type",
    "price", "cost", "reload", "speed", "damage" }
local RELOAD_A = { "reload" }
local RELOAD_B = { "time", "duration", "delay", "length", "cooldown" }

local function isAmmoName(n)
    return hasWord(n, AMMO_YES) and not hasWord(n, AMMO_NO)
end
local function isReloadTimeName(n)
    return type(n) == "string" and hasWord(n, RELOAD_A) and hasWord(n, RELOAD_B)
end

local function findAmmo(tool)
    local list = { tool }
    for _, d in ipairs(tool:GetDescendants()) do list[#list + 1] = d end
    for _, d in ipairs(list) do
        local cn = d.ClassName
        if (cn == "IntValue" or cn == "NumberValue") and isAmmoName(d.Name) then
            return { kind = "value", obj = d, name = d.Name }
        end
        local ok, attrs = pcall(function() return d:GetAttributes() end)
        if ok then
            for k, v in pairs(attrs) do
                if type(v) == "number" and isAmmoName(k) then
                    return { kind = "attr", obj = d, name = k }
                end
            end
        end
    end
    return nil
end

local function readAmmo()
    local s = Gun.src
    if not s or not s.obj.Parent then return nil end
    local v
    pcall(function()
        if s.kind == "value" then v = s.obj.Value
        elseif s.kind == "attr" then v = s.obj:GetAttribute(s.name)
        else v = tonumber(string.match(s.obj.Text, "^%s*(%d+)%s*/")) end
    end)
    return tonumber(v)
end

local function pressR()
    local focused = nil
    pcall(function() focused = UserInputService:GetFocusedTextBox() end)
    if focused then return false end -- never type "r" into the chat
    if keypress and keyrelease then
        if pcall(function() keypress(0x52); task.wait(0.03); keyrelease(0x52) end) then return true end
    end
    return pcall(function()
        local vim = game:GetService("VirtualInputManager")
        vim:SendKeyEvent(true, Enum.KeyCode.R, false, game)
        task.wait(0.03)
        vim:SendKeyEvent(false, Enum.KeyCode.R, false, game)
    end)
end

local function gunEquipped()
    local t = Gun.tool
    return t ~= nil and t.Parent ~= nil and t.Parent == LocalPlayer.Character
end

local function requestReload(why)
    if not (Config.AutoReload and Running and gunEquipped()) then return end
    local now = os.clock()
    if now - Gun.lastReload < 0.6 then return end
    Gun.lastReload = now
    task.spawn(pressR)
    if Config.ReloadDebug then
        print(("[Reload] %s -> pressed R (%s, ammo %s/%s)"):format(
            Gun.tool.Name, why, tostring(readAmmo()), tostring(Gun.max)))
    end
end

local function onAmmo()
    local v = readAmmo()
    if not v then return end
    if v > Gun.max then Gun.max = v end
    if v <= 0 then requestReload("empty") end
end

-- fast reload: remember originals once, then apply/restore from them
local function learn(store, owner, key, cur)
    local orig = cur
    if math.abs(cur - FAST_RELOAD) < 1e-6 then orig = RL.normal[key] end -- copy of a sped-up value
    if orig then
        store[owner] = orig
        RL.normal[key] = RL.normal[key] or orig
    end
end

local function registerToolReload(tool)
    local list = { tool }
    for _, d in ipairs(tool:GetDescendants()) do list[#list + 1] = d end
    for _, d in ipairs(list) do
        local cn = d.ClassName
        if (cn == "NumberValue" or cn == "IntValue") and isReloadTimeName(d.Name)
            and RL.valOrig[d] == nil and type(d.Value) == "number" and d.Value > 0 then
            learn(RL.valOrig, d, d.Name, d.Value)
        end
        local ok, attrs = pcall(function() return d:GetAttributes() end)
        if ok then
            for k, v in pairs(attrs) do
                if type(v) == "number" and v > 0 and isReloadTimeName(k) then
                    local rec = RL.attrOrig[d]
                    if not (rec and rec[k] ~= nil) then
                        rec = rec or {}
                        RL.attrOrig[d] = rec
                        local tmp = {}
                        learn(tmp, k, k, v)
                        if tmp[k] then rec[k] = tmp[k] end
                    end
                end
            end
        end
    end
end

local lastGcFast = 0
local function gcFastScan(force)
    if not getgc then return end
    if not force and os.clock() - lastGcFast < 5 then return end
    lastGcFast = os.clock()
    local ok, gc = pcall(getgc, true)
    if not ok or type(gc) ~= "table" then return end
    for i = 1, #gc do
        if not Running then return end
        local t = gc[i]
        if type(t) == "table" and t ~= Config and t ~= RL then
            pcall(function()
                for k, v in next, t do
                    if type(v) == "number" and v > 0 and v <= 30 and isReloadTimeName(k) then
                        local rec = RL.tableOrig[t]
                        if not (rec and rec[k] ~= nil) then
                            local tmp = {}
                            learn(tmp, k, k, v)
                            if tmp[k] then
                                rec = rec or {}
                                RL.tableOrig[t] = rec
                                rec[k] = tmp[k]
                            end
                        end
                    end
                end
            end)
        end
        if i % 20000 == 0 then task.wait() end
    end
end

local function applyFast()
    local on = Config.FastReload and Running
    for d, orig in pairs(RL.valOrig) do
        if d.Parent then
            local want = on and math.min(orig, FAST_RELOAD) or orig
            pcall(function() if d.Value ~= want then d.Value = want end end)
        end
    end
    for inst, rec in pairs(RL.attrOrig) do
        if inst.Parent then
            for k, orig in pairs(rec) do
                local want = on and math.min(orig, FAST_RELOAD) or orig
                pcall(function() if inst:GetAttribute(k) ~= want then inst:SetAttribute(k, want) end end)
            end
        end
    end
    for t, rec in pairs(RL.tableOrig) do
        for k, orig in pairs(rec) do
            local want = on and math.min(orig, FAST_RELOAD) or orig
            pcall(function() if t[k] ~= want then t[k] = want end end)
        end
    end
end

local function unequipGun()
    for _, c in ipairs(Gun.conns) do pcall(function() c:Disconnect() end) end
    table.clear(Gun.conns)
    Gun.tool, Gun.src, Gun.max = nil, nil, 0
end

local function watchSource(src)
    local sig
    if src.kind == "value" then sig = src.obj:GetPropertyChangedSignal("Value")
    elseif src.kind == "attr" then sig = src.obj:GetAttributeChangedSignal(src.name)
    else sig = src.obj:GetPropertyChangedSignal("Text") end
    table.insert(Gun.conns, sig:Connect(onAmmo))
end

local function equipGun(tool)
    unequipGun()
    Gun.tool = tool
    local src = findAmmo(tool)
    if not src and Gun.label and Gun.label.Parent then
        src = { kind = "label", obj = Gun.label, name = "screen text" }
    end
    Gun.src = src
    if src then
        watchSource(src)
        Gun.max = readAmmo() or 0
    end
    pcall(registerToolReload, tool)
    if Config.FastReload then
        pcall(applyFast)
        task.spawn(function() pcall(gcFastScan); pcall(applyFast) end)
    end
end

-- no ammo value on the gun: learn the "6/6" style text on screen from your first shot
local function ammoLabels()
    local out = {}
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not pg then return out end
    for _, d in ipairs(pg:GetDescendants()) do
        if d.ClassName == "TextLabel" and d.Visible then
            local a = string.match(d.Text, "^%s*(%d+)%s*/%s*%d+")
            if a then out[d] = tonumber(a) end
        end
    end
    return out
end

Connections.reloadShot = UserInputService.InputBegan:Connect(function(input)
    local it = input.UserInputType
    if it ~= Enum.UserInputType.MouseButton1 and it ~= Enum.UserInputType.Touch then return end
    Gun.lastShot = os.clock()
    if Config.AutoReload and gunEquipped() and not Gun.src then
        local tool = Gun.tool
        local before = ammoLabels()
        task.delay(0.3, function()
            if Gun.tool ~= tool or Gun.src then return end
            for lbl, b in pairs(before) do
                local a = lbl.Parent and tonumber(string.match(lbl.Text, "^%s*(%d+)%s*/"))
                if a and a < b then
                    Gun.label = lbl
                    Gun.src = { kind = "label", obj = lbl, name = "screen text" }
                    Gun.max = math.max(b, a)
                    watchSource(Gun.src)
                    if Config.ReloadDebug then print("[Reload] learned ammo text on screen: " .. GetFullName(lbl)) end
                    onAmmo()
                    return
                end
            end
        end)
    end
end)

-- faster reload animation
local function hookAnimator(char)
    local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
    if not hum or not Running then return end
    local src = hum:FindFirstChildOfClass("Animator") or hum
    table.insert(Connections, src.AnimationPlayed:Connect(function(track)
        if not Running then return end
        local n = ""
        pcall(function()
            n = string.lower((track.Name or "") .. " " .. ((track.Animation and track.Animation.Name) or ""))
        end)
        if string.find(n, "reload", 1, true) then
            Gun.lastReload = os.clock()
            if Config.FastReload then
                pcall(function() track:AdjustSpeed(Config.ReloadAnimSpeed) end)
            end
        end
    end))
end

local function hookCharReload(char)
    table.insert(Connections, char.ChildAdded:Connect(function(t)
        if t:IsA("Tool") then equipGun(t) end
    end))
    table.insert(Connections, char.ChildRemoved:Connect(function(t)
        if t == Gun.tool then unequipGun() end
    end))
    for _, t in ipairs(char:GetChildren()) do
        if t:IsA("Tool") then equipGun(t) break end
    end
    task.spawn(hookAnimator, char)
end
if LocalPlayer.Character then hookCharReload(LocalPlayer.Character) end
Connections.reloadChar = LocalPlayer.CharacterAdded:Connect(hookCharReload)

RL.restore = function()
    unequipGun()
    pcall(applyFast) -- Running is false here, so everything goes back to normal
end

-- 5x per second: top-up check, toggle changes, status text
task.spawn(function()
    local lastFast = nil
    while Running do
        if Config.FastReload ~= lastFast then
            lastFast = Config.FastReload
            if Config.FastReload then
                if Gun.tool then pcall(registerToolReload, Gun.tool) end
                task.spawn(function() pcall(gcFastScan, true); pcall(applyFast) end)
            end
            pcall(applyFast)
        end

        local now = os.clock()
        local v = gunEquipped() and readAmmo() or nil
        if Config.AutoReload and Config.ReloadTopUp and v and Gun.max > 0 and v < Gun.max
            and now - Gun.lastShot > 0.8 and now - Gun.lastReload > 1.2 then
            local held = false
            pcall(function() held = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end)
            if not held then requestReload("top up") end
        end

        if ReloadLabel then
            local txt
            if not gunEquipped() then
                txt = "Reload: equip a gun"
            elseif not Gun.src then
                txt = "Reload: fire once so it finds the ammo"
            else
                txt = ("Reload: %s %s/%s"):format(Gun.tool.Name, tostring(v or "?"), tostring(Gun.max))
            end
            if ReloadLabel.Text ~= txt then ReloadLabel.Text = txt end
        end
        task.wait(0.2)
    end
end)

----------------------------------------------------------------
-- (fix) The Luau compiler allows at most 200 local variables in one
-- function. This script has more than that, so everything from here to the
-- end (GUI + main loop) lives inside its own function, which gets its own
-- budget of 200. buildGui() is called on the last line.
----------------------------------------------------------------
local function buildGui()

----------------------------------------------------------------
-- GUI
----------------------------------------------------------------
local parent = (gethui and gethui()) or game:GetService("CoreGui")
local old = parent:FindFirstChild("DeadRailsAim")
if old then old:Destroy() end

Gui = Instance.new("ScreenGui")
Gui.Name = "DeadRailsAim"
Gui.ResetOnSpawn = false
Gui.Parent = parent

----------------------------------------------------------------
-- (tabs) The tab list is its own bar pinned to the TOP of your screen.
-- Click a tab to open that page in the window; click the open tab again
-- to close the window. The window can be resized (corner grip or the
-- size setting in Settings) and moved by its title bar.
----------------------------------------------------------------
local ACCENT = Color3.fromRGB(150, 40, 40)
local UI = env.DRUISize or { w = 360, h = 400, scale = 1 } -- kept between re-runs
env.DRUISize = UI
Config.UIScale = math.floor((UI.scale or 1) * 100 + 0.5)

-- scale applies to the window only (not the FOV circle)
local Scale = Instance.new("UIScale")
Scale.Scale = UI.scale or 1

local Main = Instance.new("Frame")
Main.Size = UDim2.fromOffset(UI.w, UI.h)
Main.Position = UDim2.new(0.5, -UI.w / 2, 0, 64)
Main.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
Main.BorderSizePixel = 0
Main.Active = true
Main.Draggable = true
Main.ClipsDescendants = true
Main.Parent = Gui
Scale.Parent = Main
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 8)

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, 0, 0, 34)
Title.BackgroundColor3 = ACCENT
Title.BorderSizePixel = 0
Title.Text = "  Dead Rails Silent Aim"
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.TextColor3 = Color3.new(1, 1, 1)
Title.Font = Enum.Font.GothamBold
Title.TextSize = 15
Title.Parent = Main
Instance.new("UICorner", Title).CornerRadius = UDim.new(0, 8)

local Hint = Instance.new("TextLabel")
Hint.Size = UDim2.new(0, 160, 1, 0)
Hint.Position = UDim2.new(1, -168, 0, 0)
Hint.BackgroundTransparency = 1
Hint.Text = "RightCtrl: hide / show"
Hint.TextXAlignment = Enum.TextXAlignment.Right
Hint.TextColor3 = Color3.fromRGB(235, 200, 200)
Hint.Font = Enum.Font.Gotham
Hint.TextSize = 12
Hint.Parent = Title

-- tab bar: lives INSIDE the window, so there is only one GUI and it moves as one piece
local TabBar = Instance.new("Frame")
TabBar.Name = "TabBar"
TabBar.Position = UDim2.fromOffset(8, 38)
TabBar.Size = UDim2.new(1, -16, 0, 30)
TabBar.BackgroundTransparency = 1
TabBar.BorderSizePixel = 0
TabBar.Parent = Main
local TabLayout = Instance.new("UIListLayout", TabBar)
TabLayout.FillDirection = Enum.FillDirection.Horizontal
TabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
TabLayout.Padding = UDim.new(0, 4)
TabLayout.SortOrder = Enum.SortOrder.LayoutOrder

-- page area (whole window under the title)
local PageArea = Instance.new("Frame")
PageArea.Size = UDim2.new(1, -16, 1, -78)
PageArea.Position = UDim2.fromOffset(8, 72)
PageArea.BackgroundTransparency = 1
PageArea.Parent = Main

-- resize grip (bottom-right corner): drag it to change the window size
local Grip = Instance.new("TextButton")
Grip.Size = UDim2.fromOffset(18, 18)
Grip.AnchorPoint = Vector2.new(1, 1)
Grip.Position = UDim2.new(1, -2, 1, -2)
Grip.BackgroundTransparency = 1
Grip.Text = "◢"
Grip.TextColor3 = Color3.fromRGB(150, 150, 160)
Grip.TextSize = 14
Grip.Font = Enum.Font.GothamBold
Grip.ZIndex = 5
Grip.Parent = Main

local MIN_W, MIN_H, MAX_W, MAX_H = 260, 220, 900, 800
local resizing, rsStart, rsSize = false, nil, nil
Grip.MouseButton1Down:Connect(function()
    resizing = true
    rsStart = UserInputService:GetMouseLocation()
    rsSize = Vector2.new(Main.AbsoluteSize.X, Main.AbsoluteSize.Y) / Scale.Scale
    Main.Draggable = false
end)
Connections.resizeMove = UserInputService.InputChanged:Connect(function(input)
    if resizing and input.UserInputType == Enum.UserInputType.MouseMovement then
        local d = (UserInputService:GetMouseLocation() - rsStart) / Scale.Scale
        UI.w = math.clamp(math.floor(rsSize.X + d.X), MIN_W, MAX_W)
        UI.h = math.clamp(math.floor(rsSize.Y + d.Y), MIN_H, MAX_H)
        Main.Size = UDim2.fromOffset(UI.w, UI.h)
    end
end)
Connections.resizeEnd = UserInputService.InputEnded:Connect(function(input)
    if resizing and input.UserInputType == Enum.UserInputType.MouseButton1 then
        resizing = false
        Main.Draggable = true
    end
end)

local Tabs = {} -- name -> { button, page }
local TabOrder = 0
local Holder -- the page new controls go into (set by setTab)
local CurrentTab

-- keeps controls in the order they were added
local function nextOrder()
    CurrentTab.n = CurrentTab.n + 1
    return CurrentTab.n
end

local OpenTab = nil
local function selectTab(name)
    OpenTab = name
    for n, t in pairs(Tabs) do
        local on = (n == name)
        t.page.Visible = on
        t.button.BackgroundColor3 = on and ACCENT or Color3.fromRGB(42, 42, 50)
        t.button.TextColor3 = on and Color3.new(1, 1, 1) or Color3.fromRGB(190, 190, 200)
    end
    if name then Title.Text = "  Dead Rails  |  " .. name end
end

-- creates the tab the first time, then makes it the target for new controls
local function setTab(name)
    if not Tabs[name] then
        TabOrder = TabOrder + 1
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0.2, -4, 0, 28)
        b.LayoutOrder = TabOrder
        b.BorderSizePixel = 0
        b.AutoButtonColor = true
        b.Text = name
        b.Font = Enum.Font.GothamBold
        b.TextSize = 13
        b.TextScaled = true
        b.Parent = TabBar
        Instance.new("UITextSizeConstraint", b).MaxTextSize = 13
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)

        local page = Instance.new("ScrollingFrame")
        page.Size = UDim2.new(1, 0, 1, 0)
        page.BackgroundTransparency = 1
        page.BorderSizePixel = 0
        page.ScrollBarThickness = 4
        page.CanvasSize = UDim2.new(0, 0, 0, 0)
        page.AutomaticCanvasSize = Enum.AutomaticSize.Y
        page.Visible = false
        page.Parent = PageArea
        local l = Instance.new("UIListLayout", page)
        l.Padding = UDim.new(0, 6)
        l.SortOrder = Enum.SortOrder.LayoutOrder
        local p = Instance.new("UIPadding", page)
        p.PaddingRight = UDim.new(0, 6)

        Tabs[name] = { button = b, page = page, n = 0 }
        b.MouseButton1Click:Connect(function() selectTab(name) end)
        if TabOrder == 1 then selectTab(name) end
    end
    Holder = Tabs[name].page
    CurrentTab = Tabs[name]
end

local ON, OFF = Color3.fromRGB(46, 160, 90), Color3.fromRGB(60, 60, 68)

local function makeButton(text)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 30)
    b.BackgroundColor3 = OFF
    b.BorderSizePixel = 0
    b.Text = text
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.Gotham
    b.TextSize = 14
    b.LayoutOrder = nextOrder()
    b.Parent = Holder
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end

local function makeLabel(text)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, 0, 0, 18)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = Color3.fromRGB(170, 170, 180)
    l.Font = Enum.Font.GothamBold
    l.TextSize = 12
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.LayoutOrder = nextOrder()
    l.Parent = Holder
    return l
end

local function makeToggle(text, get, set)
    local b = makeButton("")
    local function refresh()
        b.Text = text .. ": " .. (get() and "ON" or "OFF")
        b.BackgroundColor3 = get() and ON or OFF
    end
    b.MouseButton1Click:Connect(function() set(not get()); refresh() end)
    refresh()
    return b
end

-- Left click = increase, right click = decrease
local function makeAdjuster(label, key, step, min, max, decimals)
    local b = makeButton("")
    b.BackgroundColor3 = Color3.fromRGB(70, 90, 160)
    local function refresh()
        b.Text = ("%s: %s  [L +  /  R -]"):format(label, tostring(Config[key]))
    end
    local function change(dir)
        local v = math.clamp(Config[key] + step * dir, min, max)
        local m = 10 ^ decimals
        Config[key] = math.floor(v * m + 0.5) / m
        refresh()
    end
    b.MouseButton1Click:Connect(function() change(1) end)
    b.MouseButton2Click:Connect(function() change(-1) end)
    refresh()
    return b
end

-- (tabs) tab order: Aim, Visuals, Gun, Items, Settings
setTab("Aim")
setTab("Visuals")
setTab("Gun")
setTab("Items")
setTab("Settings")

----------------------------------------------------------------
-- AIM TAB
----------------------------------------------------------------
setTab("Aim")

-- Master toggle
if not HooksSupported then makeLabel("Needs hook support (executor)") end
makeToggle("Silent Aim", function() return Config.Silent end, function(v) Config.Silent = v end)

-- Aim part selector
makeLabel("AIM PART")
local partButton = makeButton("")
local function refreshPart()
    partButton.Text = "Aim at: " .. Config.AimPart
    partButton.BackgroundColor3 = Color3.fromRGB(70, 90, 160)
end
partButton.MouseButton1Click:Connect(function()
    Config.AimPart = (Config.AimPart == "Head") and "Torso" or "Head"
    refreshPart()
end)
refreshPart()

-- Target type toggles
makeLabel("TARGETS")
for _, kind in ipairs({ "Zombie", "Werewolf", "Outlaw", "Other" }) do
    makeToggle(kind, function() return Config.Targets[kind] end, function(v) Config.Targets[kind] = v end)
end

-- FOV
makeLabel("FOV")
makeAdjuster("FOV radius", "FOV", 50, 25, 3000, 0)
makeToggle("Unlimited FOV (360)", function() return Config.Unlimited end, function(v) Config.Unlimited = v end)
makeAdjuster("Max distance", "MaxDistance", 50, 50, 2000, 0)
makeToggle("Show FOV circle", function() return Config.ShowFOV end, function(v) Config.ShowFOV = v end)

-- Lead (helps with fast movers like werewolves)
makeLabel("LEAD")
local PingLabel = makeLabel("Ping: ...")
makeToggle("Lead moving targets", function() return Config.Lead end, function(v) Config.Lead = v end)
makeToggle("Auto lead (ping)", function() return Config.AutoLead end, function(v) Config.AutoLead = v end)
makeAdjuster("Extra lead (s)", "LeadTime", 0.02, 0, 0.4, 2)

-- Options
makeLabel("OPTIONS")
makeToggle("Wall Check", function() return Config.WallCheck end, function(v) Config.WallCheck = v end)

makeToggle("Log Gun Remotes", function() return Config.LogRemotes end, function(v) Config.LogRemotes = v end)

-- Debug: prints what the script detects (open the console with F9)
local dbg = makeButton("Debug: print NPCs")
dbg.MouseButton1Click:Connect(function()
    print(("[DeadRailsAim] %d NPC models detected"):format(#NPCs))
    for i, npc in ipairs(NPCs) do
        if i > 20 then break end
        local m = npc.model
        print(("  %s | kind=%s | Head=%s HRP=%s UpperTorso=%s Torso=%s | path=%s"):format(
            m.Name, npc.kind,
            tostring(m:FindFirstChild("Head") ~= nil),
            tostring(m:FindFirstChild("HumanoidRootPart") ~= nil),
            tostring(m:FindFirstChild("UpperTorso") ~= nil),
            tostring(m:FindFirstChild("Torso") ~= nil),
            m:GetFullName()))
    end
end)

----------------------------------------------------------------
-- VISUALS TAB
----------------------------------------------------------------
setTab("Visuals")

makeLabel("WORLD")
makeToggle("Fullbright", function() return Config.Fullbright end, function(v) Config.Fullbright = v end)
makeToggle("No fog", function() return Config.NoFog end, function(v) Config.NoFog = v end)

-- Vault ESP (added)
makeLabel("VAULT")
makeToggle("Vault ESP + code", function() return Config.VaultESP end, function(v) Config.VaultESP = v end)

-- live list of every vault code with its town number
makeLabel("VAULT CODES")
local codeLabel = makeLabel("No vaults found yet")
codeLabel.Size = UDim2.new(1, 0, 0, 0)
codeLabel.AutomaticSize = Enum.AutomaticSize.Y
codeLabel.TextWrapped = true
codeLabel.TextSize = 15
codeLabel.Font = Enum.Font.GothamBold
codeLabel.TextColor3 = Color3.fromRGB(255, 210, 60)
codeLabel.TextYAlignment = Enum.TextYAlignment.Top
task.spawn(function()
    while Running do
        local ok, txt = pcall(vaultText)
        if ok and codeLabel.Text ~= txt then codeLabel.Text = txt end
        task.wait(0.5)
    end
end)
local vcopy = makeButton("Copy all codes")
vcopy.MouseButton1Click:Connect(function()
    if setclipboard then pcall(setclipboard, vaultText()) end
end)

local vdeep = makeButton("Deep scan for code (F9)")
vdeep.MouseButton1Click:Connect(function() task.spawn(function() pcall(deepScan) end) end)
local vdbg = makeButton("Debug: dump vault data")
vdbg.MouseButton1Click:Connect(function() pcall(dumpVaults) end)

----------------------------------------------------------------
-- GUN TAB
----------------------------------------------------------------
setTab("Gun")

makeLabel("RELOAD")
makeToggle("Auto reload", function() return Config.AutoReload end, function(v) Config.AutoReload = v end)
makeToggle("Top up when not full", function() return Config.ReloadTopUp end, function(v) Config.ReloadTopUp = v end)
makeToggle("Fast reload", function() return Config.FastReload end, function(v) Config.FastReload = v end)
makeAdjuster("Reload anim speed", "ReloadAnimSpeed", 1, 1, 15, 0)
makeToggle("Reload debug (F9)", function() return Config.ReloadDebug end, function(v) Config.ReloadDebug = v end)
ReloadLabel = makeLabel("Reload: equip a gun")
local rlrep = makeButton("Reload: report (F9)")
rlrep.MouseButton1Click:Connect(function()
    task.spawn(function()
        if Gun.tool then pcall(registerToolReload, Gun.tool) end
        pcall(gcFastScan, true)
        pcall(applyFast)
        local nt = 0
        for _, rec in pairs(RL.tableOrig) do nt = nt + countKeys(rec) end
        print(("[Reload] gun: %s | ammo source: %s (%s) | ammo %s/%s"):format(
            Gun.tool and Gun.tool.Name or "none",
            Gun.src and Gun.src.kind or "not found",
            Gun.src and tostring(Gun.src.name) or "-",
            tostring(readAmmo()), tostring(Gun.max)))
        print(("[Reload] reload-time settings: gun values %d, gun attributes %d, script settings %d | keypress=%s"):format(
            countKeys(RL.valOrig), countKeys(RL.attrOrig), nt, tostring(keypress ~= nil)))
    end)
end)

----------------------------------------------------------------
-- ITEMS TAB
----------------------------------------------------------------
setTab("Items")

-- Ammo aura (v2)
makeLabel("COLLECT")
makeToggle("Ammo aura", function() return Config.AmmoAura end, function(v) Config.AmmoAura = v end)
makeToggle("Skip shop items", function() return Config.SkipShop end, function(v) Config.SkipShop = v end)
makeToggle("Also money bags", function() return Config.CollectMoney end, function(v) Config.CollectMoney = v end)
makeAdjuster("Aura radius", "AuraRadius", 2, 6, 30, 0)
makeAdjuster("Items per sweep", "AuraBurst", 1, 1, 15, 0)
makeToggle("Aura debug (F9)", function() return Config.AuraDebug end, function(v) Config.AuraDebug = v end)
local adbg = makeButton("Debug: list nearby ammo")
adbg.MouseButton1Click:Connect(function() pcall(listPickups) end)
local aclr = makeButton("Clear learned shop spots")
aclr.MouseButton1Click:Connect(function()
    table.clear(ShopSpots)
    for _, e in pairs(Pickups) do e.shop, e.shopT = nil, nil end
end)
CollectLabel = makeLabel("Aura: idle")

-- Reach (added)
makeLabel("REACH")
local reachToggle = makeToggle("Reach (grab items far)", function() return Config.Reach end, function(v) Config.Reach = v end)
makeAdjuster("Reach distance", "ReachDist", 5, 10, 150, 0)
ReachLabel = makeLabel("Reach: OFF (normal distance)")
local rscan = makeButton("Reach: rescan + report (F9)")
rscan.MouseButton1Click:Connect(function()
    task.spawn(function()
        pcall(reachScan)
        pcall(applyReach)
        local ns = 0
        for _, rec in pairs(TableOrig) do ns = ns + countKeys(rec) end
        print(("[Reach] hook=%s | prompts/clickers tracked %d | drag settings found %d | reach %s studs (%s)"):format(
            tostring(HooksSupported), countKeys(PromptOrig), ns, tostring(Config.ReachDist), Config.Reach and "ON" or "OFF"))
    end)
end)
local rreset = makeButton("Reach: reset to normal")
rreset.MouseButton1Click:Connect(function()
    Config.Reach = false
    reachToggle.Text = "Reach (grab items far): OFF"
    reachToggle.BackgroundColor3 = OFF
    task.spawn(function()
        pcall(reachScan)
        pcall(Reach.restore)
        print("[Reach] everything set back to the game's normal distances")
    end)
end)

-- Air weld (added)
makeLabel("AIR WELD")
makeToggle("Air weld (weld in the air)", function() return Config.AirWeld end, function(v) Config.AirWeld = v end)
makeAdjuster("Max train distance", "AirWeldRange", 10, 20, 300, 0)
makeToggle("Log weld remote (F9)", function() return Config.LogWeld end, function(v) Config.LogWeld = v end)
AirLabel = makeLabel("Air weld: off")
local awdbg = makeButton("Air weld: report (F9)")
awdbg.MouseButton1Click:Connect(function()
    local p, d = nil, nil
    if AW.heldPos then p, d = nearestTrainPart(AW.heldPos) end
    print(("[AirWeld] hook=%s | train models found %d | holding %s | nearest train part %s (%s st)"):format(
        tostring(HooksSupported), countKeys(TrainModels),
        AW.held and GetFullName(AW.held) or "nothing",
        p and GetFullName(p) or "none", d and tostring(math.floor(d)) or "-"))
    for m in pairs(TrainModels) do print("   train model: " .. GetFullName(m)) end
end)

----------------------------------------------------------------
-- SETTINGS TAB
----------------------------------------------------------------
setTab("Settings")

makeLabel("MENU")
makeLabel("Tabs are at the top of the window")
makeLabel("RightCtrl hides / shows the window")
makeLabel("Drag the title bar or empty space to move it")
makeLabel("Drag the ◢ corner to resize it")

makeLabel("SIZE")
makeAdjuster("Menu scale (%)", "UIScale", 10, 60, 200, 0)
local rsz = makeButton("Reset size + position")
rsz.MouseButton1Click:Connect(function()
    UI.w, UI.h, UI.scale = 360, 400, 1
    Config.UIScale = 100
    Scale.Scale = 1
    Main.Size = UDim2.fromOffset(UI.w, UI.h)
    Main.Position = UDim2.new(0.5, -UI.w / 2, 0, 64)
end)

-- applies the scale setting (only when it changes)
task.spawn(function()
    while Running do
        local s = math.clamp((Config.UIScale or 100) / 100, 0.6, 2)
        if math.abs(Scale.Scale - s) > 1e-3 then
            Scale.Scale = s
            UI.scale = s
        end
        task.wait(0.2)
    end
end)

makeLabel("SCRIPT")
makeToggle("Console output (debug)", function() return Console.on end, function(v) Console.on = v end)
-- Quit: fully unloads the script (GUI, loops, connections)
local quit = makeButton("Quit / Unload")
quit.BackgroundColor3 = Color3.fromRGB(170, 45, 45)
quit.MouseButton1Click:Connect(Unload)

-- FOV circle
local Circle = Instance.new("Frame")
Circle.AnchorPoint = Vector2.new(0.5, 0.5)
Circle.BackgroundTransparency = 1
Circle.Parent = Gui
Instance.new("UICorner", Circle).CornerRadius = UDim.new(1, 0)
local stroke = Instance.new("UIStroke", Circle)
stroke.Color = Color3.fromRGB(80, 160, 255)
stroke.Thickness = 1.5

Connections.input = UserInputService.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightControl then
        Main.Visible = not Main.Visible
    end
end)

----------------------------------------------------------------
-- MAIN LOOP (never touches the camera)
----------------------------------------------------------------
local lastPingUpdate = 0
local lastPingSample = 0
local lastVelTrack = 0
local lastPick = 0
local cachedPart, cachedNpc = nil, nil

Connections.render = RunService.RenderStepped:Connect(function()
    Camera = Workspace.CurrentCamera
    local nowT = os.clock()
    -- lag fix: velocity at 30/s, ping at 2/s instead of every frame
    if nowT - lastVelTrack > 1 / 30 then
        lastVelTrack = nowT
        trackVelocities()
    end
    if nowT - lastPingSample > 0.5 then
        lastPingSample = nowT
        samplePing()
    end
    if nowT - lastPingUpdate > 0.25 and Main.Visible then
        lastPingUpdate = nowT
        PingLabel.Text = ("Ping: %d ms  |  auto lead: %.3fs"):format(PingMs, autoLead())
    end

    local mouse = UserInputService:GetMouseLocation()
    local inset = GuiService:GetGuiInset()
    Circle.Visible  = Config.ShowFOV and Config.Silent and not Config.Unlimited
    Circle.Size     = UDim2.fromOffset(Config.FOV * 2, Config.FOV * 2)
    Circle.Position = UDim2.fromOffset(mouse.X, mouse.Y - inset.Y)

    Silent.log = Config.LogRemotes
    Silent.active, Silent.point, Silent.part = false, nil, nil
    if not (Config.Silent and HooksSupported) then return end

    -- lag fix: re-pick the target 30x/s (wall-check raycasts are the costly part)
    if nowT - lastPick > 1 / 30 then
        lastPick = nowT
        cachedPart, cachedNpc = pickTarget(mouse)
    end
    local part, npc = cachedPart, cachedNpc
    if part and not (part.Parent and npc and npc.humanoid.Health > 0) then
        part, npc = nil, nil
    end
    if part then
        local vel, lead = Vector3.zero, 0
        local st = npc and Track[npc.model]
        if Config.Lead and st then
            vel  = st.vel
            lead = Config.LeadTime
            if Config.AutoLead then lead = lead + autoLead() end
        end
        Silent.part, Silent.base, Silent.vel, Silent.lead, Silent.t = part, part.Position, vel, lead, os.clock()
        Silent.point, Silent.active = part.Position, true
    end
end)
-- ===== END =====

end -- (fix) closes buildGui
buildGui()