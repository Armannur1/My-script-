-- 🎯 Piggy Ability Tracker (Mobile Optimized + Collapsible)
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local UIS = game:GetService("UserInputService")

-- 1. Create the GUI
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "AbilityTrackerGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

-- 2. Main Frame (Made smaller for mobile)
local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 260, 0, 320) -- Shrunk from 320x400
MainFrame.Position = UDim2.new(0.05, 0, 0.2, 0)
MainFrame.BackgroundColor3 = Color3.new(0.1, 0.1, 0.1)
MainFrame.BackgroundTransparency = 0.2
MainFrame.BorderSizePixel = 2
MainFrame.BorderColor3 = Color3.new(0.8, 0.2, 0.2)
MainFrame.Active = true
MainFrame.Parent = ScreenGui

-- 3. Title Bar (Dedicated drag handle for mobile)
local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1, 0, 0, 35)
TitleBar.BackgroundTransparency = 1
TitleBar.Parent = MainFrame

-- 4. Title Text
local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -80, 1, 0)
Title.Position = UDim2.new(0, 10, 0, 0)
Title.BackgroundTransparency = 1
Title.Text = "🔪 Ability Tracker"
Title.TextColor3 = Color3.new(1, 0.6, 0.6)
Title.TextScaled = true
Title.Font = Enum.Font.SourceSansBold
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = TitleBar

-- 5. Collapse Button (Fold)
local CollapseBtn = Instance.new("TextButton")
CollapseBtn.Size = UDim2.new(0, 30, 0, 30)
CollapseBtn.Position = UDim2.new(1, -70, 0, 2.5)
CollapseBtn.BackgroundColor3 = Color3.new(0.8, 0.6, 0.1)
CollapseBtn.Text = "▼"
CollapseBtn.TextColor3 = Color3.new(1, 1, 1)
CollapseBtn.TextScaled = true
CollapseBtn.Font = Enum.Font.SourceSansBold
CollapseBtn.Parent = TitleBar

-- 6. Close Button
local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 30, 0, 30)
CloseBtn.Position = UDim2.new(1, -35, 0, 2.5)
CloseBtn.BackgroundColor3 = Color3.new(1, 0, 0)
CloseBtn.Text = "X"
CloseBtn.TextColor3 = Color3.new(1, 1, 1)
CloseBtn.TextScaled = true
CloseBtn.Font = Enum.Font.SourceSansBold
CloseBtn.Parent = TitleBar

-- 7. Player List (Scrollable)
local ScrollFrame = Instance.new("ScrollingFrame")
ScrollFrame.Size = UDim2.new(1, -20, 0, 150) -- Adjusted height
ScrollFrame.Position = UDim2.new(0, 10, 0, 40)
ScrollFrame.BackgroundColor3 = Color3.new(0, 0, 0)
ScrollFrame.BackgroundTransparency = 0.5
ScrollFrame.BorderSizePixel = 0
ScrollFrame.ScrollBarThickness = 5
ScrollFrame.Parent = MainFrame

local UIList = Instance.new("UIListLayout")
UIList.Padding = UDim.new(0, 4)
UIList.SortOrder = Enum.SortOrder.LayoutOrder
UIList.Parent = ScrollFrame

-- 8. Detail Label (Shows abilities of selected player)
local DetailFrame = Instance.new("Frame")
DetailFrame.Size = UDim2.new(1, -20, 0, 110) -- Adjusted height
DetailFrame.Position = UDim2.new(0, 10, 0, 200)
DetailFrame.BackgroundColor3 = Color3.new(0, 0, 0)
DetailFrame.BackgroundTransparency = 0.5
DetailFrame.BorderSizePixel = 0
DetailFrame.Parent = MainFrame

local DetailText = Instance.new("TextLabel")
DetailText.Size = UDim2.new(1, -10, 1, -10)
DetailText.Position = UDim2.new(0, 5, 0, 5)
DetailText.BackgroundTransparency = 1
DetailText.Text = "👆 Click a player's name"
DetailText.TextColor3 = Color3.new(1, 1, 1)
DetailText.TextScaled = true
DetailText.Font = Enum.Font.SourceSans
DetailText.TextWrapped = true
DetailText.TextXAlignment = Enum.TextXAlignment.Left
DetailText.TextYAlignment = Enum.TextYAlignment.Top
DetailText.Parent = DetailFrame

-- 9. Fold / Collapse Logic
local isCollapsed = false
local expandedSize = UDim2.new(0, 260, 0, 320)
local collapsedSize = UDim2.new(0, 260, 0, 35)

CollapseBtn.MouseButton1Click:Connect(function()
    isCollapsed = not isCollapsed
    if isCollapsed then
        MainFrame.Size = collapsedSize
        ScrollFrame.Visible = false
        DetailFrame.Visible = false
        CollapseBtn.Text = "▲" -- Up arrow when collapsed
    else
        MainFrame.Size = expandedSize
        ScrollFrame.Visible = true
        DetailFrame.Visible = true
        CollapseBtn.Text = "▼" -- Down arrow when expanded
    end
end)

CloseBtn.MouseButton1Click:Connect(function()
    ScreenGui:Destroy()
end)

-- 10. Dragging Logic (Attached to TitleBar so you don't drag while scrolling)
local dragging, dragInput, dragStart, startPos
TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = MainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
TitleBar.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)
UIS.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        local delta = input.Position - dragStart
        MainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)

-- 11. Function to read the abilities
local function getAbilities(player)
    local dataFolder = player:FindFirstChild("Data")
    local playerData = dataFolder and dataFolder:FindFirstChild("PlayerData")
    if not playerData then return "⏳ Loading data..." end

    local lines = {}
    
    -- Survivor Abilities
    local survFolder = playerData:FindFirstChild("SurvivorAbilityEquipped")
    if survFolder then
        local survList = {}
        for _, slot in ipairs(survFolder:GetChildren()) do
            if slot:IsA("StringValue") and slot.Value ~= "" and slot.Value ~= "None" then
                table.insert(survList, slot.Value)
            end
        end
        if #survList > 0 then
            table.insert(lines, "🏃 Survivor: " .. table.concat(survList, ", "))
        else
            table.insert(lines, "🏃 Survivor: None")
        end
    else
        table.insert(lines, "🏃 Survivor: No data")
    end

    -- Piggy Abilities
    local piggyFolder = playerData:FindFirstChild("PiggyAbilityEquipped")
    if piggyFolder then
        local piggyList = {}
        for _, slot in ipairs(piggyFolder:GetChildren()) do
            if slot:IsA("StringValue") and slot.Value ~= "" and slot.Value ~= "None" then
                table.insert(piggyList, slot.Value)
            end
        end
        if #piggyList > 0 then
            table.insert(lines, "🐷 Piggy: " .. table.concat(piggyList, ", "))
        else
            table.insert(lines, "🐷 Piggy: None")
        end
    else
        table.insert(lines, "🐷 Piggy: No data")
    end

    return table.concat(lines, "\n")
end

-- 12. Build the list of player buttons
local playerButtons = {}
local function buildList()
    for _, child in ipairs(ScrollFrame:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end
    playerButtons = {}

    for _, player in ipairs(Players:GetPlayers()) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, -5, 0, 28) -- Slightly shorter buttons for mobile
        btn.BackgroundColor3 = Color3.new(0.2, 0.2, 0.2)
        btn.Text = player.Name
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.TextScaled = true
        btn.Font = Enum.Font.SourceSans
        btn.Parent = ScrollFrame
        
        btn.MouseButton1Click:Connect(function()
            DetailText.Text = "🔍 " .. player.Name .. "\n\n" .. getAbilities(player)
        end)
        
        playerButtons[player] = btn
    end
end

-- 13. Background update loop
task.spawn(function()
    buildList()
    while ScreenGui.Parent do
        task.wait(1)
        local currentCount = #Players:GetPlayers()
        local listCount = 0
        for _, c in ipairs(ScrollFrame:GetChildren()) do
            if c:IsA("TextButton") then listCount = listCount + 1 end
        end
        
        if currentCount ~= listCount then
            buildList()
        end
    end
end)
