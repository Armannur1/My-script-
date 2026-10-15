-- Ability & Inventory Tracker (LocalScript) - separate from PiggyESP.
-- Shows, for the player you tap:
--   * equipped Survivor / Piggy abilities  (Players > name > Data > PlayerData)
--   * the tool they are holding            (their character)
--   * their Backpack contents              (Players > name > Backpack)
--
-- Performance design:
--   * No per-frame work. A small loop runs 4x/second ONLY while a player is
--     selected and the panel is open; it stops completely when collapsed/closed.
--   * Watchers are attached only to the selected player's Backpack, Data folders,
--     ability values and character, and are removed while collapsed.
--   * The label is only touched when the text actually changed.
--   * A once-per-second safety refresh means a missed event can never leave
--     stale info on screen.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local TICK = 0.25          -- seconds between checks while a player is selected
local SAFETY_TICKS = 4     -- full refresh every 4 ticks (= 1 second)

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
local conns = {}      -- permanent connections
local selConns = {}   -- CharacterAdded of the selected player
local treeConns = {}  -- Backpack / Data / ability folders / values
local charConns = {}  -- the selected player's character
local rows = {}       -- [Player] = TextButton

local selected = nil
local dirty, rebind, collapsed = false, false, false
local watchedChar, lastHeld, lastText = nil, nil, nil
local loopRunning = false

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

local function markDirty()
	dirty = true
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

-- "Name, Other x2" from the children of a container
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

-- cheap fingerprint of what a player is holding (used to detect equips)
local function heldSignature(player)
	local char = player.Character
	if not char then return "" end
	local names = {}
	for _, c in ipairs(char:GetChildren()) do
		if c:IsA("Tool") then names[#names + 1] = c.Name end
	end
	return table.concat(names, "|")
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

-- Player list
local list = Instance.new("ScrollingFrame")
list.Position = UDim2.fromOffset(8, 0)
list.Size = UDim2.new(1, -16, 0.38, 0)
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

-- Detail
local detailFrame = Instance.new("ScrollingFrame")
detailFrame.Position = UDim2.new(0, 8, 0.38, 6)
detailFrame.Size = UDim2.new(1, -16, 0.62, -14)
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
-- Drag: follows ONLY the finger/pointer that started on the title bar
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
-- Watchers for the selected player (narrow: only the known locations)
--------------------------------------------------------------------
local function bindTree(player)
	disconnectList(treeConns)

	local function add(signal, fn)
		treeConns[#treeConns + 1] = signal:Connect(fn)
	end
	-- container changed -> re-attach watchers (a new Backpack/Data may have appeared)
	local function structural()
		dirty = true
		rebind = true
	end

	add(player.ChildAdded, structural)
	add(player.ChildRemoved, structural)

	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		add(backpack.ChildAdded, markDirty)
		add(backpack.ChildRemoved, markDirty)
	end

	local data = player:FindFirstChild("Data")
	if data then
		add(data.ChildAdded, structural)
		add(data.ChildRemoved, structural)
	end

	local pd = getPlayerData(player)
	if pd then
		add(pd.ChildAdded, structural)
		add(pd.ChildRemoved, structural)
		for _, def in ipairs(ABILITY_FOLDERS) do
			local folder = pd:FindFirstChild(def.key)
			if folder then
				add(folder.ChildAdded, structural)
				add(folder.ChildRemoved, structural)
				for _, v in ipairs(folder:GetChildren()) do
					if v:IsA("StringValue") then add(v.Changed, markDirty) end
				end
			end
		end
	end
end

local function watchCharacter(char)
	disconnectList(charConns)
	watchedChar = char
	if not char then return end
	charConns[#charConns + 1] = char.ChildAdded:Connect(markDirty)   -- tool equipped
	charConns[#charConns + 1] = char.ChildRemoved:Connect(markDirty) -- tool unequipped
end

local function stopWatching()
	disconnectList(selConns)
	disconnectList(treeConns)
	disconnectList(charConns)
	watchedChar = nil
end

local function startWatching(player)
	local ok, err = pcall(bindTree, player)
	if not ok then warn("[AbilityTracker] " .. tostring(err)) end
	watchCharacter(player.Character)
	selConns[#selConns + 1] = player.CharacterAdded:Connect(function(c)
		watchCharacter(c)
		dirty = true
	end)
end

--------------------------------------------------------------------
-- Rendering and the update loop
--------------------------------------------------------------------
-- Errors are caught so a bad read can never leave the old player's text on screen.
local function render()
	if not selected then return end
	local ok, result = pcall(buildText, selected)
	if not ok then
		warn("[AbilityTracker] " .. tostring(result))
		result = "<b>" .. esc(selected.Name) .. "</b>\n\nCould not read this player's data."
	end
	if result ~= lastText then -- only touch the label when something changed
		lastText = result
		detail.Text = result
	end
end

local safety = 0
local function tickUpdate()
	local p = selected
	if not p then return end

	safety += 1
	if safety >= SAFETY_TICKS then
		safety = 0
		dirty = true -- full refresh once a second
	end

	-- character was replaced (respawn, skin swap): attach to the new one
	if p.Character ~= watchedChar then
		watchCharacter(p.Character)
		dirty = true
	end

	if rebind then
		rebind = false
		local ok, err = pcall(bindTree, p)
		if not ok then warn("[AbilityTracker] " .. tostring(err)) end
		dirty = true
	end

	-- what they hold is checked directly, so equips can never be missed
	local sig = heldSignature(p)
	if sig ~= lastHeld then
		lastHeld = sig
		dirty = true
	end

	if dirty then
		dirty = false
		render()
	end
end

-- The loop only exists while a player is selected and the panel is open.
local function startLoop()
	if loopRunning then return end
	loopRunning = true
	task.spawn(function()
		while selected and not collapsed and gui.Parent do
			task.wait(TICK)
			if selected and not collapsed then tickUpdate() end
		end
		loopRunning = false
	end)
end

local function selectPlayer(p)
	selected = p
	for pl, b in pairs(rows) do
		b.BackgroundColor3 = (pl == p) and SELECT_COLOR or ROW_COLOR
	end
	stopWatching()
	lastHeld, lastText = nil, nil
	dirty, rebind, safety = false, false, 0
	if not p then
		detail.Text = HINT
		return
	end
	startWatching(p)
	render() -- show the new player immediately
	startLoop()
end

--------------------------------------------------------------------
-- Player list (built once, then only touched when players join/leave)
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
-- Collapse / close
--------------------------------------------------------------------
local function setCollapsed(v)
	collapsed = v
	body.Visible = not v
	panel.Size = UDim2.fromOffset(PANEL_W, v and TITLE_H or PANEL_H)
	collapseBtn.Text = v and "+" or "-"
	if v then
		stopWatching() -- zero activity while folded
	elseif selected then
		startWatching(selected)
		lastHeld, lastText = nil, nil
		render()
		startLoop()
	end
end
collapseBtn.MouseButton1Click:Connect(function() setCollapsed(not collapsed) end)

local function cleanup()
	selected = nil
	for _, c in ipairs(conns) do c:Disconnect() end
	stopWatching()
	gui:Destroy()
	if _G.AbilityTrackerCleanup == cleanup then _G.AbilityTrackerCleanup = nil end
end
closeBtn.MouseButton1Click:Connect(cleanup)
_G.AbilityTrackerCleanup = cleanup

--------------------------------------------------------------------
-- LovestruckTrap tester (client-side only; server may reject/revert changes)
--------------------------------------------------------------------
local trapEnabled = false
local targetY = -500
local trapRef = nil
local trapStatus = nil
local trapToggle = nil
local trapYBox = nil
local trapApply = nil
local trapScanConnection = nil
local trapStatusText = nil

local function isAllowedFolderName(name)
	return name == "ItemFolder" or name == "ItemFolder1" or name:match("^%d+$") ~= nil
end

local function findLovestruckTrap()
	-- Search only under qualifying folders, wherever they occur beneath Workspace.
	for _, inst in ipairs(workspace:GetDescendants()) do
		if inst.Name == "LovestruckTrap" then
			local ancestor = inst.Parent
			while ancestor and ancestor ~= workspace do
				if isAllowedFolderName(ancestor.Name) then
					local root = inst:FindFirstChild("HumanoidRootPart", true)
					if root and root:IsA("BasePart") then
						return inst, root
					end
					break
				end
				ancestor = ancestor.Parent
			end
		end
	end
	return nil, nil
end

local trapPanel = Instance.new("Frame")
trapPanel.Name = "LovestruckTrapTester"
trapPanel.Size = UDim2.fromOffset(260, 176)
trapPanel.Position = UDim2.fromOffset(304, 60)
trapPanel.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
trapPanel.BackgroundTransparency = 0.04
trapPanel.Active = true
trapPanel.Parent = gui
round(trapPanel, 10)
local trapStroke = Instance.new("UIStroke")
trapStroke.Color = Color3.fromRGB(70, 70, 90)
trapStroke.Thickness = 1
trapStroke.Parent = trapPanel

local trapHeader = Instance.new("Frame")
trapHeader.Size = UDim2.new(1, 0, 0, 34)
trapHeader.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
trapHeader.Active = true
trapHeader.Parent = trapPanel
round(trapHeader, 10)

local trapTitle = Instance.new("TextLabel")
trapTitle.Size = UDim2.new(1, -12, 1, 0)
trapTitle.Position = UDim2.fromOffset(10, 0)
trapTitle.BackgroundTransparency = 1
trapTitle.Font = Enum.Font.GothamBold
trapTitle.TextSize = 14
trapTitle.TextColor3 = Color3.new(1, 1, 1)
trapTitle.TextXAlignment = Enum.TextXAlignment.Left
trapTitle.Text = "LovestruckTrap Tester"
trapTitle.Parent = trapHeader

local trapStatusTextLabel = Instance.new("TextLabel")
trapStatusTextLabel.Name = "TrapStatus"
trapStatusTextLabel.Position = UDim2.fromOffset(10, 42)
trapStatusTextLabel.Size = UDim2.new(1, -20, 0, 38)
trapStatusTextLabel.BackgroundTransparency = 1
trapStatusTextLabel.Font = Enum.Font.Gotham
trapStatusTextLabel.TextSize = 12
trapStatusTextLabel.TextColor3 = Color3.fromRGB(220, 220, 230)
trapStatusTextLabel.TextXAlignment = Enum.TextXAlignment.Left
trapStatusTextLabel.TextYAlignment = Enum.TextYAlignment.Top
trapStatusTextLabel.TextWrapped = true
trapStatusTextLabel.Text = "Searching for LovestruckTrap..."
trapStatusTextLabel.Parent = trapPanel
trapStatusText = trapStatusTextLabel

local yLabel = Instance.new("TextLabel")
yLabel.Position = UDim2.fromOffset(10, 83)
yLabel.Size = UDim2.fromOffset(68, 30)
yLabel.BackgroundTransparency = 1
yLabel.Font = Enum.Font.GothamMedium
yLabel.TextSize = 13
yLabel.TextColor3 = Color3.new(1, 1, 1)
yLabel.Text = "Target Y:"
yLabel.Parent = trapPanel

trapYBox = Instance.new("TextBox")
trapYBox.Name = "TargetY"
trapYBox.Position = UDim2.fromOffset(78, 83)
trapYBox.Size = UDim2.fromOffset(70, 30)
trapYBox.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
trapYBox.TextColor3 = Color3.new(1, 1, 1)
trapYBox.PlaceholderText = "-500"
trapYBox.Text = "-500"
trapYBox.ClearTextOnFocus = false
trapYBox.Font = Enum.Font.Gotham
trapYBox.TextSize = 13
trapYBox.Parent = trapPanel
round(trapYBox, 7)

trapToggle = newButton(trapPanel, "Enable: OFF", UDim2.fromOffset(92, 30), Color3.fromRGB(75, 75, 92))
trapToggle.Position = UDim2.fromOffset(156, 83)
trapToggle.TextSize = 12

trapApply = newButton(trapPanel, "Apply Y Position", UDim2.new(1, -20, 0, 32), Color3.fromRGB(70, 110, 200))
trapApply.Position = UDim2.fromOffset(10, 128)
trapApply.TextSize = 13

local function refreshTrapReference()
	local model, root = findLovestruckTrap()
	trapRef = model
	trapStatus = root
	if root then
		trapStatusText.Text = "Found LovestruckTrap • HRP ready"
	else
		trapStatusText.Text = "Trap not found in a supported folder."
	end
end

local function getTargetY()
	local value = tonumber(trapYBox.Text)
	if not value or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return math.clamp(value, -100000, 100000)
end

trapYBox.FocusLost:Connect(function()
	local value = getTargetY()
	if value then
		targetY = value
		trapYBox.Text = tostring(value)
	else
		trapYBox.Text = tostring(targetY)
	end
end)

trapToggle.MouseButton1Click:Connect(function()
	trapEnabled = not trapEnabled
	trapToggle.Text = trapEnabled and "Enable: ON" or "Enable: OFF"
	trapToggle.BackgroundColor3 = trapEnabled and Color3.fromRGB(45, 145, 85) or Color3.fromRGB(75, 75, 92)
	if trapEnabled then
		refreshTrapReference()
		if trapStatus then
			trapStatusText.Text = "Enabled • move only when nearby"
		end
	else
		trapStatusText.Text = trapStatus and "Found LovestruckTrap • disabled" or "Trap not found in a supported folder."
	end
end)

trapApply.MouseButton1Click:Connect(function()
	local value = getTargetY()
	if not value then
		trapStatusText.Text = "Enter a valid numeric Y coordinate."
		return
	end
	targetY = value
	trapYBox.Text = tostring(value)
	refreshTrapReference()
	if not trapEnabled then
		trapStatusText.Text = "Turn Enable ON first."
		return
	end
	if not trapStatus or not trapStatus.Parent then
		trapStatusText.Text = "Trap HRP not found."
		return
	end
	local character = LocalPlayer.Character
	local playerRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not playerRoot then
		trapStatusText.Text = "Your character HRP is unavailable."
		return
	end
	local distance = (playerRoot.Position - trapStatus.Position).Magnitude
	if distance > 35 then
		trapStatusText.Text = string.format("Too far away (%.0f studs). Get within 35 studs.", distance)
		return
	end
	-- Client-side attempt only. Network ownership/server rules may reject or undo this.
	local ok, err = pcall(function()
		local old = trapStatus.CFrame
		trapStatus.CFrame = CFrame.new(old.Position.X, targetY, old.Position.Z) * (old - old.Position)
	end)
	if ok then
		trapStatusText.Text = "Local CFrame change attempted. Server may revert it."
	else
		trapStatusText.Text = "Move failed: " .. tostring(err)
	end
end)

-- Lightweight polling while enabled; avoids a per-frame scan.
task.spawn(function()
	local lastRoot = nil
	while gui.Parent do
		task.wait(0.5)
		if trapEnabled then
			if not trapStatus or not trapStatus.Parent then
				refreshTrapReference()
			end
			local character = LocalPlayer.Character
			local playerRoot = character and character:FindFirstChild("HumanoidRootPart")
			if trapStatus and playerRoot then
				local distance = (playerRoot.Position - trapStatus.Position).Magnitude
				if distance > 35 then
					trapStatusText.Text = string.format("Found trap • %.0f studs away", distance)
				elseif distance <= 35 then
					trapStatusText.Text = string.format("Nearby • %.0f studs • press Apply", distance)
				end
			end
		end
	end
end)

-- Make the added panel draggable by its title bar.
do
	local activeInput, startInputPos, startPos
	trapHeader.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			activeInput = input
			startInputPos = Vector2.new(input.Position.X, input.Position.Y)
			startPos = trapPanel.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not activeInput then return end
		local matches = input == activeInput or (activeInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)
		if not matches then return end
		local delta = Vector2.new(input.Position.X, input.Position.Y) - startInputPos
		local screen = gui.AbsoluteSize
		local size = trapPanel.AbsoluteSize
		trapPanel.Position = UDim2.fromOffset(
			math.clamp(startPos.X.Offset + delta.X, 0, math.max(0, screen.X - size.X)),
			math.clamp(startPos.Y.Offset + delta.Y, 0, math.max(0, screen.Y - size.Y))
		)
	end)
	UserInputService.InputEnded:Connect(function(input)
		if activeInput and (input == activeInput or (activeInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1)) then
			activeInput = nil
		end
	end)
end

refreshTrapReference()

gui.Parent = playerGui