local _ENV = (getgenv or getrenv or getfenv)()

local Module, Settings = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/vita8it/Opengame/main/utils/package.luau"
))()

local Queue = Module.GoodQueue:Create()
local Plugins = Module.Plugins
local Connections = Module.Connections

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local PreviousESP = _ENV.NextESP

if PreviousESP and PreviousESP.Clear then
    PreviousESP:Clear()
end

local Folder = gethui and gethui()

if Folder then
    for Index, Value in Folder:GetChildren() do
        if Value.Name:find("Next.js") then
            Value:Destroy()
        end
    end
end

Module:CreateModule("Aimbot", function(Module)
    local Aimbot = {}

    local Shared = ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Shared")
    local DeagleShared = require(Shared:WaitForChild("DeagleShared"))

    local CachedTarget = nil

    if not _ENV.NextOriginalRaycast then
        _ENV.NextOriginalRaycast = DeagleShared.Raycast
    end

    function Aimbot:IsAlive(Character)
        if not Character or not Character.Parent then
            return false
        end

        if Character:GetAttribute("Alive") == false then
            return false
        end

        local Humanoid = Character:FindFirstChildOfClass("Humanoid")

        if not Humanoid or Humanoid.Health <= 0 then
            return false
        end

        return true
    end

    function Aimbot:IsEnemy(Player)
        if not Settings.CheckTeam then
            return true
        end

        local LocalTeam = LocalPlayer.Team

        if not LocalTeam or Player.Neutral or LocalPlayer.Neutral then
            return true
        end

        return Player.Team ~= LocalTeam
    end

    function Aimbot:IsValidTarget(Target)
        local Character = Target.Character
        local IsBot = Character and Character:GetAttribute("IsBot") == true

        if not IsBot and Target == LocalPlayer then
            return false
        end

        if not Character or not Character.Parent then
            return false
        end

        if not IsBot and not self:IsEnemy(Target) then
            return false
        end

        return self:IsAlive(Character)
    end

    function Aimbot:GetTargets()
        local Targets = {}

        for Index, Player in Players:GetPlayers() do
            table.insert(Targets, Player)
        end

        if Settings.TargetBots then
            for Index, Model in workspace:GetChildren() do
                if not Model:IsA("Model") then
                    continue
                end

                if Model:GetAttribute("IsBot") ~= true then
                    continue
                end

                if Model == LocalPlayer.Character then
                    continue
                end

                local Bot = {}
                Bot.Name = Model.Name
                Bot.Character = Model

                table.insert(Targets, Bot)
            end
        end

        return Targets
    end

    function Aimbot:GetTargetPosition(Character)
        local HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart")

        if not HumanoidRootPart then
            return nil
        end

        local PartName = Settings.TargetPart or "HumanoidRootPart"
        local Part = Character:FindFirstChild(PartName) or HumanoidRootPart

        return Part.Position
    end

    function Aimbot:IsVisible(From, Position, Target)
        if not Settings.CheckWall then
            return true
        end

        local Character = LocalPlayer.Character
        local TargetCharacter = Target and Target.Character

        if not Character or not TargetCharacter then
            return false
        end

        local Params = RaycastParams.new()
        Params.FilterType = Enum.RaycastFilterType.Exclude
        Params.FilterDescendantsInstances = { Character, TargetCharacter }

        local Direction = Position - From
        local Result = workspace:Raycast(From, Direction, Params)

        if not Result then
            return true
        end

        return Result.Instance:IsDescendantOf(TargetCharacter)
    end

    function Aimbot:IsWithinFOV(Position)
        local ActiveCamera = workspace.CurrentCamera

        if not ActiveCamera then
            return false
        end

        local Point, OnScreen = ActiveCamera:WorldToViewportPoint(Position)

        if not OnScreen then
            return false
        end

        local Center = ActiveCamera.ViewportSize / 2
        local CrosshairDistance = (Vector2.new(Point.X, Point.Y) - Center).Magnitude

        return CrosshairDistance <= (Settings.FOV or 100)
    end

    function Aimbot:FindTarget(From)
        local MaxDistance = Settings.Distance or 300
        local TargetMode = Settings.TargetMode or "Nearest"
        local BestTarget = nil
        local BestPosition = nil
        local BestDistance = math.huge

        if CachedTarget and self:IsValidTarget(CachedTarget) then
            local CachedPosition = self:GetTargetPosition(CachedTarget.Character)

            if CachedPosition then
                local CachedDistance = (CachedPosition - From).Magnitude

                if CachedDistance <= MaxDistance and self:IsVisible(From, CachedPosition, CachedTarget) then
                    BestTarget = CachedTarget
                    BestPosition = CachedPosition
                    BestDistance = CachedDistance
                end
            end
        end

        for Index, Target in self:GetTargets() do
            if not self:IsValidTarget(Target) then
                continue
            end

            local Position = self:GetTargetPosition(Target.Character)

            if not Position then
                continue
            end

            local Distance = (Position - From).Magnitude

            if Distance > MaxDistance then
                continue
            end

            if TargetMode == "FOV" and not self:IsWithinFOV(Position) then
                continue
            end

            if not self:IsVisible(From, Position, Target) then
                continue
            end

            if Distance >= BestDistance then
                continue
            end

            BestTarget = Target
            BestPosition = Position
            BestDistance = Distance
        end

        if BestTarget then
            CachedTarget = BestTarget
        end

        return BestTarget, BestPosition
    end

    function Aimbot:Enable()
        if self.Hooked then
            return
        end

        self.Hooked = true

        DeagleShared.Raycast = function(Origin, From, To)
            local Success, Target, TargetPosition = pcall(Aimbot.FindTarget, Aimbot, From)

            if Success and Target and TargetPosition then
                return self.OriginalRaycast(Origin, From, TargetPosition)
            end

            return self.OriginalRaycast(Origin, From, To)
        end
    end

    function Aimbot:Disable()
        if not self.Hooked then
            return
        end

        self.Hooked = false

        DeagleShared.Raycast = self.OriginalRaycast
    end

    Aimbot.OriginalRaycast = _ENV.NextOriginalRaycast

    return Aimbot
end)

Module:CreateModule("ESP", function(Module)
    local ESP = {}

    local Cached = {}
    local ColorMap = {
        Red = Color3.fromRGB(255, 60, 60),
        Orange = Color3.fromRGB(255, 150, 40),
        Yellow = Color3.fromRGB(255, 220, 60),
        Green = Color3.fromRGB(80, 255, 100),
        Cyan = Color3.fromRGB(60, 220, 255),
        Blue = Color3.fromRGB(90, 130, 255),
        Purple = Color3.fromRGB(190, 90, 255),
        Pink = Color3.fromRGB(255, 120, 200),
    }

    local Circle = Drawing.new("Circle")
    Circle.Thickness = 1
    Circle.Filled = false
    Circle.Visible = false

    function ESP:IsAlive(Character)
        if not Character or not Character.Parent then
            return false
        end

        if Character:GetAttribute("Alive") == false then
            return false
        end

        local Humanoid = Character:FindFirstChildOfClass("Humanoid")

        if not Humanoid or Humanoid.Health <= 0 then
            return false
        end

        return true
    end

    function ESP:IsEnemy(Player)
        if not Settings.ESPCheckTeam then
            return true
        end

        local LocalTeam = LocalPlayer.Team

        if not LocalTeam or Player.Neutral or LocalPlayer.Neutral then
            return true
        end

        return Player.Team ~= LocalTeam
    end

    function ESP:IsValidTarget(Target)
        local Character = Target.Character
        local IsBot = Character and Character:GetAttribute("IsBot") == true

        if not IsBot and Target == LocalPlayer then
            return false
        end

        if not Character or not Character.Parent then
            return false
        end

        if not IsBot and not self:IsEnemy(Target) then
            return false
        end

        return self:IsAlive(Character)
    end

    function ESP:GetTargets()
        local Targets = {}

        for Index, Player in Players:GetPlayers() do
            table.insert(Targets, Player)
        end

        if Settings.ESPTargetBots then
            for Index, Model in workspace:GetChildren() do
                if not Model:IsA("Model") then
                    continue
                end

                if Model:GetAttribute("IsBot") ~= true then
                    continue
                end

                if Model == LocalPlayer.Character then
                    continue
                end

                local Bot = {}
                Bot.Name = Model.Name
                Bot.Character = Model

                table.insert(Targets, Bot)
            end
        end

        return Targets
    end

    function ESP:GetColor()
        local Name = Settings.ESPColor or "Red"

        return ColorMap[ Name ] or ColorMap.Red
    end

    function ESP:CreateSquare()
        local Box = Drawing.new("Square")
        Box.Thickness = 1
        Box.Visible = false

        return Box
    end

    function ESP:CreateText()
        local Name = Drawing.new("Text")
        Name.Center = true
        Name.Outline = true
        Name.OutlineColor = Color3.new(0, 0, 0)
        Name.Visible = false

        return Name
    end

    function ESP:CreateLine()
        local Tracer = Drawing.new("Line")
        Tracer.Thickness = 1
        Tracer.Visible = false

        return Tracer
    end

    function ESP:CreateData(Target)
        return {
            Box = ESP:CreateSquare(),
            Outline = ESP:CreateSquare(),
            Name = ESP:CreateText(),
            Tracer = ESP:CreateLine(),
        }
    end

    function ESP:HideData(Data)
        Data.Box.Visible = false
        Data.Outline.Visible = false
        Data.Name.Visible = false
        Data.Tracer.Visible = false
    end

    function ESP:Hide()
        for Index, Data in Cached do
            ESP:HideData(Data)
        end

        Circle.Visible = false
    end

    ESP.RemovePlayer = function(Player)
        local Data = Cached[ Player ]

        if not Data then
            return
        end

        Data.Box:Remove()
        Data.Outline:Remove()
        Data.Name:Remove()
        Data.Tracer:Remove()

        Cached[ Player ] = nil
    end

    function ESP:UpdateBox(Box, Outline, HeadPoint, RootPoint, Opacity)
        local Height = RootPoint.Y - HeadPoint.Y

        if Height <= 0 then
            Box.Visible = false
            Outline.Visible = false

            return
        end

        local Width = math.max(Height * 0.6, 4)

        if Settings.ESPBoxOutline then
            Outline.Filled = true
            Outline.Position = Vector2.new(RootPoint.X - Width / 2, HeadPoint.Y) - Vector2.new(1, 1)
            Outline.Size = Vector2.new(Width, Height) + Vector2.new(2, 2)
            Outline.Color = Color3.new(0, 0, 0)
            Outline.Transparency = Opacity
            Outline.Visible = true
        else
            Outline.Visible = false
        end

        Box.Position = Vector2.new(RootPoint.X - Width / 2, HeadPoint.Y)
        Box.Size = Vector2.new(Width, Height)
        Box.Color = self:GetColor()
        Box.Transparency = Opacity
        Box.Visible = true
    end

    function ESP:UpdateName(Name, Target, HeadPoint, Distance, Opacity)
        local Text = Target.Name

        if Settings.ESPShowDistance then
            Text ..= string.format(" [%dm]", math.round(Distance))
        end

        Name.Position = Vector2.new(HeadPoint.X, HeadPoint.Y - 16)
        Name.Text = Text
        Name.Color = self:GetColor()
        Name.Size = Settings.ESPNameSize or 13
        Name.Transparency = Opacity
        Name.Visible = true
    end

    function ESP:UpdateTracer(Tracer, RootPoint, Opacity)
        local Camera = workspace.CurrentCamera

        if not Camera then
            return
        end

        local ViewportSize = Camera.ViewportSize

        Tracer.From = Vector2.new(ViewportSize.X / 2, ViewportSize.Y)
        Tracer.To = Vector2.new(RootPoint.X, RootPoint.Y)
        Tracer.Color = self:GetColor()
        Tracer.Transparency = Opacity
        Tracer.Visible = true
    end

    function ESP:UpdateCircle(Opacity)
        local Camera = workspace.CurrentCamera

        if not Camera then
            return
        end

        Circle.Position = Camera.ViewportSize / 2
        Circle.Radius = Settings.ESPFOV or 100
        Circle.Color = self:GetColor()
        Circle.Transparency = Opacity
        Circle.Visible = true
    end

    function ESP:UpdatePlayer(Target, Camera, Opacity)
        local Character = Target.Character
        local IsBot = Character and Character:GetAttribute("IsBot") == true
        local Key = IsBot and Character or Target
        local Data = Cached[ Key ]

        if not Data then
            Data = ESP:CreateData(Target)
            Cached[ Key ] = Data
        end

        if not self:IsValidTarget(Target) then
            self:HideData(Data)

            return
        end

        local Character = Target.Character
        local HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart")

        if not HumanoidRootPart then
            self:HideData(Data)

            return
        end

        local RootPosition = HumanoidRootPart.Position
        local Distance = (RootPosition - Camera.CFrame.Position).Magnitude
        local MaxDistance = Settings.ESPDistance or 300

        if Distance > MaxDistance then
            self:HideData(Data)

            return
        end

        local Head = Character:FindFirstChild("Head") or HumanoidRootPart
        local HeadPosition = Head.Position
        local RootPoint, RootOnScreen = Camera:WorldToViewportPoint(RootPosition)
        local HeadPoint, HeadOnScreen = Camera:WorldToViewportPoint(HeadPosition)

        if not RootOnScreen or not HeadOnScreen then
            self:HideData(Data)

            return
        end

        if Settings.ESPBox then
            self:UpdateBox(Data.Box, Data.Outline, HeadPoint, RootPoint, Opacity)
        else
            Data.Box.Visible = false
        end

        if Settings.ESPName then
            self:UpdateName(Data.Name, Target, HeadPoint, Distance, Opacity)
        else
            Data.Name.Visible = false
        end

        if Settings.ESPTracer then
            self:UpdateTracer(Data.Tracer, RootPoint, Opacity)
        else
            Data.Tracer.Visible = false
        end
    end

    function ESP:Update()
        local Enabled = Settings.ESP

        if not Enabled then
            self:Hide()

            return
        end

        local Camera = workspace.CurrentCamera
        local Opacity = Settings.ESPOpacity or 1

        if Settings.ESPFOVCircle then
            self:UpdateCircle(Opacity)
        else
            Circle.Visible = false
        end

        if not Camera then
            return
        end

        for Index, Target in self:GetTargets() do
            self:UpdatePlayer(Target, Camera, Opacity)
        end
    end

    function ESP:Clear()
        for Index, Data in Cached do
            Data.Box:Remove()
            Data.Outline:Remove()
            Data.Name:Remove()
            Data.Tracer:Remove()
        end

        table.clear(Cached)

        Circle:Remove()
    end

    _ENV.NextESP = ESP

    return ESP
end)

local Aimbot = Module.Aimbot
local ESP = Module.ESP

Connections.Connect(RunService.RenderStepped, function()
    ESP:Update()
end)

Connections.Connect(Players.PlayerRemoving, ESP.RemovePlayer)

Plugins:Window(Queue, {
    "Aimbot + ESP",
    "Made by vita8it"
})

Plugins:Community()

local AimbotTab = Plugins:CreateTab({ "Aimbot", "Automatic aiming" }) do
    AimbotTab:Section("Aimbot", function(Section)
        Plugins:SetDefault("SilentAim", false)
        Plugins:SetDefault("TargetMode", "Nearest")
        Plugins:SetDefault("TargetPart", "HumanoidRootPart")
        Plugins:SetDefault("Distance", 300)
        Plugins:SetDefault("FOV", 100)
        Plugins:SetDefault("CheckWall", true)
        Plugins:SetDefault("CheckTeam", false)
        Plugins:SetDefault("TargetBots", true)

        Plugins:Toggle(Section, {
            "Silent Aim",
            "Redirect bullets to the nearest target"
        }, "SilentAim", function(Value)
            if Value then
                Aimbot:Enable()
            else
                Aimbot:Disable()
            end
        end)

        Plugins:Dropdown(Section, "Target Mode", {
            "Nearest",
            "FOV"
        }, "TargetMode", function(Value)
        end)

        Plugins:Dropdown(Section, "Target Part", {
            "Head",
            "HumanoidRootPart"
        }, "TargetPart", function(Value)
        end)

        Plugins:Slider(Section, {
            "Distance",
            "Maximum distance to acquire the target"
        }, { 50, 400, 10 }, "Distance", function(Value)
        end)

        Plugins:Slider(Section, {
            "FOV",
            "Maximum distance from the crosshair"
        }, { 10, 300, 5 }, "FOV", function(Value)
        end)

        Plugins:Toggle(Section, {
            "Check Wall",
            "Ignore targets behind walls"
        }, "CheckWall", function(Value)
        end)

        Plugins:Toggle(Section, {
            "Check Team",
            "Ignore same team players"
        }, "CheckTeam", function(Value)
        end)

        Plugins:Toggle(Section, {
            "Target Bots",
            "Aim at bots with the IsBot attribute"
        }, "TargetBots", function(Value)
        end)
    end)
end

local ESPTab = Plugins:CreateTab({ "ESP", "See enemies" }) do
    ESPTab:Section("ESP", function(Section)
        Plugins:SetDefault("ESP", false)
        Plugins:SetDefault("ESPBox", true)
        Plugins:SetDefault("ESPName", true)
        Plugins:SetDefault("ESPTracer", true)
        Plugins:SetDefault("ESPBoxOutline", true)
        Plugins:SetDefault("ESPShowDistance", true)
        Plugins:SetDefault("ESPFOVCircle", false)
        Plugins:SetDefault("ESPCheckTeam", false)
        Plugins:SetDefault("ESPColor", "Red")
        Plugins:SetDefault("ESPDistance", 300)
        Plugins:SetDefault("ESPFOV", 100)
        Plugins:SetDefault("ESPOpacity", 1)
        Plugins:SetDefault("ESPNameSize", 13)
        Plugins:SetDefault("ESPTargetBots", true)

        Plugins:Toggle(Section, {
            "ESP",
            "Enable player esp"
        }, "ESP", function(Value)
        end)

        Plugins:Toggle(Section, {
            "Box",
            "Draw a box around the player"
        }, "ESPBox", function(Value)
        end)

        Plugins:Toggle(Section, {
            "Name",
            "Show the player name"
        }, "ESPName", function(Value)
        end)

        Plugins:Toggle(Section, {
            "Tracer",
            "Draw a line from the bottom to the player"
        }, "ESPTracer", function(Value)
        end)

        Plugins:Toggle(Section, {
            "Box Outline",
            "Draw an outline around the box"
        }, "ESPBoxOutline", function(Value)
        end)

        Plugins:Toggle(Section, {
            "Show Distance",
            "Show the distance on the name"
        }, "ESPShowDistance", function(Value)
        end)

        Plugins:Toggle(Section, {
            "FOV Circle",
            "Draw a circle around the crosshair"
        }, "ESPFOVCircle", function(Value)
        end)

        Plugins:Toggle(Section, {
            "Check Team",
            "Only show enemy team players"
        }, "ESPCheckTeam", function(Value)
        end)

        Plugins:Toggle(Section, {
            "Target Bots",
            "Show bots with the IsBot attribute"
        }, "ESPTargetBots", function(Value)
        end)

        Plugins:Dropdown(Section, "Color", {
            "Red",
            "Orange",
            "Yellow",
            "Green",
            "Cyan",
            "Blue",
            "Purple",
            "Pink"
        }, "ESPColor", function(Value)
        end)

        Plugins:Slider(Section, {
            "Distance",
            "Maximum distance to show the player"
        }, { 50, 400, 10 }, "ESPDistance", function(Value)
        end)

        Plugins:Slider(Section, {
            "FOV",
            "Radius of the fov circle"
        }, { 10, 300, 5 }, "ESPFOV", function(Value)
        end)

        Plugins:Slider(Section, {
            "Opacity",
            "Visibility of the drawings"
        }, { 0, 1, 0.05 }, "ESPOpacity", function(Value)
        end)

        Plugins:Slider(Section, {
            "Name Size",
            "Font size of the name"
        }, { 8, 30, 1 }, "ESPNameSize", function(Value)
        end)
    end)
end

Plugins:Managers()
