-- Ability & Inventory Tracker (LocalScript) - separate from PiggyESP.
-- Shows, for the player you tap:
--   * equipped Survivor / Piggy abilities  (Players > name > Data > PlayerData)
--   * the tool they are holding            (their character)
--   * their Backpack contents              (Players > name > Backpack)
-- Event driven: nothing runs unless a player is selected, the panel is open and
-- something actually changed (checked at most 4 times a second).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local UPDATE_INTERVAL = 0.25 -- seconds between detail refreshes (max)

local ABILITY_FOLDERS = {
	{ key = "SurvivorAbilityEquipped", label = "Survivor", color = "#7CE08A" },
	{ key = "PiggyAbilityEquipped",    label = "Piggy",    color = "#FF8A8A" },
}
local HELD_COLOR = "#FFD866"
local BACKPACK_COLOR = "#8FB8FF"

local ROW_COLOR = Color3.fromRGB(45, 45, 58)
local SELECT_COLOR = Color3.fromRGB(70, 110, 200)
local HINT = "Tap a player to see their abilities and inventory."

--------------------------------------------------------------------
-- Re-run safety: clean up a previous copy of this script
--------------------------------------------------------------------
if _G.AbilityTrackerCleanup then pcall(_G.AbilityTrackerCleanup) end

local playerGui = LocalPlayer:WaitForChild("PlayerGui")
local old = playerGui:FindFirstChild("AbilityTrackerGui")
if old then old:Destroy() end

--------------------------------------------------------------------
-- State
--------------------------------------------------------------------
local conns = {}       -- permanent connections
local structConns = {} -- watching the selected player's tree
local valueConns = {}  -- .Changed on the selected player's ability values
local charConns = {}   -- watching the selected player's character
local rows = {}        -- [Player] = TextButton
local selected, dirty, rebind, collapsed = nil, false, false, false

local function keep(c)
	conns[#conns + 1] = c
	return c
end

local function disconnectList(list)
	for i = #list, 1, -1 do
		list[i]:Disconnect()
		list[i] = nil
	end
end

--------------------------------------------------------------------
-- Reading data
--------------------------------------------------------------------
local function esc(s)
	return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function getPlayerData(player)
	local data = player:FindFirstChild("Data")
	return data and data:FindFirstChild("PlayerData")
end

local function listValues(folder)
	local items = {}
	for _, v in ipairs(folder:GetChildren()) do
		if v:IsA("StringValue") and v.Value ~= "" and v.Value ~= "None" then
			items[#items + 1] = esc(v.Value)
		end
	end
	return items
end

local function countedNames(container, toolsOnly)
	local counts, order = {}, {}
	for _, child in ipairs(container:GetChildren()) do
		local ok
		if toolsOnly then
			ok = child:IsA("Tool")
		else
			ok = not child:IsA("LuaSourceContainer")
		end
		if ok then
			local n = child.Name
			if not counts[n] then
				counts[n] = 0
				order[#order + 1] = n
			end
			counts[n] += 1
		end
	end
	if #order == 0 then return "None" end
	local parts = {}
	for i, n in ipairs(order) do
		parts[i] = counts[n] > 1 and (esc(n) .. " x" .. counts[n]) or esc(n)
	end
	return table.concat(parts, ", ")
end

local function section(label, color, text)
	return string.format('<font color="%s"><b>%s</b></font>  %s', color, label, text)
end

local function buildText(player)
	local lines = { string.format("<b>%s</b>", esc(player.Name)), "" }

	local pd = getPlayerData(player)
	if not pd then
		lines[#lines + 1] = "<i>Loading data...</i>"
	else
		for _, def in ipairs(ABILITY_FOLDERS) do
			local folder = pd:FindFirstChild(def.key)
			local text
			if folder then
				local items = listValues(folder)
				text = #items > 0 and table.concat(items, ", ") or "None"
			else
				text = "No data"
			end
			lines[#lines + 1] = section(def.label, def.color, text)
		end
	end

	lines[#lines + 1] = ""
	local char = player.Character
	lines[#lines + 1] = section("Holding", HELD_COLOR, char and countedNames(char, true) or "None")

	local backpack = player:FindFirstChild("Backpack")
	lines[#lines + 1] = section("Backpack", BACKPACK_COLOR, backpack and countedNames(backpack, false) or "Not visible")

	return table.concat(lines, "\n")
end

--------------------------------------------------------------------
-- Trap Dropper (LovestruckTrap)
--------------------------------------------------------------------
local TRAP_NAME = "LovestruckTrap"

local TrapDropper = {
	enabled = false,
	targetY = -500,
	traps = {},
	scanAcc = 0,
	moveAcc = 0,
	found = 0,
	owned = 0,
	SCAN_INTERVAL = 1.0,      -- rescan every 1s
	MOVE_INTERVAL = 1 / 10,   -- try to move 10x per second
}

-- Full descendant scan: robust to any folder nesting ("ItemFolder",
-- "ItemFolder1", numeric folders, sub-folders, whatever).
local function scanTraps()
	local found = {}
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("Model") and d.Name == TRAP_NAME then
			found[#found + 1] = d
		end
	end
	return found
end

local function getTrapRoot(trap)
	local root = trap:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		if trap.PrimaryPart ~= root then trap.PrimaryPart = root end
		return root
	end
	root = trap.PrimaryPart
	if root and root:IsA("BasePart") and root.Parent then return root end
	root = trap:FindFirstChildWhichIsA("BasePart")
	if root then trap.PrimaryPart = root; return root end
	return nil
end

-- Unanchor + calm the rig so we can teleport it cleanly.
-- We do NOT touch CanCollide: unanchored parts at -500 have no floor anyway.
local function prepTrap(trap)
	for _, d in ipairs(trap:GetDescendants()) do
		if d:IsA("BasePart") then
			pcall(function() d.Anchored = false end)
		end
	end
	local hum = trap:FindFirstChildOfClass("Humanoid")
	if hum then
		pcall(function() hum.PlatformStand = true end)
	end
	if not trap.PrimaryPart then getTrapRoot(trap) end
end

-- Pure teleport. No velocity, no physics. Trap lands exactly on targetY
-- and stays there. One CFrame write per move, so it's basically free.
local function dropToY(trap, root, targetY)
	-- Already there? Do nothing.
	if math.abs(root.Position.Y - targetY) < 1 then return end

	-- Kill any residual physics so the trap can't drift after we place it.
	pcall(function()
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end)

	-- Single teleport: keep X, Z and rotation; only Y changes.
	local p = root.Position
	local r = root.CFrame - p
	root.CFrame = CFrame.new(p.X, targetY, p.Z) * r
end

local function updateTraps(dt)
	local td = TrapDropper
	td.scanAcc += dt
	td.moveAcc += dt

	-- Periodic scan (cheap at 1 Hz, never misses nested folders)
	if td.scanAcc >= td.SCAN_INTERVAL then
		td.scanAcc = 0
		td.traps = scanTraps()
		td.found = #td.traps
		for _, trap in ipairs(td.traps) do
			prepTrap(trap)
		end
	end

	if td.moveAcc < td.MOVE_INTERVAL then return end
	td.moveAcc = 0

	local targetY = td.targetY
	local ownedCount = 0
	for i = #td.traps, 1, -1 do
		local trap = td.traps[i]
		if not trap.Parent then
			table.remove(td.traps, i)
			td.found = #td.traps
		else
			local root = getTrapRoot(trap)
			if root then
				-- Try to own it (only succeeds when you're near)
				local owner = root:GetNetworkOwner()
				if owner ~= LocalPlayer then
					pcall(function() root:SetNetworkOwner(LocalPlayer) end)
					owner = root:GetNetworkOwner()
				end

				-- Only move what we actually control -> no rubberband flicker
				if owner == LocalPlayer then
					ownedCount += 1
					dropToY(trap, root, targetY)
				end
			end
		end
	end
	td.owned = ownedCount
end

--------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "AbilityTrackerGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 998
gui.IgnoreGuiInset = true

local function round(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 8)
	c.Parent = inst
end

local function newButton(parent, text, size, bg)
	local b = Instance.new("TextButton")
	b.Size = size
	b.AutoButtonColor = false
	b.BackgroundColor3 = bg
	b.Font = Enum.Font.GothamBold
	b.TextSize = 14
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Text = text
	b.Parent = parent
	round(b, 7)
	return b
end

local cam = workspace.CurrentCamera
local viewport = cam and cam.ViewportSize or Vector2.new(800, 400)
local PANEL_W = 280
local PANEL_H = math.min(360, viewport.Y - 24)
local TITLE_H = 34
local CONTROLS_H = 76

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
panel.Position = UDim2.fromOffset(12, 60)
panel.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
panel.BackgroundTransparency = 0.04
panel.Active = true
panel.Parent = gui
round(panel, 10)
local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(70, 70, 90)
stroke.Thickness = 1
stroke.Parent = panel

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, TITLE_H)
titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
titleBar.Active = true
titleBar.Parent = panel
round(titleBar, 10)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -84, 1, 0)
title.Position = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextColor3 = Color3.new(1, 1, 1)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "Abilities & Inventory"
title.Parent = titleBar

local collapseBtn = newButton(titleBar, "-", UDim2.fromOffset(30, 26), Color3.fromRGB(200, 150, 30))
collapseBtn.AnchorPoint = Vector2.new(1, 0.5)
collapseBtn.Position = UDim2.new(1, -40, 0.5, 0)
collapseBtn.TextSize = 18

local closeBtn = newButton(titleBar, "X", UDim2.fromOffset(30, 26), Color3.fromRGB(190, 50, 50))
closeBtn.AnchorPoint = Vector2.new(1, 0.5)
closeBtn.Position = UDim2.new(1, -6, 0.5, 0)

local body = Instance.new("Frame")
body.Size = UDim2.new(1, 0, 1, -(TITLE_H + 4))
body.Position = UDim2.fromOffset(0, TITLE_H + 4)
body.BackgroundTransparency = 1
body.Parent = panel

-- Player list (fixed height so the trap controls at the bottom always fit)
local LIST_H = 100
local list = Instance.new("ScrollingFrame")
list.Position = UDim2.fromOffset(8, 0)
list.Size = UDim2.new(1, -16, 0, LIST_H)
list.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
list.BackgroundTransparency = 0.3
list.BorderSizePixel = 0
list.ScrollBarThickness = 4
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.CanvasSize = UDim2.new()
list.Parent = body
round(list, 8)
local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 3)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = list
local listPad = Instance.new("UIPadding")
listPad.PaddingLeft, listPad.PaddingRight = UDim.new(0, 4), UDim.new(0, 8)
listPad.PaddingTop, listPad.PaddingBottom = UDim.new(0, 4), UDim.new(0, 4)
listPad.Parent = list

-- Detail (fills space between list and trap controls)
local DETAIL_TOP = LIST_H + 6
local detailFrame = Instance.new("ScrollingFrame")
detailFrame.Position = UDim2.fromOffset(8, DETAIL_TOP)
detailFrame.Size = UDim2.new(1, -16, 1, -(DETAIL_TOP + CONTROLS_H + 6))
detailFrame.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
detailFrame.BackgroundTransparency = 0.3
detailFrame.BorderSizePixel = 0
detailFrame.ScrollBarThickness = 4
detailFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
detailFrame.CanvasSize = UDim2.new()
detailFrame.Parent = body
round(detailFrame, 8)
local detailPad = Instance.new("UIPadding")
detailPad.PaddingLeft, detailPad.PaddingRight = UDim.new(0, 8), UDim.new(0, 8)
detailPad.PaddingTop, detailPad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
detailPad.Parent = detailFrame

local detail = Instance.new("TextLabel")
detail.Size = UDim2.new(1, 0, 0, 0)
detail.AutomaticSize = Enum.AutomaticSize.Y
detail.BackgroundTransparency = 1
detail.Font = Enum.Font.GothamMedium
detail.TextSize = 14
detail.TextColor3 = Color3.new(1, 1, 1)
detail.TextXAlignment = Enum.TextXAlignment.Left
detail.TextYAlignment = Enum.TextYAlignment.Top
detail.TextWrapped = true
detail.RichText = true
detail.Text = HINT
detail.Parent = detailFrame

--------------------------------------------------------------------
-- Trap controls (bottom of body)
--------------------------------------------------------------------
local controls = Instance.new("Frame")
controls.Name = "TrapControls"
controls.AnchorPoint = Vector2.new(0, 1)
controls.Position = UDim2.new(0, 8, 1, -4)
controls.Size = UDim2.new(1, -16, 0, CONTROLS_H)
controls.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
controls.BackgroundTransparency = 0.3
controls.BorderSizePixel = 0
controls.Parent = body
round(controls, 8)

local dropLabel = Instance.new("TextLabel")
dropLabel.Size = UDim2.new(1, -80, 0, 22)
dropLabel.Position = UDim2.fromOffset(8, 4)
dropLabel.BackgroundTransparency = 1
dropLabel.Font = Enum.Font.GothamBold
dropLabel.TextSize = 13
dropLabel.TextColor3 = Color3.new(1, 1, 1)
dropLabel.TextXAlignment = Enum.TextXAlignment.Left
dropLabel.Text = "Drop Lovestruck Traps"
dropLabel.Parent = controls

local dropToggle = newButton(controls, "OFF", UDim2.fromOffset(64, 22), Color3.fromRGB(80, 80, 90))
dropToggle.AnchorPoint = Vector2.new(1, 0)
dropToggle.Position = UDim2.new(1, -8, 0, 4)
dropToggle.TextSize = 12

local yLabel = Instance.new("TextLabel")
yLabel.Size = UDim2.fromOffset(70, 24)
yLabel.Position = UDim2.fromOffset(8, 28)
yLabel.BackgroundTransparency = 1
yLabel.Font = Enum.Font.GothamBold
yLabel.TextSize = 13
yLabel.TextColor3 = Color3.new(1, 1, 1)
yLabel.TextXAlignment = Enum.TextXAlignment.Left
yLabel.Text = "Target Y:"
yLabel.Parent = controls

local yInput = Instance.new("TextBox")
yInput.Size = UDim2.new(1, -86, 0, 24)
yInput.Position = UDim2.fromOffset(76, 28)
yInput.BackgroundColor3 = Color3.fromRGB(30, 30, 42)
yInput.BorderSizePixel = 0
yInput.Font = Enum.Font.GothamMedium
yInput.TextSize = 13
yInput.TextColor3 = Color3.new(1, 1, 1)
yInput.PlaceholderText = "-500"
yInput.Text = "-500"
yInput.ClearTextOnFocus = false
yInput.TextXAlignment = Enum.TextXAlignment.Left
yInput.Parent = controls
round(yInput, 6)
local yPad = Instance.new("UIPadding")
yPad.PaddingLeft = UDim.new(0, 6)
yPad.Parent = yInput

yInput.FocusLost:Connect(function()
	local n = tonumber(yInput.Text)
	if n then
		TrapDropper.targetY = n
		yInput.Text = tostring(n)
	else
		yInput.Text = tostring(TrapDropper.targetY)
	end
end)

-- Status line
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 14)
status.Position = UDim2.fromOffset(8, 56)
status.BackgroundTransparency = 1
status.Font = Enum.Font.GothamMedium
status.TextSize = 11
status.TextColor3 = Color3.fromRGB(170, 170, 190)
status.TextXAlignment = Enum.TextXAlignment.Left
status.Text = "Idle."
status.Parent = controls

dropToggle.MouseButton1Click:Connect(function()
	TrapDropper.enabled = not TrapDropper.enabled
	if TrapDropper.enabled then
		dropToggle.Text = "ON"
		dropToggle.BackgroundColor3 = Color3.fromRGB(80, 180, 100)
		TrapDropper.traps = scanTraps()
		TrapDropper.found = #TrapDropper.traps
		for _, t in ipairs(TrapDropper.traps) do prepTrap(t) end
		TrapDropper.scanAcc = 0
		TrapDropper.moveAcc = 0
	else
		dropToggle.Text = "OFF"
		dropToggle.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
		status.Text = "Idle."
	end
end)

--------------------------------------------------------------------
-- Drag
--------------------------------------------------------------------
do
	local MOUSE = Enum.UserInputType.MouseButton1
	local TOUCH = Enum.UserInputType.Touch
	local activeInput, startInputPos, startPos, moved

	keep(titleBar.InputBegan:Connect(function(input)
		if activeInput then return end
		if input.UserInputType == TOUCH or input.UserInputType == MOUSE then
			activeInput = input
			startInputPos = Vector2.new(input.Position.X, input.Position.Y)
			startPos = panel.Position
			moved = false
		end
	end))

	keep(UserInputService.InputChanged:Connect(function(input)
		if not activeInput then return end
		local match = (input == activeInput)
			or (activeInput.UserInputType == MOUSE and input.UserInputType == Enum.UserInputType.MouseMovement)
		if not match then return end
		local delta = Vector2.new(input.Position.X, input.Position.Y) - startInputPos
		if not moved and delta.Magnitude < 8 then return end
		moved = true
		local screen = gui.AbsoluteSize
		local size = panel.AbsoluteSize
		local x = math.clamp(startPos.X.Offset + delta.X, 0, math.max(0, screen.X - size.X))
		local y = math.clamp(startPos.Y.Offset + delta.Y, 0, math.max(0, screen.Y - size.Y))
		panel.Position = UDim2.fromOffset(x, y)
	end))

	keep(UserInputService.InputEnded:Connect(function(input)
		if not activeInput then return end
		local match = (input == activeInput)
			or (activeInput.UserInputType == MOUSE and input.UserInputType == MOUSE)
		if match then activeInput = nil end
	end))
end

--------------------------------------------------------------------
-- Watching the selected player
--------------------------------------------------------------------
local function markDirty()
	dirty = true
end

local function bindValues(player)
	disconnectList(valueConns)
	local pd = getPlayerData(player)
	if not pd then return end
	for _, def in ipairs(ABILITY_FOLDERS) do
		local folder = pd:FindFirstChild(def.key)
		if folder then
			for _, v in ipairs(folder:GetChildren()) do
				if v:IsA("StringValue") then
					valueConns[#valueConns + 1] = v.Changed:Connect(markDirty)
				end
			end
		end
	end
end

local function watchCharacter(char)
	disconnectList(charConns)
	if not char then return end
	charConns[#charConns + 1] = char.ChildAdded:Connect(markDirty)
	charConns[#charConns + 1] = char.ChildRemoved:Connect(markDirty)
end

local function watch(player)
	local function structural()
		dirty = true
		rebind = true
	end
	structConns[#structConns + 1] = player.DescendantAdded:Connect(structural)
	structConns[#structConns + 1] = player.DescendantRemoved:Connect(structural)
	structConns[#structConns + 1] = player.CharacterAdded:Connect(function(c)
		watchCharacter(c)
		dirty = true
	end)
	watchCharacter(player.Character)
end

local acc = UPDATE_INTERVAL

local function render()
	if not selected then return end
	local ok, result = pcall(buildText, selected)
	if ok then
		detail.Text = result
	else
		detail.Text = "<b>" .. esc(selected.Name) .. "</b>\n\nCould not read this player's data."
		warn("[AbilityTracker] " .. tostring(result))
	end
end

local function selectPlayer(p)
	selected = p
	for pl, b in pairs(rows) do
		b.BackgroundColor3 = (pl == p) and SELECT_COLOR or ROW_COLOR
	end
	disconnectList(structConns)
	disconnectList(valueConns)
	disconnectList(charConns)
	if not p then
		detail.Text = HINT
		return
	end
	dirty, rebind = false, false
	pcall(bindValues, p)
	render()
	local ok, err = pcall(watch, p)
	if not ok then warn("[AbilityTracker] " .. tostring(err)) end
end

--------------------------------------------------------------------
-- Player list
--------------------------------------------------------------------
local function reorder()
	local all = Players:GetPlayers()
	table.sort(all, function(a, b) return a.Name:lower() < b.Name:lower() end)
	for i, p in ipairs(all) do
		local b = rows[p]
		if b then b.LayoutOrder = i end
	end
end

local function addPlayer(p)
	if rows[p] then return end
	local b = newButton(list, p == LocalPlayer and (p.Name .. " (you)") or p.Name,
		UDim2.new(1, 0, 0, 30), ROW_COLOR)
	b.TextTruncate = Enum.TextTruncate.AtEnd
	b.TextXAlignment = Enum.TextXAlignment.Left
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.Parent = b
	b.MouseButton1Click:Connect(function() selectPlayer(p) end)
	rows[p] = b
	reorder()
end

local function removePlayer(p)
	local b = rows[p]
	if b then
		b:Destroy()
		rows[p] = nil
	end
	if selected == p then selectPlayer(nil) end
end

for _, p in ipairs(Players:GetPlayers()) do addPlayer(p) end
keep(Players.PlayerAdded:Connect(addPlayer))
keep(Players.PlayerRemoving:Connect(removePlayer))

--------------------------------------------------------------------
-- Refresh loop
--------------------------------------------------------------------
local statusAcc = 0
keep(RunService.Heartbeat:Connect(function(dt)
	if TrapDropper.enabled then
		updateTraps(dt)
		statusAcc += dt
		if statusAcc >= 0.5 then
			statusAcc = 0
			status.Text = string.format("Found: %d   |   Owned: %d", TrapDropper.found, TrapDropper.owned)
		end
	end

	if not dirty then return end
	acc += dt
	if acc < UPDATE_INTERVAL then return end
	if not selected or collapsed then return end
	acc = 0
	dirty = false
	if rebind then
		rebind = false
		pcall(bindValues, selected)
	end
	render()
end))

--------------------------------------------------------------------
-- Collapse / close
--------------------------------------------------------------------
local function setCollapsed(v)
	collapsed = v
	body.Visible = not v
	panel.Size = UDim2.fromOffset(PANEL_W, v and TITLE_H or PANEL_H)
	collapseBtn.Text = v and "+" or "-"
	if not v then dirty = true end
end
collapseBtn.MouseButton1Click:Connect(function() setCollapsed(not collapsed) end)

local function cleanup()
	for _, c in ipairs(conns) do c:Disconnect() end
	disconnectList(structConns)
	disconnectList(valueConns)
	disconnectList(charConns)
	gui:Destroy()
	if _G.AbilityTrackerCleanup == cleanup then _G.AbilityTrackerCleanup = nil end
end
closeBtn.MouseButton1Click:Connect(cleanup)
_G.AbilityTrackerCleanup = cleanup

gui.Parent = playerGui
