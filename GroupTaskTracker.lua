--[[
    GroupTaskTracker.lua
    Task progress tracker for EQ group members using DanNet

    Usage: /lua run GroupTaskTracker
    Commands:
        /gqt - Toggle UI window
        /gqtstop - Stop the script
        /gqtrefresh - Refresh task data
        /gqtcleanup - Clear all DanNet observers
]]

local mq = require('mq')
require('ImGui')

-- Configuration
local SCRIPT_NAME = "Group Task Tracker"
local UPDATE_INTERVAL = 1000  -- Update every 1 second to reduce DanNet load
local TASK_QUERY_COOLDOWN = 500

-- UI State
local Open = true
local ShowUI = true
local selectedTab = 1  -- 0 = Group Task Tracker, 1 = Task Selection

-- Data Storage
local groupMembers = {}
local selectedTask = ""
local selectedTaskID = nil
local availableTasks = {}
local taskProgress = {}
local previousTaskProgress = {}  -- Track previous state to detect changes
local lastUpdate = 0
local isQueryingTasks = false
local lastTaskQuery = 0
local needsProgressUpdate = false
local needsRefresh = false  -- Flag for deferred refresh (to avoid mq.delay in ImGui callback)
local needsTaskSetup = false  -- Flag for deferred task observer setup
local pendingTaskID = nil  -- Task ID to set up observers for
local TaskNPC = nil  -- Store the NPC targeted when accepting a task

-- Checkbox states for each member
local checkboxStates = {}  -- [memberName] = { i = bool, ivu = bool }
local lastInvisCheckTime = 0
local INVIS_CHECK_INTERVAL = 200  -- Check invisible status every 200ms

-- Loot all state machine
local lootState = {
    active = false,
    phase = "idle",  -- idle, querying, looting
    currentItem = 1,
    memberLootCounts = {},
    lastCommandTime = 0,
    commandDelay = 1000,  -- 1 second between loot commands
    queryStarted = false
}

-- Ground spawn pickup state machine
local pickupState = {
    active = false,
    membersToPickup = {}
}

-- Hail state machine
local hailState = {
    active = false,
    phase = "idle",  -- idle, targeting, hailing
    currentHail = 1,
    hailCount = 0,
    targetID = nil,
    lastCommandTime = 0,
    commandDelay = 5000  -- 5 seconds between hails
}

-- Turn in state machine
local turninState = {
    active = false,
    phase = "idle",  -- idle, targeting, picking, clicking, giving
    cursorItem = "",
    stackSize = 1,
    targetID = nil,
    lastCommandTime = 0,
    commandDelay = 500
}

-- Use item state machine
local useItemState = {
    active = false,
    phase = "idle",  -- idle, targeting, using
    currentMember = 1,
    itemName = "",
    targetID = nil,
    lastCommandTime = 0,
    commandDelay = 500
}

local queryCounter = 0

-- Persistent observer tracking
local persistentObservers = {} -- [characterName][query] = true

-- Create a persistent observer (does not read the value)
local function CreatePersistentObserver(characterName, query)
    local cleanName = characterName:gsub("'s corpse$", "")

    -- Initialize character table if needed
    if not persistentObservers[cleanName] then
        persistentObservers[cleanName] = {}
    end

    -- Only create if not already exists
    if not persistentObservers[cleanName][query] then
        mq.cmdf('/squelch /dobserve %s -q "%s"', cleanName, query)
        persistentObservers[cleanName][query] = true
    end
end

-- Read a persistent observer value (must be created first)
local function ReadPersistentObserver(characterName, query)
    local cleanName = characterName:gsub("'s corpse$", "")

    local success, result = pcall(function()
        return mq.TLO.DanNet(cleanName).Observe(query)()
    end)

    if not success or result == nil or result == "NULL" or result == "" or result == false or result == "FALSE" then
        return nil
    end

    return result
end

-- Drop a persistent observer
local function DropPersistentObserver(characterName, query)
    local cleanName = characterName:gsub("'s corpse$", "")

    if persistentObservers[cleanName] and persistentObservers[cleanName][query] then
        mq.cmdf('/squelch /dobserve %s -q "%s" -drop', cleanName, query)
        persistentObservers[cleanName][query] = nil
    end
end

-- Drop all persistent observers for a character
local function DropAllObserversForCharacter(characterName)
    local cleanName = characterName:gsub("'s corpse$", "")

    if persistentObservers[cleanName] then
        for query, _ in pairs(persistentObservers[cleanName]) do
            mq.cmdf('/squelch /dobserve %s -q "%s" -drop', cleanName, query)
        end
        persistentObservers[cleanName] = nil
    end
end

-- Drop all persistent observers
local function DropAllObservers()
    for characterName, queries in pairs(persistentObservers) do
        for query, _ in pairs(queries) do
            mq.cmdf('/squelch /dobserve %s -q "%s" -drop', characterName, query)
        end
    end
    persistentObservers = {}
end

-- Set up invis observers for all remote group members
local function SetupInvisObservers()
    local myName = mq.TLO.Me.CleanName()

    for _, memberName in ipairs(groupMembers) do
        if memberName ~= myName then
            local cleanName = memberName:gsub("'s corpse$", "")

            -- Create Me.Invis observer with delay if new
            if not persistentObservers[cleanName] or not persistentObservers[cleanName]['Me.Invis'] then
                CreatePersistentObserver(memberName, 'Me.Invis')
                mq.delay(50)
            end

            -- Create Me.Invis[UNDEAD] observer with delay if new
            if not persistentObservers[cleanName] or not persistentObservers[cleanName]['Me.Invis[UNDEAD]'] then
                CreatePersistentObserver(memberName, 'Me.Invis[UNDEAD]')
                mq.delay(50)
            end
        end
    end
end

-- Read invis status for a remote character
local function GetRemoteInvisStatus(characterName)
    local invis = ReadPersistentObserver(characterName, 'Me.Invis')
    local invisUndead = ReadPersistentObserver(characterName, 'Me.Invis[UNDEAD]')

    return {
        invis = (invis == "TRUE" or invis == true),
        invisUndead = (invisUndead == "TRUE" or invisUndead == true)
    }
end

-- Query DanNet - use query string as observer index (creates/destroys observer) - for transient queries
local function DanNetQuery(characterName, query)
    -- Strip "'s corpse" suffix if present
    local cleanName = characterName:gsub("'s corpse$", "")

    -- Set up observation with full squelch
    mq.cmdf('/squelch /dobserve %s -q "%s"', cleanName, query)

    -- Wait for DanNet to populate - 100ms for reliable queries
    mq.delay(100)

    -- Read using .Observe(query)() with error handling
    local success, result = pcall(function()
        return mq.TLO.DanNet(cleanName).Observe(query)()
    end)

    -- Drop observer when done
    mq.cmdf('/squelch /dobserve %s -q "%s" -drop', cleanName, query)

    -- Handle errors or NULL/empty
    if not success or result == nil or result == "NULL" or result == "" or result == false or result == "FALSE" then
        return nil
    end

    return result
end

-- Track task progress state for each character
local taskObserverState = {} -- [characterName] = { taskID, currentObjective, stepQuery, statusQuery }

-- Set up initial task observers for a character - find task slot by matching Task.ID
local function SetupTaskObserversForCharacter(characterName, taskID)
    local myName = mq.TLO.Me.CleanName()
    if characterName == myName then return end

    local cleanName = characterName:gsub("'s corpse$", "")
    local targetID = tostring(taskID)

    -- First, find which task slot has the matching Task.ID using transient DanNetQuery
    local taskSlot = nil
    for i = 1, 10 do
        local slotID = DanNetQuery(characterName, string.format('Task[%d].ID', i))

        if not slotID or slotID == "" or slotID == "NULL" then
            break
        end

        if tostring(slotID) == targetID then
            taskSlot = i
            break
        end
    end

    if not taskSlot then
        taskObserverState[cleanName] = { taskID = taskID, taskSlot = nil, currentObjective = nil, complete = false, hasTask = false }
        return
    end

    -- Now create persistent observer for Task[slot].Step
    local stepQuery = string.format('Task[%d].Step', taskSlot)
    if not persistentObservers[cleanName] or not persistentObservers[cleanName][stepQuery] then
        CreatePersistentObserver(characterName, stepQuery)
        mq.delay(200)
    end

    -- Read the current step text
    local stepText = ReadPersistentObserver(characterName, stepQuery)

    if not stepText or stepText == "" or stepText == "NULL" then
        -- Character may have completed the task
        taskObserverState[cleanName] = { taskID = taskID, taskSlot = taskSlot, currentObjective = nil, stepQuery = stepQuery, complete = true, hasTask = true }
        return
    end

    -- Find the objective index by checking objectives until we match
    local currentObjective = nil
    for j = 1, 20 do
        local instrQuery = string.format('Task[%d].Objective[%d].Instruction', taskSlot, j)
        if not persistentObservers[cleanName] or not persistentObservers[cleanName][instrQuery] then
            CreatePersistentObserver(characterName, instrQuery)
            mq.delay(100)
        end

        local instruction = ReadPersistentObserver(characterName, instrQuery)
        if not instruction or instruction == "" or instruction == "NULL" then
            break
        end

        if instruction == stepText then
            currentObjective = j
            break
        end
    end

    if not currentObjective then
        -- Couldn't find matching objective, task may be complete
        taskObserverState[cleanName] = { taskID = taskID, taskSlot = taskSlot, currentObjective = nil, stepQuery = stepQuery, complete = true, hasTask = true }
        return
    end

    -- Create observer for the current objective's status
    local statusQuery = string.format('Task[%d].Objective[%d].Status', taskSlot, currentObjective)
    if not persistentObservers[cleanName] or not persistentObservers[cleanName][statusQuery] then
        CreatePersistentObserver(characterName, statusQuery)
        mq.delay(100)
    end

    -- Store the state
    taskObserverState[cleanName] = {
        taskID = taskID,
        taskSlot = taskSlot,
        currentObjective = currentObjective,
        stepQuery = stepQuery,
        statusQuery = statusQuery,
        complete = false,
        hasTask = true
    }
end

-- Update task observer when objective completes - drop old status observer, find new objective
local function UpdateTaskObserverForCharacter(characterName, taskID)
    local myName = mq.TLO.Me.CleanName()
    if characterName == myName then return end

    local cleanName = characterName:gsub("'s corpse$", "")
    local state = taskObserverState[cleanName]

    if not state or not state.taskSlot then
        -- No state yet, set up from scratch
        SetupTaskObserversForCharacter(characterName, taskID)
        return
    end

    -- If character doesn't have the task, nothing to update
    if not state.hasTask then
        return
    end

    -- Read the current step text
    local stepText = ReadPersistentObserver(characterName, state.stepQuery)

    -- Check if current objective status is "Done"
    if state.statusQuery then
        local status = ReadPersistentObserver(characterName, state.statusQuery)
        if status == "Done" then
            -- Drop the old status observer
            DropPersistentObserver(characterName, state.statusQuery)

            -- Find the new objective that matches stepText
            local newObjective = nil
            for j = 1, 20 do
                local instrQuery = string.format('Task[%d].Objective[%d].Instruction', state.taskSlot, j)
                if not persistentObservers[cleanName] or not persistentObservers[cleanName][instrQuery] then
                    CreatePersistentObserver(characterName, instrQuery)
                    mq.delay(50)
                end

                local instruction = ReadPersistentObserver(characterName, instrQuery)
                if not instruction or instruction == "" or instruction == "NULL" then
                    break
                end

                if instruction == stepText then
                    newObjective = j
                    break
                end
            end

            if newObjective then
                -- Create new status observer
                local newStatusQuery = string.format('Task[%d].Objective[%d].Status', state.taskSlot, newObjective)
                if not persistentObservers[cleanName] or not persistentObservers[cleanName][newStatusQuery] then
                    CreatePersistentObserver(characterName, newStatusQuery)
                    mq.delay(50)
                end

                state.currentObjective = newObjective
                state.statusQuery = newStatusQuery
                state.complete = false
            else
                -- No matching objective found, task may be complete
                state.currentObjective = nil
                state.statusQuery = nil
                state.complete = true
            end
        end
    end
end

-- Read task progress from persistent observers
local function ReadTaskProgressFromObservers(characterName)
    local cleanName = characterName:gsub("'s corpse$", "")
    local state = taskObserverState[cleanName]

    if not state then
        return { hasTask = false, currentStep = "Not on task", objectives = {} }
    end

    -- Character doesn't have the task
    if not state.hasTask then
        return { hasTask = false, currentStep = "Not on task", objectives = {} }
    end

    if state.complete then
        return { hasTask = true, currentStep = "All Complete!", objectives = {}, currentObjective = nil }
    end

    if not state.stepQuery then
        return { hasTask = false, currentStep = "Not on task", objectives = {} }
    end

    local stepText = ReadPersistentObserver(characterName, state.stepQuery)
    local status = state.statusQuery and ReadPersistentObserver(characterName, state.statusQuery) or "Unknown"

    if not stepText or stepText == "" or stepText == "NULL" then
        return { hasTask = true, currentStep = "All Complete!", objectives = {}, currentObjective = nil }
    end

    local currentStep = string.format("%s (%s)", stepText, status or "Unknown")

    return {
        hasTask = true,
        currentStep = currentStep,
        objectives = {},
        currentObjective = state.currentObjective
    }
end

----------------------------------------------------------------------
-- GROUP AND TASK FUNCTIONS
----------------------------------------------------------------------

-- Update group members list
local function UpdateGroupMembers()
    groupMembers = {}
    local myName = mq.TLO.Me.CleanName()
    table.insert(groupMembers, myName)

    local groupSize = mq.TLO.Group.Members() or 0
    for i = 1, groupSize do
        local member = mq.TLO.Group.Member(i)
        local memberName = member.CleanName()
        local memberType = member.Type()
        -- Skip mercenaries
        if memberName and memberName ~= "" and memberType ~= "Mercenary" then
            table.insert(groupMembers, memberName)
        end
    end

    -- Set up persistent invis observers for remote members
    SetupInvisObservers()
end

-- Get local tasks
local function UpdateAvailableTasks()
    availableTasks = {}
    
    for i = 1, 20 do
        local taskTitle = mq.TLO.Task(i).Title()
        local taskID = mq.TLO.Task(i).ID()
        
        if taskTitle and taskTitle ~= "" and taskTitle ~= "NULL" and taskID then
            table.insert(availableTasks, {
                index = i,
                title = taskTitle,
                id = taskID,
                sharedCount = 0
            })
        end
    end
end

-- Get local task progress
local function GetTaskProgress(taskID)
    local progress = {
        hasTask = false,
        currentStep = "Not on task",
        objectives = {}
    }
    
    for i = 1, 20 do
        local id = mq.TLO.Task(i).ID()
        
        if id and tostring(id) == tostring(taskID) then
            progress.hasTask = true
            
            for j = 1, 30 do
                local objective = mq.TLO.Task(i).Objective(j)
                if not objective then break end
                
                local objText = objective.Instruction()
                if not objText or objText == "" or objText == "NULL" then
                    break
                end
                
                -- Get status instead of Done (more reliable)
                local objStatus = objective.Status()
                local objDone = (objStatus == "Done")
                
                table.insert(progress.objectives, {
                    index = j,
                    text = objText,
                    done = objDone,
                    status = objStatus
                })
                
                if not objDone and progress.currentStep == "Not on task" then
                    if objStatus then
                        progress.currentStep = string.format("%s (%s)", objText, objStatus)
                    else
                        progress.currentStep = objText
                    end
                    progress.currentObjective = j  -- Track which objective number we're on
                end
            end
            
            if progress.currentStep == "Not on task" and #progress.objectives > 0 then
                progress.currentStep = "All Complete!"
            end
            break
        end
    end
    
    return progress
end

-- Get remote task list - optimized
local function GetRemoteTaskList(characterName)
    local tasks = {}
    
    if not characterName or characterName == "" then
        return tasks
    end
    
    -- Only check first 5 task slots
    for i = 1, 5 do
        local taskID = DanNetQuery(characterName, string.format('Task[%d].ID', i))
        if not taskID then break end
        
        local taskTitle = DanNetQuery(characterName, string.format('Task[%d].Title', i))
        if taskTitle then
            table.insert(tasks, {
                title = taskTitle,
                id = tonumber(taskID)
            })
        end
    end
    
    return tasks
end

-- Query remote progress by ID - using transient observers
local function QueryRemoteTaskProgress(characterName, taskID)
    if not taskID or not characterName or characterName == "" then
        return {hasTask = false, currentStep = "Not on task", objectives = {}}
    end

    local cleanName = characterName:gsub("'s corpse$", "")
    local targetID = tostring(taskID)

    -- Find task slot with this ID
    local taskSlot = nil
    for i = 1, 5 do
        local id = DanNetQuery(characterName, string.format('Task[%d].ID', i))
        if not id or id == "" or id == "NULL" then break end

        if tostring(id) == targetID then
            taskSlot = i
            break
        end
    end

    if not taskSlot then
        return {hasTask = false, currentStep = "Not on task", objectives = {}}
    end

    -- Find the current active objective using Task.Step
    local progress = {hasTask = true, currentStep = "Not on task", objectives = {}}

    -- Get the current step instruction text
    local stepIndex = DanNetQuery(characterName, string.format('Task[%d].Step', taskSlot))

    -- Collect all objectives first
    local allObjectives = {}
    for j = 1, 20 do
        local objInstruction = DanNetQuery(characterName, string.format('Task[%d].Objective[%d].Instruction', taskSlot, j))

        -- If no instruction, we've reached the end of objectives
        if not objInstruction or objInstruction == "" or objInstruction == "NULL" then
            break
        end

        local objStatus = DanNetQuery(characterName, string.format('Task[%d].Objective[%d].Status', taskSlot, j))

        table.insert(allObjectives, {
            index = j,
            instruction = objInstruction,
            status = objStatus
        })
    end

    -- Use Task.Step to find the current objective by matching instruction text
    if stepIndex and stepIndex ~= "" and stepIndex ~= "NULL" then
        -- Find the objective that matches the Step instruction
        for _, obj in ipairs(allObjectives) do
            if obj.instruction == stepIndex then
                progress.currentStep = string.format("%s (%s)", obj.instruction, obj.status or "Unknown")
                progress.currentObjective = obj.index
                break
            end
        end
    end

    -- Fallback: find first non-Done objective if we didn't find a match
    if progress.currentStep == "Not on task" then
        for _, obj in ipairs(allObjectives) do
            if obj.status and obj.status ~= "" and obj.status ~= "NULL" and obj.status ~= "Done" then
                progress.currentStep = string.format("%s (%s)", obj.instruction, obj.status)
                progress.currentObjective = obj.index
                break
            end
        end
    end

    -- If we went through all objectives and didn't find an incomplete one, mark as complete
    if progress.currentStep == "Not on task" then
        progress.currentStep = "All Complete!"
    end

    return progress
end


-- Update all progress using persistent observers
local function UpdateTaskProgress()
    if not selectedTaskID then return end

    local newProgress = {}
    local myName = mq.TLO.Me.CleanName()

    for _, memberName in ipairs(groupMembers) do
        if memberName == myName then
            newProgress[memberName] = GetTaskProgress(selectedTaskID)
        else
            -- Update observer state (handles objective completion transitions)
            UpdateTaskObserverForCharacter(memberName, selectedTaskID)
            -- Read progress from observers
            newProgress[memberName] = ReadTaskProgressFromObservers(memberName)
        end
    end

    -- Only update if something changed OR if taskProgress is empty (first run)
    local hasChanged = false
    local isEmpty = next(taskProgress) == nil

    if not isEmpty then
        for memberName, progress in pairs(newProgress) do
            local oldProgress = previousTaskProgress[memberName]
            if not oldProgress or oldProgress.currentStep ~= progress.currentStep then
                hasChanged = true
                break
            end
        end
    end

    if hasChanged or isEmpty then
        taskProgress = newProgress
        previousTaskProgress = {}
        for k, v in pairs(newProgress) do
            previousTaskProgress[k] = {currentStep = v.currentStep, hasTask = v.hasTask}
        end
    end
end

-- Check if a character is invisible
local function IsCharacterInvisible(characterName)
    local myName = mq.TLO.Me.CleanName()

    if characterName == myName then
        -- Check local character (driver)
        return mq.TLO.Me.Invis() or false
    else
        -- Read from persistent observer
        local invisStatus = ReadPersistentObserver(characterName, 'Me.Invis')
        return (invisStatus == "TRUE" or invisStatus == true)
    end
end

-- Check if a character is invisible vs undead
local function IsCharacterInvisUndead(characterName)
    local myName = mq.TLO.Me.CleanName()

    if characterName == myName then
        -- Check local character (driver) - Me.Invis[UNDEAD] or Me.Invis[2]
        return mq.TLO.Me.Invis("UNDEAD")() or false
    else
        -- Read from persistent observer
        local ivuStatus = ReadPersistentObserver(characterName, 'Me.Invis[UNDEAD]')
        return (ivuStatus == "TRUE" or ivuStatus == true)
    end
end

-- Update invisible status for all group members
local function UpdateInvisibleStatus()
    for _, memberName in ipairs(groupMembers) do
        if not checkboxStates[memberName] then
            checkboxStates[memberName] = { i = false, ivu = false }
        end

        -- Update invisible checkbox based on actual status
        checkboxStates[memberName].i = IsCharacterInvisible(memberName)
    end
end

----------------------------------------------------------------------
-- TURN IN ITEM FUNCTIONALITY
----------------------------------------------------------------------

-- Use item on target - pause boxr, target driver's target, and use driver's held item
local function UseItemOnTarget()
    local myName = mq.TLO.Me.CleanName()

    -- Get the item the driver is holding
    local heldItem = mq.TLO.Cursor.Name()
    if not heldItem or heldItem == "" or heldItem == "NULL" then
        print("[GQT] No item on cursor!")
        return
    end

    -- Check if we have a target
    local targetName = mq.TLO.Target.CleanName()
    local targetID = mq.TLO.Target.ID()
    if not targetName or targetName == "" or targetName == "NULL" or not targetID then
        print("[GQT] No target selected!")
        return
    end

    print(string.format("[GQT] Requesting party members use %s on %s", heldItem, targetName))

    -- Start the use item state machine
    useItemState.active = true
    useItemState.phase = "idle"
    useItemState.currentMember = 1
    useItemState.itemName = heldItem
    useItemState.targetID = targetID
    useItemState.lastCommandTime = 0
end

-- Loot all assigned items - have all group members loot their personal loot
local function LootAllAssigned()
    -- Start the loot process - querying happens in the state machine
    lootState.active = true
    lootState.phase = "querying"
    lootState.memberLootCounts = {}
    lootState.currentItem = 1
    lootState.lastCommandTime = 0
    lootState.queryStarted = false
    print("[GQT] Starting loot process...")
end

-- Pick up ground spawn - find members behind the highest step count and have them pick up nearest ground spawn
local function PickupGroundSpawn()
    if not selectedTaskID then
        print("[GQT] No task selected!")
        return
    end

    -- Check if we have any task progress data and track which step each member is on
    local memberStepNumbers = {}
    local highestStep = 0

    for _, memberName in ipairs(groupMembers) do
        local progress = taskProgress[memberName]
        if progress and progress.currentObjective then
            -- Track which step number (objective number) this member is on
            local stepNumber = progress.currentObjective
            memberStepNumbers[memberName] = stepNumber
            if stepNumber > highestStep then
                highestStep = stepNumber
            end
        elseif progress and progress.currentStep == "All Complete!" then
            -- Member has completed all objectives - use total objective count + 1
            local totalObjectives = #(progress.objectives or {})
            memberStepNumbers[memberName] = totalObjectives + 1
            if totalObjectives + 1 > highestStep then
                highestStep = totalObjectives + 1
            end
        end
    end

    -- If we have no member data at all, return early
    if next(memberStepNumbers) == nil then
        print("[GQT] No task progress data available - wait for progress to load")
        return
    end

    -- Find all members who are behind the highest step
    local membersToPickup = {}
    for memberName, stepNumber in pairs(memberStepNumbers) do
        if stepNumber < highestStep then
            table.insert(membersToPickup, memberName)
        end
    end

    -- If all members are on the same step, have all members try
    if #membersToPickup == 0 then
        print(string.format("[GQT] All members on step %d, all picking up ground spawn", highestStep))
        pickupState.membersToPickup = groupMembers
    else
        print(string.format("[GQT] %d member(s) behind (highest step: %d), picking up ground spawn", #membersToPickup, highestStep))
        pickupState.membersToPickup = membersToPickup
    end

    -- Start the pickup state machine
    pickupState.active = true
end

-- Perform hails - have all group members hail driver's target based on progress count
local function PerformHails()
    local myName = mq.TLO.Me.CleanName()

    -- Check if we have a target
    local targetName = mq.TLO.Target.CleanName()
    local targetID = mq.TLO.Target.ID()
    if not targetName or targetName == "" or targetName == "NULL" or not targetID then
        print("[GQT] No target selected!")
        return
    end

    -- Get the driver's task progress and extract the number
    local myProgress = taskProgress[myName]
    if not myProgress or not myProgress.currentStep then
        print("[GQT] No task progress to read!")
        return
    end

    -- Extract numbers from the progress text (e.g., "0/4" gives us 4, or "Talk to NPC 3 times" gives us 3)
    local numbers = {}
    for num in myProgress.currentStep:gmatch("%d+") do
        table.insert(numbers, tonumber(num))
    end

    if #numbers == 0 then
        print("[GQT] Could not find a number in progress text!")
        return
    end

    -- If we have two numbers (like "0/4"), use the second one; otherwise use the first
    local hailCount = #numbers >= 2 and numbers[2] or numbers[1]

    print(string.format("[GQT] Requesting party members hail %s %d times", targetName, hailCount))

    -- Pause boxr
    mq.cmd('/dgga /boxr pause')

    -- Start the hail state machine (targeting will happen in the state machine)
    hailState.active = true
    hailState.phase = "targeting"
    hailState.currentHail = 1
    hailState.hailCount = hailCount
    hailState.targetID = targetID
    hailState.lastCommandTime = 0
end

-- Turn in item - have all group members give the cursor item to driver's target
local function TurnInItem()
    local myName = mq.TLO.Me.CleanName()

    -- Get cursor item info (optional - will default to 1 if no item)
    local cursorItem = mq.TLO.Cursor.Name()
    local stackSize = mq.TLO.Cursor.Stack() or 1

    -- Check if we have a target
    local targetName = mq.TLO.Target.CleanName()
    local targetID = mq.TLO.Target.ID()
    if not targetName or targetName == "" or targetName == "NULL" or not targetID then
        print("[GQT] No target selected!")
        return
    end

    if cursorItem and cursorItem ~= "" and cursorItem ~= "NULL" then
        print(string.format("[GQT] Requesting party members turn in: %sx%d to %s", cursorItem, stackSize, targetName))
    else
        print(string.format("[GQT] Requesting party members turn in items to %s", targetName))
        cursorItem = ""  -- Set to empty string for safety
    end

    -- Pause boxr
    mq.cmd('/dgga /boxr pause')

    -- Start the turn in state machine
    turninState.active = true
    turninState.phase = "targeting"
    turninState.cursorItem = cursorItem
    turninState.stackSize = stackSize
    turninState.targetID = targetID
    turninState.lastCommandTime = 0
end

----------------------------------------------------------------------
-- ImGui UI
----------------------------------------------------------------------

local function GroupTaskTrackerGUI()
    if not ShowUI then return end

    local shouldShow
    Open, shouldShow = ImGui.Begin(SCRIPT_NAME .. '##MainWindow', true)

    if not Open then
        ImGui.End()
        return
    end

    if ImGui.BeginTabBar("MainTabs") then
            -- Progress Tab (position 1)
            if ImGui.BeginTabItem("Group Task Tracker", nil, selectedTab == 0 and ImGuiTabItemFlags.SetSelected or 0) then
                if selectedTab == 0 then selectedTab = -1 end  -- Clear flag after first render
                ImGui.Text(string.format("Group: %d members", #groupMembers))
                ImGui.Separator()

                -- Progress table
                if selectedTaskID then
                    ImGui.Text(string.format("Tracking: %s", selectedTask))
                    ImGui.Separator()

                    if ImGui.BeginTable("Progress", 4, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg) then
                        ImGui.TableSetupColumn("Character", ImGuiTableColumnFlags.WidthFixed, 120)
                        ImGui.TableSetupColumn("i", ImGuiTableColumnFlags.WidthFixed, 25)
                        ImGui.TableSetupColumn("ivu", ImGuiTableColumnFlags.WidthFixed, 25)
                        ImGui.TableSetupColumn("Progress", ImGuiTableColumnFlags.WidthStretch)
                        ImGui.TableHeadersRow()

                        for _, memberName in ipairs(groupMembers) do
                            -- Initialize checkbox states if needed
                            if not checkboxStates[memberName] then
                                checkboxStates[memberName] = { i = false, ivu = false }
                            end

                            ImGui.TableNextRow()
                            ImGui.TableSetColumnIndex(0)

                            if memberName == mq.TLO.Me.CleanName() then
                                ImGui.TextColored(0.5, 1, 1, 1, memberName .. " (You)")
                            else
                                ImGui.Text(memberName)
                            end

                            -- "i" checkbox column (centered, smaller, read-only)
                            ImGui.TableSetColumnIndex(1)
                            local availWidth = ImGui.GetContentRegionAvail()
                            local checkboxSize = 13  -- Smaller checkbox size
                            ImGui.SetCursorPosX(ImGui.GetCursorPosX() + (availWidth - checkboxSize) * 0.5)
                            ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 1, 1)
                            ImGui.BeginDisabled()  -- Make read-only since it's auto-updated
                            local iChecked = checkboxStates[memberName].i
                            ImGui.Checkbox("##i_" .. memberName, iChecked)
                            ImGui.EndDisabled()
                            ImGui.PopStyleVar()

                            -- "ivu" checkbox column (centered, smaller, read-only)
                            ImGui.TableSetColumnIndex(2)
                            availWidth = ImGui.GetContentRegionAvail()
                            ImGui.SetCursorPosX(ImGui.GetCursorPosX() + (availWidth - checkboxSize) * 0.5)
                            ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 1, 1)
                            ImGui.BeginDisabled()  -- Make read-only since it's auto-updated
                            local ivuChecked = checkboxStates[memberName].ivu
                            ImGui.Checkbox("##ivu_" .. memberName, ivuChecked)
                            ImGui.EndDisabled()
                            ImGui.PopStyleVar()

                            -- Progress column
                            ImGui.TableSetColumnIndex(3)

                            local prog = taskProgress[memberName]
                            if prog then
                                if prog.hasTask then
                                    local stepText = prog.currentStep or "Unknown"
                                    if stepText == "All Complete!" then
                                        ImGui.TextColored(0.5, 1, 0.5, 1, "[DONE] All Complete!")
                                    else
                                        ImGui.TextColored(1, 1, 0.5, 1, stepText)
                                    end
                                else
                                    ImGui.TextColored(0.7, 0.7, 0.7, 1, prog.currentStep or "Not on task")
                                end
                            else
                                ImGui.TextColored(0.7, 0.7, 0.7, 1, "...")
                            end
                        end

                        ImGui.EndTable()
                    end
                else
                    ImGui.TextColored(1, 0.5, 0, 1, "No task selected")
                    ImGui.Text("Select a task from the Task Selection tab")
                end

                ImGui.Separator()

                if ImGui.Button("Refresh") then
                    -- Set flag for deferred refresh (mq.delay cannot be called from ImGui callback)
                    needsRefresh = true
                    print("[GQT] Refresh queued...")
                end

                ImGui.Separator()
                ImGui.TextColored(0.7, 0.9, 1, 1, "Commands:")

                if ImGui.Button("Accept Task") then
                    -- Store the current target as the TaskNPC
                    local targetName = mq.TLO.Target.CleanName()
                    if targetName and targetName ~= "" then
                        TaskNPC = targetName
                        print(string.format("[GQT] TaskNPC set to: %s", TaskNPC))
                    end
                    mq.cmd('/dga /notify TaskSelectWnd TSEL_AcceptButton leftmouseup')
                end
                ImGui.SameLine()
                if ImGui.Button("Turn in Item") then
                    TurnInItem()
                end

                if ImGui.Button("Inspect") then
                    mq.cmd('/dgga /inspect')
                end
                ImGui.SameLine()
                if ImGui.Button("Use Item") then
                    UseItemOnTarget()
                end

                if ImGui.Button("Hails") then
                    PerformHails()
                end
                ImGui.SameLine()
                if ImGui.Button("Loot All") then
                    LootAllAssigned()
                end

                if ImGui.Button("Pickup Ground Spawn") then
                    PickupGroundSpawn()
                end

                ImGui.BeginDisabled()
                ImGui.Button("Assign Task Loot")
                ImGui.EndDisabled()
                ImGui.SameLine()
                if ImGui.Button("Target Task NPC") then
                    if TaskNPC and TaskNPC ~= "" then
                        mq.cmdf('/target "%s"', TaskNPC)
                        print(string.format("[GQT] Targeting TaskNPC: %s", TaskNPC))
                    else
                        print("[GQT] No TaskNPC set - accept a task first")
                    end
                end

                ImGui.EndTabItem()
            end

            -- Task Selection Tab (position 2, but shown on launch)
            if ImGui.BeginTabItem("Task Selection", nil, selectedTab == 1 and ImGuiTabItemFlags.SetSelected or 0) then
                if selectedTab == 1 then selectedTab = -1 end  -- Clear flag after first render

                ImGui.Text(string.format("Your Tasks: %d", #availableTasks))
                ImGui.Separator()

                ImGui.TextColored(0.7, 0.9, 1, 1, "Instructions:")
                ImGui.Text("Select a task from the list below")
                ImGui.Separator()

                -- Quest list
                if #availableTasks > 0 then
                    for i, task in ipairs(availableTasks) do
                        local label = task.title
                        if task.sharedCount > 0 then
                            label = string.format("%s [%d/%d]", task.title, task.sharedCount, #groupMembers)
                            if task.sharedCount == #groupMembers then
                                label = label .. " ✓"
                            end
                        end

                        if ImGui.Selectable(label, selectedTaskID == task.id) then
                            if selectedTaskID ~= task.id then
                                selectedTask = task.title
                                selectedTaskID = task.id
                                -- Defer observer setup to main loop (mq.delay cannot be called from ImGui)
                                taskObserverState = {}
                                needsTaskSetup = true
                                pendingTaskID = task.id
                                selectedTab = 0  -- Switch to Group Task Tracker tab
                            end
                        end
                    end
                else
                    ImGui.TextColored(1, 0.5, 0, 1, "No active tasks")
                end

                ImGui.EndTabItem()
            end

            -- Instructions Tab
            if ImGui.BeginTabItem("Instructions") then
                ImGui.TextColored(0.7, 0.9, 1, 1, "How to Use Group Task Tracker")
                ImGui.Separator()

                ImGui.TextColored(1, 1, 0.5, 1, "Setup:")
                ImGui.BulletText("All characters must be in the same group")
                ImGui.BulletText("DanNet must be running on all clients")
                ImGui.BulletText("Mercenaries are automatically ignored")
                ImGui.Separator()

                ImGui.TextColored(1, 1, 0.5, 1, "Task Selection:")
                ImGui.BulletText("Go to the Task Selection tab")
                ImGui.BulletText("Select a task from your active task list")
                ImGui.BulletText("The tracker will show progress for all group members")
                ImGui.Separator()

                ImGui.TextColored(1, 1, 0.5, 1, "Accept Task:")
                ImGui.BulletText("Click 'Accept Task' to have all group members accept the task window")
                ImGui.Separator()

                ImGui.TextColored(1, 1, 0.5, 1, "Turn in Item:")
                ImGui.BulletText("Put the item to turn in on your cursor")
                ImGui.BulletText("Target the NPC you want to give items to")
                ImGui.BulletText("Click 'Turn in Item' button")
                ImGui.BulletText("All group members will search bags and turn in same quantity")
                ImGui.BulletText("Note: May need to click button 2-3 times for reliable turnin")
                ImGui.Separator()

                ImGui.TextColored(1, 1, 0.5, 1, "Inspect:")
                ImGui.BulletText("Target an NPC and click 'Inspect'")
                ImGui.BulletText("All group members will inspect the target")
                ImGui.Separator()

                ImGui.TextColored(1, 1, 0.5, 1, "Use Item:")
                ImGui.BulletText("Put the item on your cursor")
                ImGui.BulletText("Target the NPC or object")
                ImGui.BulletText("Click 'Use Item' button")
                ImGui.BulletText("All group members will target same NPC and use the item")
                ImGui.Separator()

                ImGui.TextColored(1, 1, 0.5, 1, "Hails:")
                ImGui.BulletText("Select a task with a hail step")
                ImGui.BulletText("Target the NPC to hail")
                ImGui.BulletText("Click 'Hails' button")
                ImGui.BulletText("Pauses boxr, all members hail based on task progress number")
                ImGui.BulletText("Resumes boxr when complete")
                ImGui.Separator()

                ImGui.TextColored(1, 1, 0.5, 1, "Loot All:")
                ImGui.BulletText("Click 'Loot All' button")
                ImGui.BulletText("Opens Advanced Loot window for all group members")
                ImGui.BulletText("Clicks all loot buttons in Personal Loot list")
                ImGui.Separator()

                ImGui.TextColored(1, 1, 0.5, 1, "Pickup Ground Spawn:")
                ImGui.BulletText("Click 'Pickup Ground Spawn' button")
                ImGui.BulletText("Members behind on task progress will pick up nearest ground spawn")
                ImGui.BulletText("If all members are on same step, all will attempt pickup")
                ImGui.Separator()

                ImGui.TextColored(1, 1, 0.5, 1, "Target Task NPC:")
                ImGui.BulletText("When accepting a task, the targeted NPC is saved")
                ImGui.BulletText("Click 'Target Task NPC' to target that NPC again")
                ImGui.BulletText("Useful for returning to quest giver to turn in")
                ImGui.Separator()

                ImGui.TextColored(1, 1, 0.5, 1, "Commands:")
                ImGui.BulletText("/gqt - Toggle UI window")
                ImGui.BulletText("/gqtstop - Stop the script")
                ImGui.BulletText("/gqtrefresh - Refresh group and task data")
                ImGui.BulletText("/gqtcleanup - Clear all DanNet observers (dev use)")

                ImGui.EndTabItem()
            end

        ImGui.EndTabBar()
    end

    ImGui.End()
end

----------------------------------------------------------------------
-- COMMANDS
----------------------------------------------------------------------

mq.bind('/gqt', function()
    ShowUI = not ShowUI
    print(string.format("\ay[\at%s\ay] UI %s", SCRIPT_NAME, ShowUI and "Opened" or "Closed"))
end)

mq.bind('/gqtstop', function()
    Open = false
end)

mq.bind('/gqtrefresh', function()
    -- Clear all task observers and recreate them
    DropAllObservers()
    taskObserverState = {}
    UpdateGroupMembers()
    UpdateAvailableTasks()
    if selectedTaskID then
        -- Recreate observers for all remote members
        local myName = mq.TLO.Me.CleanName()
        for _, memberName in ipairs(groupMembers) do
            if memberName ~= myName then
                SetupTaskObserversForCharacter(memberName, selectedTaskID)
            end
        end
        needsProgressUpdate = true
    end
    print("[GQT] Refreshed - observers recreated")
end)

mq.bind('/gqtcleanup', function()
    -- Drop all observers for all group members
    local myName = mq.TLO.Me.CleanName()
    print(string.format("\\ay[\\at%s\\ay] Cleaning up DanNet observers...", SCRIPT_NAME))

    -- Update group members first
    UpdateGroupMembers()

    -- Drop all observers for each group member
    for _, memberName in ipairs(groupMembers) do
        if memberName ~= myName then
            mq.cmdf('/squelch /dobserve %s -dropall', memberName)
            print(string.format("\\ay[\\at%s\\ay] Dropped observers for %s", SCRIPT_NAME, memberName))
        end
    end

    print(string.format("\\ay[\\at%s\\ay] \\agCleanup complete", SCRIPT_NAME))
end)

----------------------------------------------------------------------
-- MAIN
----------------------------------------------------------------------

mq.imgui.init('grouptasktracker', GroupTaskTrackerGUI)



print(string.format("\ay[\at%s\ay] \agStarted - /gqt to toggle, /gqtstop to exit, /gqtcleanup to clear observers", SCRIPT_NAME))

UpdateGroupMembers()
UpdateAvailableTasks()

-- Auto-select task if driver only has one task on startup
if #availableTasks == 1 then
    selectedTask = availableTasks[1].title
    selectedTaskID = availableTasks[1].id
    selectedTab = 0  -- Switch to Group Task Tracker tab
    print(string.format("[GQT] Auto-selected task: %s", selectedTask))
    -- Set up task observers for all remote members
    local myName = mq.TLO.Me.CleanName()
    for _, memberName in ipairs(groupMembers) do
        if memberName ~= myName then
            SetupTaskObserversForCharacter(memberName, selectedTaskID)
        end
    end
    needsProgressUpdate = true
end

while Open do
    local currentTime = os.clock() * 1000

    -- Handle deferred refresh (from Refresh button click in ImGui)
    if needsRefresh then
        needsRefresh = false
        DropAllObservers()
        taskObserverState = {}
        UpdateGroupMembers()
        UpdateAvailableTasks()
        if selectedTaskID then
            -- Recreate observers for all remote members
            local myName = mq.TLO.Me.CleanName()
            for _, memberName in ipairs(groupMembers) do
                if memberName ~= myName then
                    SetupTaskObserversForCharacter(memberName, selectedTaskID)
                end
            end
            needsProgressUpdate = true
        end
        print("[GQT] Refreshed - observers recreated")
    end

    -- Handle deferred task observer setup (from task selection in ImGui)
    if needsTaskSetup and pendingTaskID then
        needsTaskSetup = false
        local taskID = pendingTaskID
        pendingTaskID = nil
        local myName = mq.TLO.Me.CleanName()
        for _, memberName in ipairs(groupMembers) do
            if memberName ~= myName then
                SetupTaskObserversForCharacter(memberName, taskID)
            end
        end
        needsProgressUpdate = true
    end

    if needsProgressUpdate and not lootState.active and not pickupState.active and not hailState.active and not turninState.active and not useItemState.active then
        needsProgressUpdate = false
        UpdateTaskProgress()
    end

    -- Update group members and tasks every UPDATE_INTERVAL (skip during any active state machine to avoid blocking)
    if not lootState.active and not pickupState.active and not hailState.active and not turninState.active and not useItemState.active and currentTime - lastUpdate > UPDATE_INTERVAL then
        local previousMemberCount = #groupMembers
        UpdateGroupMembers()

        UpdateAvailableTasks()
        -- Also update task progress if we have a selected task
        if selectedTaskID then
            UpdateTaskProgress()
        end
        lastUpdate = currentTime
    end

    -- Update invisible status once per second
    if currentTime - lastInvisCheckTime >= INVIS_CHECK_INTERVAL then
        for _, memberName in ipairs(groupMembers) do
            if not checkboxStates[memberName] then
                checkboxStates[memberName] = { i = false, ivu = false }
            end
            checkboxStates[memberName].i = IsCharacterInvisible(memberName)
            checkboxStates[memberName].ivu = IsCharacterInvisUndead(memberName)
        end
        lastInvisCheckTime = currentTime
    end

    -- Process loot state machine
    if lootState.active then
        local currentTime = os.clock() * 1000
        local myName = mq.TLO.Me.CleanName()

        if lootState.phase == "querying" then
            -- Query phase: Query all members simultaneously and immediately start looting
            print("[GQT] Querying all members for loot counts...")

            -- Query all members at once (no delays)
            for _, memberName in ipairs(groupMembers) do
                local lootCount
                if memberName == myName then
                    lootCount = mq.TLO.AdvLoot.PCount() or 0
                else
                    local result = DanNetQuery(memberName, "AdvLoot.PCount")
                    lootCount = tonumber(result) or 0
                end
                lootState.memberLootCounts[memberName] = lootCount
                print(string.format("[GQT] %s has %d items", memberName, lootCount))
            end

            -- Calculate total and start looting immediately
            local totalItems = 0
            for _, count in pairs(lootState.memberLootCounts) do
                totalItems = totalItems + count
            end

            print(string.format("[GQT] Total personal loot items across group: %d", totalItems))

            if totalItems == 0 then
                print("[GQT] No personal loot to loot")
                lootState.active = false
                lootState.phase = "idle"
            else
                -- Start looting phase immediately
                lootState.phase = "looting"
                lootState.currentItem = 1
                lootState.lastCommandTime = 0
                print(string.format("[GQT] Starting to loot %d total items", totalItems))
            end

        elseif lootState.phase == "looting" then
            -- Looting phase: All members loot simultaneously with delay between rounds

            -- Wait for delay between loot rounds
            if lootState.lastCommandTime > 0 and (currentTime - lootState.lastCommandTime < lootState.commandDelay) then
                -- Still waiting, do nothing
            else
                -- Find the maximum item count across all members
                local maxItems = 0
                for _, count in pairs(lootState.memberLootCounts) do
                    if count > maxItems then
                        maxItems = count
                    end
                end

                -- Check if we're done looting
                if lootState.currentItem > maxItems then
                    -- All done
                    lootState.active = false
                    lootState.phase = "idle"
                    print("[GQT] Loot all complete!")
                else
                    -- Send loot command to all members who still have items
                    print(string.format("[GQT] Loot round %d - all characters looting simultaneously", lootState.currentItem))
                    for _, memberName in ipairs(groupMembers) do
                        local memberLootCount = lootState.memberLootCounts[memberName] or 0
                        if lootState.currentItem <= memberLootCount then
                            if memberName == myName then
                                mq.cmd('/advloot personal 1 loot')
                            else
                                mq.cmdf('/dex %s /advloot personal 1 loot', memberName)
                            end
                        end
                    end
                    lootState.lastCommandTime = currentTime
                    lootState.currentItem = lootState.currentItem + 1
                end
            end
        end
    end

    -- Process ground spawn pickup state machine
    if pickupState.active then
        local myName = mq.TLO.Me.CleanName()

        -- Send pickup commands to ALL characters simultaneously (no delays)
        print(string.format("[GQT] %d character(s) attempting to pick up ground spawn", #pickupState.membersToPickup))
        for _, memberName in ipairs(pickupState.membersToPickup) do
            if memberName == myName then
                mq.cmd('/itemtarget')
                mq.cmd('/click left item')
            else
                mq.cmdf('/dex %s /itemtarget', memberName)
                mq.cmdf('/dex %s /click left item', memberName)
            end
        end

        pickupState.active = false
        print("[GQT] Ground spawn pickup commands sent!")
    end

    -- Process hail state machine
    if hailState.active then
        local currentTime = os.clock() * 1000
        local myName = mq.TLO.Me.CleanName()

        if hailState.phase == "targeting" then
            -- Target NPC for all characters
            print("[GQT] Targeting NPC for all characters...")
            mq.cmdf('/target id %d', hailState.targetID)  -- Driver targets locally
            for _, memberName in ipairs(groupMembers) do
                if memberName ~= myName then
                    mq.cmdf('/dex %s /target id %d', memberName, hailState.targetID)
                end
            end

            -- Move to hailing phase and set up 5 second delay
            hailState.phase = "hailing"
            hailState.lastCommandTime = currentTime

        elseif hailState.phase == "hailing" then
            -- Wait for delay (5 seconds after targeting, then 5 seconds between hail rounds)
            if hailState.lastCommandTime > 0 and (currentTime - hailState.lastCommandTime < hailState.commandDelay) then
                -- Still waiting
            elseif hailState.currentHail <= hailState.hailCount then
                -- Send hail to ALL group members simultaneously
                print(string.format("[GQT] Round %d/%d - all characters hailing", hailState.currentHail, hailState.hailCount))

                -- Driver hails locally
                mq.cmd('/keypress h')

                -- Other members hail via DanNet
                for _, memberName in ipairs(groupMembers) do
                    if memberName ~= myName then
                        mq.cmdf('/dex %s /keypress h', memberName)
                    end
                end

                hailState.lastCommandTime = currentTime
                hailState.currentHail = hailState.currentHail + 1
            else
                -- All hails complete, unpause all members
                print("[GQT] Hails complete - unpausing all members")
                mq.cmd('/boxr unpause')  -- Driver unpause locally
                for _, memberName in ipairs(groupMembers) do
                    if memberName ~= myName then
                        mq.cmdf('/dex %s /boxr unpause', memberName)
                    end
                end
                hailState.active = false
                hailState.phase = "idle"
                print("[GQT] Hail commands complete!")
            end
        end
    end

    -- Process turn in state machine
    if turninState.active then
        local currentTime = os.clock() * 1000
        local myName = mq.TLO.Me.CleanName()

        -- Wait for delay between commands
        if turninState.lastCommandTime > 0 and (currentTime - turninState.lastCommandTime < turninState.commandDelay) then
            -- Still waiting
        else
            if turninState.phase == "targeting" then
                -- All members target the NPC simultaneously
                print("[GQT] All members targeting NPC...")
                for _, memberName in ipairs(groupMembers) do
                    if memberName == myName then
                        mq.cmdf('/target id %d', turninState.targetID)
                    else
                        mq.cmdf('/dex %s /target id %d', memberName, turninState.targetID)
                    end
                end
                turninState.phase = "picking"
                turninState.lastCommandTime = currentTime

            elseif turninState.phase == "picking" then
                -- All members pick up the item from bags simultaneously
                print("[GQT] All members picking up items...")
                for _, memberName in ipairs(groupMembers) do
                    if memberName == myName then
                        mq.cmdf('/itemnotify "${FindItem[=%s]}" leftmouseup', turninState.cursorItem)
                    else
                        mq.cmdf('/dex %s /itemnotify "${FindItem[=%s]}" leftmouseup', memberName, turninState.cursorItem)
                    end
                end
                turninState.phase = "clicking"
                turninState.lastCommandTime = currentTime

            elseif turninState.phase == "clicking" then
                -- All members set quantity and click target simultaneously
                print("[GQT] All members setting quantity and clicking target...")
                for _, memberName in ipairs(groupMembers) do
                    if memberName == myName then
                        mq.cmdf('/notify QuantityWnd QTYW_Slider newvalue %d', turninState.stackSize)
                        mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
                        mq.cmd('/click left target')
                    else
                        mq.cmdf('/dex %s /notify QuantityWnd QTYW_Slider newvalue %d', memberName, turninState.stackSize)
                        mq.cmdf('/dex %s /notify QuantityWnd QTYW_Accept_Button leftmouseup', memberName)
                        mq.cmdf('/dex %s /click left target', memberName)
                    end
                end
                turninState.phase = "giving"
                turninState.lastCommandTime = currentTime

            elseif turninState.phase == "giving" then
                -- All members click the give button simultaneously
                print("[GQT] All members clicking give button...")
                for _, memberName in ipairs(groupMembers) do
                    if memberName == myName then
                        mq.cmd('/notify GiveWnd GVW_Give_Button leftmouseup')
                    else
                        mq.cmdf('/dex %s /notify GiveWnd GVW_Give_Button leftmouseup', memberName)
                    end
                end

                -- Unpause boxr for all members
                print("[GQT] Turn in complete - unpausing all members")
                mq.cmd('/boxr unpause')  -- Driver unpause locally
                for _, memberName in ipairs(groupMembers) do
                    if memberName ~= myName then
                        mq.cmdf('/dex %s /boxr unpause', memberName)
                    end
                end

                turninState.active = false
                turninState.phase = "idle"
            end
        end
    end

    -- Process use item state machine
    if useItemState.active then
        local currentTime = os.clock() * 1000
        local myName = mq.TLO.Me.CleanName()

        -- Wait for delay between commands
        if useItemState.lastCommandTime > 0 and (currentTime - useItemState.lastCommandTime < useItemState.commandDelay) then
            -- Still waiting
        elseif useItemState.currentMember <= #groupMembers then
            local memberName = groupMembers[useItemState.currentMember]

            if useItemState.phase == "idle" then
                if memberName == myName then
                    mq.cmdf('/target id %d', useItemState.targetID)
                else
                    mq.cmdf('/dex %s /target id %d', memberName, useItemState.targetID)
                end
                useItemState.phase = "using"
                useItemState.lastCommandTime = currentTime
            elseif useItemState.phase == "using" then
                if memberName == myName then
                    mq.cmdf('/useitem "%s"', useItemState.itemName)
                else
                    mq.cmdf('/dex %s /useitem "%s"', memberName, useItemState.itemName)
                end
                useItemState.currentMember = useItemState.currentMember + 1
                useItemState.phase = "idle"
                useItemState.lastCommandTime = currentTime
            end
        else
            useItemState.active = false
            print("[GQT] Use item complete!")
        end
    end

    mq.delay(10)
end

print(string.format("\ay[\at%s\ay] \agStopped", SCRIPT_NAME))
