-- Constants

local CHAN_PREFIX_BROADCAST = "BCAST_BROADCAST"
local MAX_MESSAGE_LENGTH = 255 - #CHAN_PREFIX_BROADCAST - 1
local BROADCAST_TYPE = {
    TARGET = "t"
}
local REFRESH_LOOP_DELAY_SEC = 1
local MAX_BROADCASTS = 3
local ITEM_HEIGHT = 50
local ITEM_WIDTH = 100
local UNIT_CLASS = {
    NONE = 0,
    WARRIOR = 1,
    PALADIN = 2,
    HUNTER = 3,
    ROGUE = 4,
    PRIEST = 5,
    SHAMAN = 7,
    MAGE = 8,
    WARLOCK = 9,
    DRUID = 11
}
local UNIT_TYPE = {
    PLAYER = "p",
    NPC = "n"
}
-- separator to send multiple values in a channel. Must not be seen in unit names, also must not be a special char for string:gmatch
local MSG_SEP = "@"
local EMPTY_SLOT = "__EMPTY__"

-- File-scope globals

local handlers = {}
local errcolor = "|cffff5555"
Bcast_Broadcasts = {}
-- lua tables cannot handle nil values so we use EMPTY_SLOT as "empty"
-- value
for i = 1,MAX_BROADCASTS do 
    -- Bcast_Broadcasts is a saved variable (@todo only in dev)
    -- so we check for nil before initializing
    if nil == Bcast_Broadcasts[i] then
        Bcast_Broadcasts[i] = EMPTY_SLOT 
    end
end
local bcast_buttons = {}

-- Helpers

local function printerr(text)
    print(errcolor .. text)
end

local function ioinspect(val, label)
    prefix = (label == nil) and "" or (label .. ":  ")
    print(prefix .. tostring(val))
end

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
        print(formatting .. v)
      end
    end
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

-- Broadcast

local Broadcast = {}
Broadcast.__index = Broadcast


function Broadcast.create(type, unit_type, unit_guid, unit_name)
    local bcast = {}
    setmetatable(bcast,  Broadcast)
    bcast.type = type
    bcast.unit_type = unit_type
    bcast.unit_guid = unit_guid
    bcast.unit_name = unit_name
    bcast.time_at = 0
    return bcast
end

function Broadcast.from_message(msg)
    return Broadcast.create(unpack(unserialize_message(msg)))
end

function Broadcast:set_time(t)
    self.time_at = t
end

function Broadcast:to_message()
    return serialize_message(self:to_list())
end

function Broadcast:__tostring()
    print(Broadcast.to_values(self))
    return string.format("#Broadcast<%s, %s, unit_guid: %s, unit_name=\"%s\">", Broadcast.to_values(self))
end

function Broadcast:to_values()
    return self.type, self.unit_type, self.unit_guid, self.unit_name
end

function Broadcast:to_list()
    return {self:to_values()}
end

-- Broadcasts List

local function push_broadcast(bcast) 
    -- before appending the broadcast we will remove the last broadcast 
    -- from the end
    table.remove(Bcast_Broadcasts) -- no position: remove last elem
    -- the we insert at the beginning on the table
    table.insert(Bcast_Broadcasts, 1, bcast)
end

-- Interface

local function create_item_buttons()
    for i = 1, MAX_BROADCASTS do
        local bt = CreateFrame("Button", nil, Bcast_Frame, "SecureActionButtonTemplate")
        if 1 == i then
            bt:SetPoint("TOP", Bcast_Frame, 100, -20)
        else
            bt:SetPoint("TOP", bcast_buttons[i-1], "BOTTOM", 0, -3)
        end
        bt:SetNormalFontObject("GameFontWhiteSmall")
        bt:SetFrameStrata("HIGH")
        bt:SetText(" Initializing ... ")
        bt:EnableMouse(true)
        bt:RegisterForClicks("AnyUp")
        bt:SetAttribute("type", "macro")
        bt:SetWidth(ITEM_WIDTH)
        bt:SetHeight(ITEM_HEIGHT)
        -- @todo hide by default when ok
        -- bt:Hide()
        bt:Show()
        bcast_buttons[i] = bt
        print(tostring(bt))
    end
end

local function update_item_buttons()
    for i = 1, MAX_BROADCASTS do
        local bcast = Bcast_Broadcasts[i]
        local bt = bcast_buttons[i]
       if EMPTY_SLOT == bcast then
            bt:Hide()
        else
            bt:SetText(bcast.unit_name)
            bt:SetAttribute("macrotext", "/targetexact " .. bcast.unit_name)
            bt:Show()
        end
    end
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
	for k, v in pairs(handlers) do
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
        local broadcast_type = "target"
        -- we will save in the broadcast wether the unit is a player
        -- or not.
        local player_or_npc = UnitPlayerControlled("target") and "p" or "n"
        -- in the same way, we will add the class and the name of the
        -- unit so we can show them for clients that have not
        -- seen the unit yet (and cannot query infos by guid)
        local _, _, unit_class_index = UnitClass("target")
        local bcast = Broadcast.create(BROADCAST_TYPE.TARGET, player_or_npc, guid, name)
        local msgpack = bcast:to_message()
        print("Broadcasting " .. name)
        print("msgpack " .. tostring(msgpack))
        
        C_ChatInfo.SendAddonMessage(CHAN_PREFIX_BROADCAST, msgpack, "PARTY")
        print("Broadcasted " .. name)
    end)
    if err ~= nil then
        printerr(tostring(err))
    end
end

function handlers:PLAYER_ENTERING_WORLD(...)
    -- restore state from saved variables
    update_item_buttons()
    print("Bcast initialized")
    tprint(Bcast_Broadcasts)
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
        tprint(Bcast_Broadcasts)
    end)
    if err ~= nil then
        printerr(tostring(err))
    end
end










