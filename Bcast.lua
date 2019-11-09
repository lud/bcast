-- Constants

local VERSION = 1
local ERRCOLOR = "|cffff5555"
local CHAN_PREFIX_BROADCAST = "BCAST_BROADCAST"
local MAX_MESSAGE_LENGTH = 255 - #CHAN_PREFIX_BROADCAST - 1
local BROADCAST_TYPE = {
    TARGET = "t"
}
local REFRESH_LOOP_DELAY_SEC = 1
local MAX_BROADCASTS = 3
local ITEM_HEIGHT = 50
local ITEM_WIDTH = 100
local UNIT_CLASSES = {
     "WARRIOR",
     "PALADIN",
     "HUNTER",
     "ROGUE",
     "PRIEST",
     "SHAMAN",
     "MAGE",
     "WARLOCK",
     "DRUID", 
}

local UNIT_TYPE_NPC = "n"
local UNIT_TYPE_PLAYER = "p"

-- separator to send multiple values in a channel. Must not be seen in
-- unit names, also must not be a special char for string:gmatch
local MSG_SEP = "@"
local EMPTY_SLOT = "__EMPTY__"

-- Helpers

-- Print contents of `tbl`, with indentation.
-- `indent` sets the initial level of indentation.
local function tprint (tbl, indent)
    if not indent then indent = 0 end
    local ws = string.rep("    ", indent)
    print(ws .. "(table)")
    for k, v in pairs(tbl) do
        local formatting = ws .. k .. ": "
        if type(v) == "table" then
            print(formatting)
            tprint(v, indent+1)
        elseif type(v) == 'boolean' then
            print(formatting .. tostring(v))
        else
            print(formatting, tostring(v))
        end
    end
end


local function printerr(text)
    print(ERRCOLOR .. text)
end

local function ioinspect(val, label)
    local prefix = (label == nil) and "" or (label .. ":  ")
    print(prefix .. tostring(val))
end


local function str_split(str, sep)
    -- we add the separator at the end of the string
    str = str .. sep
    -- and now we will capture and return any character group that is
    -- preceding the separator
    -- the "-" means non-greedy, so we stop the current group as soon
    -- as we see the separator
    local parts = {}
    local pattern = "(.-)" .. sep
    print("pattern", pattern)
    for v in string.gmatch(str, pattern)
        do table.insert(parts, v) end
    return parts
end

-- File-scope globals

local handlers = {}
Bcast_Broadcasts = {}
local broadcasts_store = {}
-- Init store to MAX_BROADCASTS
-- lua tables cannot handle nil values so we use EMPTY_SLOT as "empty"
-- value
for i = 1,MAX_BROADCASTS do
    broadcasts_store[i] = EMPTY_SLOT
end
local bcast_buttons = {}

-- Fonts

local base_font = CreateFont("Bcast_ItemFont")
local class_fonts = {}
base_font:CopyFontObject("GameFontNormal")
base_font:SetJustifyH("LEFT")

local function class_rgb(unit_class)
    local color = RAID_CLASS_COLORS[unit_class]
    return color.r, color.g, color.b
end

for _,class in ipairs(UNIT_CLASSES) do
    print("define font for " .. class)
    local font = CreateFont("Bcast_itemFont_" .. class)
    font:CopyFontObject(base_font)
    font:SetTextColor(class_rgb(class))
    class_fonts[class] = font
end

ioinspect(class_fonts.HUNTER, "hunt font")

-- Class Icons

local function create_class_icon(parent)
    local icon = parent:CreateTexture(nil, "ARTWORK")
    -- texture is a sprite with all icons
    icon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
    return icon
end

local function set_class_icon_class(icon, class)
    local coords = CLASS_ICON_TCOORDS[class]
    icon:SetTexCoord(unpack(coords))
    return icon
end

-- Messaging

local function serialize_message(values)
    local msg = table.concat(values, MSG_SEP)
    -- message length must be at most 255 - CHAN_PREFIX_BROADCAST - 1
    -- because total message will be CHAN_PREFIX_BROADCAST + "\t" + message
    -- and if it is longer than 255 chars, client will disconnect
    -- In this case, we will just truncate the message, as the last
    -- part is the unitname and we will try to target by guid
    -- @todo we need a way to restore the actual name of the unit
    if #msg > MAX_MESSAGE_LENGTH then
        msg = msg:sub(1, MAX_MESSAGE_LENGTH)
    end
    return msg
end

local function unserialize_message(msg)
    return str_split(msg, MSG_SEP)
end

-- Out of combat callbacks

-- When we are in combat, we cannot update buttons. We will then store a
-- function in a table to be executed when not in combat anymore. We will even
-- use this function for the setup of buttons because you could spawn in the
-- world just onto a mob and the setup of the UI would be messed up

-- Callbacks will be put in the table associated to a key, so if we push
-- multiple functions for the same key, only the last one will be executed. This
-- avoids tu update the buttons 2 or more times in a row for no reason.

local OOC = {fns = {}, size = 0}

-- push will simply add a function to be run later
function OOC:push(key, fn)
    if self.fns[key] ~= nil then
        self.size = self.size + 1
    end
    self.fns[key] = fn
end

-- run will attempt to run a function if not in combat, or push it
-- to be run later
function OOC:run(key, fn)
    if InCombatLockdown() then
        self:push(key, fn)
        print("postponed execution of " .. key)
        -- here we should call resume() to create a new loop waiting to run
        -- functions when OOC, but multiple calls woud end up with many loops
        -- using the timer API. So we rely on the PLAYER_REGEN_ENABLED and
        -- PLAYER_ENTERING_WORLD events to call resume()
    else
        print("direct execution of " .. key)
        self:_run(fn)
    end
end

-- In resume we will attempt to run all the stored functions if not in combat.
-- If we are still in combat we will postpone the execution. If many events call
-- resume() while in combat, we will have multiple postmoning loops running
-- "concurrently". This is not a problem since the first loop calling resume()
-- again OOC will execute all the functions and the other loops will execute
-- nothing. In order to avoid looping again if the table is empty we will check
-- that before.
function OOC:resume()
    print("resuming " .. tostring(self.size) .. " functions")
    if self.size == 0 then
        return
    end
    if InCombatLockdown() then
        -- duration is in seconds
        C_Timer.After(0.1, function() OOC:resume() end)
        return
    end
    -- we can execute all the functions
    for k,fn in pairs(self.fns) do
       print("running " .. k)
       self:_run(fn)
       self.fns[k] = nil
       self.size = self.size - 1
    end
end


-- Here we just execute the function, but as we can run in delayed mode, the
-- initial calling scope cannot catch any error, so we catch errors and print
-- them
function OOC:_run(fn)
    local status, err = pcall(fn)
    if not status then
        printerr(tostring(err))
    end
end

-- Broadcast

local Broadcast = {}
Broadcast.__index = Broadcast


function Broadcast.create(type, unit_type, unit_guid, unit_class, unit_name)
    local bcast = {version = VERSION}
    setmetatable(bcast,  Broadcast)
    bcast.type = type
    bcast.unit_type = unit_type
    bcast.unit_guid = unit_guid
    bcast.unit_name = unit_name
    bcast.unit_class = unit_class
    bcast.time_at = 0
    return bcast
end

function Broadcast.from_message(msg)
    return Broadcast.create(unpack(unserialize_message(msg)))
end

function Broadcast:set_time(t)
    self.time_at = t
end

function Broadcast:is_player()
    return self.unit_type == UNIT_TYPE_PLAYER
end

function Broadcast:to_message()
    return serialize_message(self:to_list())
end

function Broadcast:__tostring()
    print(Broadcast.to_values(self))
    return string.format("#Broadcast<%s, %s, unit_guid: %s, unit_class=%s unit_name=\"%s\">", Broadcast.to_values(self))
end

function Broadcast:to_values()
    return self.type, self.unit_type, self.unit_guid, self.unit_class, self.unit_name
end

function Broadcast:to_list()
    return {self:to_values()}
end

-- Broadcasts List

local function push_broadcast(bcast)
    -- before appending the broadcast we will remove the last broadcast
    -- from the end
    table.remove(broadcasts_store) -- no position: remove last elem
    -- the we insert at the beginning on the table
    table.insert(broadcasts_store, 1, bcast)
end

-- Interface

local function create_item_buttons()
    OOC:run("create_item_buttons", function()
        for i = 1, MAX_BROADCASTS do
            local bt = CreateFrame("Button", nil, Bcast_Frame, "SecureActionButtonTemplate")
            if 1 == i then
                bt:SetPoint("TOP", Bcast_Frame, 100, -20)
            else
                bt:SetPoint("TOP", bcast_buttons[i-1], "BOTTOM", 0, -3)
            end
            bt:SetNormalFontObject(base_font)
            bt:SetFrameStrata("HIGH")
            bt:SetText(" Initializing ... ")
            bt:EnableMouse(true)
            bt:RegisterForClicks("AnyUp")
            bt:SetAttribute("type", "macro")
            bt:SetWidth(ITEM_WIDTH)
            bt:SetHeight(ITEM_HEIGHT)
            -- create the class icon
            local class_icon = create_class_icon(bt)
            class_icon:SetPoint("LEFT", bt, "LEFT", -5, 0)
            class_icon:SetHeight(10)
            class_icon:SetWidth(10)
            bt.class_icon = class_icon
            -- @todo hide by default when ok
            -- bt:Hide()
            bt:Show()
            bcast_buttons[i] = bt
            print(tostring(bt))
        end
    end)
end

local function update_item_buttons()
    OOC:run("update_item_buttons", function()     
        for i = 1, MAX_BROADCASTS do
            local bcast = broadcasts_store[i]
            local bt = bcast_buttons[i]
            if EMPTY_SLOT == bcast then
                -- bt:Hide()
            else
                tprint(bcast)
                print("bcast", tostring(bcast))
                print("bcast.unit_name", tostring(bcast.unit_name))
                print("bcast:to_message()", tostring(bcast:to_message()))
                print("bcast:is_player", tostring(bcast.is_player))
                bt:SetText(bcast.unit_name)
                if bcast:is_player() then
                    print("bcast.unit_class", bcast.unit_class)
                    bt:SetNormalFontObject(class_fonts[bcast.unit_class])
                    set_class_icon_class(bt.class_icon, bcast.unit_class)
                    bt.class_icon:Show()
                else
                    bt.class_icon:Hide()
                    bt:SetNormalFontObject(base_font)
                end
                    bt:SetAttribute("macrotext", "/targetexact " .. bcast.unit_name)
                bt:Show()
            end
        end
    end)
end

-- Refresh loop

local function refresh_loop(duration)
    C_Timer.After(duration, function()
        refresh_loop(duration)
        -- print(type(Bcast_Frame))
    end)
end

-- Init
function Bcast_OnLoad()
	for k, _ in pairs(handlers) do
		Bcast_Frame:RegisterEvent(k)
    end

    create_item_buttons()
    refresh_loop(REFRESH_LOOP_DELAY_SEC)
end

function Bcast_OnEvent(self, event, ...)
	handlers[event](self, event, ...)
end

function Bcast_BroadcastTarget()
    local status, err = pcall(function()
        local name, _ = UnitName("target")
        if nil == name then
            printerr("Cannot broadcast: no target")
            return
        end
        local guid = UnitGUID("target")
        -- create a packet for broadcasting data
        -- <broadcast_type>:<player/npc>:<guid>:<class>:<name>
        -- we will save in the broadcast wether the unit is a player
        -- or not.
        local player_or_npc = UnitPlayerControlled("target") and UNIT_TYPE_PLAYER or UNIT_TYPE_NPC
        -- in the same way, we will add the class and the name of the
        -- unit so we can show them for clients that have not
        -- seen the unit yet (and cannot query infos by guid)
        local pclass
        if UNIT_TYPE_PLAYER == player_or_npc then
            _, pclass = UnitClass("target")
        else
            pclass = 0
        end
        local bcast = Broadcast.create(BROADCAST_TYPE.TARGET, player_or_npc, guid, pclass, name)
        local msgpack = bcast:to_message()
        print("Broadcasting " .. name)
        print("msgpack " .. tostring(msgpack))

        C_ChatInfo.SendAddonMessage(CHAN_PREFIX_BROADCAST, msgpack, "PARTY")
        print("Broadcasted " .. name)
    end)
    if not status then
        printerr(tostring(err))
    end
end

function handlers:PLAYER_ENTERING_WORLD()
    -- restore state from saved variables
    tprint(broadcasts_store)
    update_item_buttons()
    print("Bcast initialized")
    -- tprint(broadcasts_store)
    OOC:resume()
end

function handlers:CHAT_MSG_ADDON(event, prefix, text, channel,sender,target,zoneChannelID,localID,name,instanceID)
    if prefix ~= CHAN_PREFIX_BROADCAST then
        return
    end
    local status, err = pcall(function()
        print("received message = " .. text)

        local bcast = Broadcast.from_message(text)
        bcast:set_time(time())
        ioinspect(bcast, "broadcast")
        push_broadcast(bcast)
        update_item_buttons()
        -- if starts_with(text, TARGET_PREFIX) then
        --     print("Add broadcast for target '" .. extract_target(text) .. "'")
        -- end
        ioinspect(prefix, "prefix")
        ioinspect(text, "text")
        ioinspect(channel, "channel")
        -- tprint(broadcasts_store)
    end)
    if not status then
        printerr(tostring(err))
    end
end

function handlers:PLAYER_REGEN_ENABLED()
    OOC:resume()
end