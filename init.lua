-- Initializes permanent storage on the world disk
local storage = minetest.get_mod_storage()

infinite_inventory = {
    players = {},
    current_page = {}
}

local SLOTS_PER_PAGE = 32
local MAX_ITEMS_PER_STACK = 999999999

-- Loads player data privately
local function load_player_data(player_name)
    if not infinite_inventory.players[player_name] then
        local saved_string = storage:get_string(player_name)
        if saved_string and saved_string ~= "" then
            infinite_inventory.players[player_name] = minetest.deserialize(saved_string)
        else
            infinite_inventory.players[player_name] = {
                [1] = {}
            }
            for i = 1, SLOTS_PER_PAGE do
                infinite_inventory.players[player_name][1][i] = {name = "", count = 0}
            end
        end
        infinite_inventory.current_page[player_name] = 1
    end
end

-- Saves player data privately to the server disk
local function save_player_data(player_name)
    if infinite_inventory.players[player_name] then
        local to_save = minetest.serialize(infinite_inventory.players[player_name])
        storage:set_string(player_name, to_save)
    end
end

-- Renders the private backpack interface
local function show_infinite_inventory_formspec(player)
    local name = player:get_player_name()
    load_player_data(name)
    
    local page = infinite_inventory.current_page[name]
    local items = infinite_inventory.players[name][page]
    
    local formspec = "size[9,10]" ..
                     "label[3.5,0.2; Infinite Inventory - Page " .. page .. "]"
    
    formspec = formspec .. "button[0.2,0.2;0.8,0.6;prev_page;<]"
    formspec = formspec .. "button[8.0,0.2;0.8,0.6;next_page;>]"
    
    for y = 0, 3 do
        for x = 0, 7 do
            local slot_id = (y * 8) + x + 1
            local item = items[slot_id] or {name = "", count = 0}
            
            local slot_x = 0.5 + (x * 1.0)
            local slot_y = 1.0 + (y * 1.0)
            
            if item.name ~= "" and item.count > 0 then
                formspec = formspec .. "item_image_button[" .. slot_x .. "," .. slot_y .. ";0.9,0.9;" .. item.name .. ";slot_" .. slot_id .. ";]"
                formspec = formspec .. "label[" .. slot_x .. "," .. (slot_y + 0.6) .. ";" .. item.count .. "]"
            else
                formspec = formspec .. "button[" .. slot_x .. "," .. slot_y .. ";0.9,0.9;slot_" .. slot_id .. ";.]"
            end
        end
    end
    
    formspec = formspec .. "label[0.5,5.2;Item in hand + click empty slot above to store | Click item to withdraw]"
    formspec = formspec .. "list[current_player;main;0.5,5.7;8,4;]"
    formspec = formspec .. "listring[current_player;main]"
    
    minetest.show_formspec(name, "infinite_inventory:bag", formspec)
end

-- CHAT COMMAND TO OPEN THE BACKPACK
minetest.register_chatcommand("bag", {
    description = "Opens your private infinite inventory backpack",
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if player then 
            show_infinite_inventory_formspec(player) 
        end
    end
})

minetest.register_on_joinplayer(function(player)
    load_player_data(player:get_player_name())
end)

minetest.register_on_leaveplayer(function(player)
    save_player_data(player:get_player_name())
end)

-- Processes button clicks and private slots
minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "infinite_inventory:bag" then return end
    local name = player:get_player_name()
    
    if fields.prev_page then
        if infinite_inventory.current_page[name] > 1 then
            infinite_inventory.current_page[name] = infinite_inventory.current_page[name] - 1
            show_infinite_inventory_formspec(player)
        end
        return true
    end
    
    if fields.next_page then
        local current = infinite_inventory.current_page[name]
        infinite_inventory.current_page[name] = current + 1
        if not infinite_inventory.players[name][current + 1] then
            infinite_inventory.players[name][current + 1] = {}
            for i = 1, SLOTS_PER_PAGE do
                infinite_inventory.players[name][current + 1][i] = {name = "", count = 0}
            end
        end
        show_infinite_inventory_formspec(player)
        return true
    end
    
    for field_name, _ in pairs(fields) do
        if string.sub(field_name, 1, 5) == "slot_" then
            local slot_id = tonumber(string.sub(field_name, 6))
            local page = infinite_inventory.current_page[name]
            local clicked_item = infinite_inventory.players[name][page][slot_id]
            
            -- WITHDRAW ITEM (Click on occupied slot)
            if clicked_item and clicked_item.name ~= "" and clicked_item.count > 0 then
                local player_inv = player:get_inventory()
                local temp_stack = ItemStack(clicked_item.name)
                local fit_count = math.min(clicked_item.count, temp_stack:get_stack_max())
                
                local to_give = ItemStack(clicked_item.name .. " " .. fit_count)
                if player_inv:room_for_item("main", to_give) then
                    player_inv:add_item("main", to_give)
                    clicked_item.count = clicked_item.count - fit_count
                    if clicked_item.count <= 0 then
                        clicked_item.name = ""
                        clicked_item.count = 0
                    end
                    save_player_data(name)
                end
            else
                -- STORE ITEM (Click on empty slot)
                local wielded = player:get_wielded_item()
                if not wielded:is_empty() then
                    local w_name = wielded:get_name()
                    local w_count = wielded:get_count()
                    
                    -- Stack Merging Intelligence: Checks if item exists on current page to merge
                    local merged = false
                    for i = 1, SLOTS_PER_PAGE do
                        local check_item = infinite_inventory.players[name][page][i]
                        if check_item and check_item.name == w_name and (check_item.count + w_count) <= MAX_ITEMS_PER_STACK then
                            check_item.count = check_item.count + w_count
                            merged = true
                            break
                        end
                    end
                    
                    -- If the item didn't exist on this page, save it to the clicked empty slot
                    if not merged then
                        infinite_inventory.players[name][page][slot_id] = {
                            name = w_name,
                            count = w_count
                        }
                    end
                    
                    wielded:clear()
                    player:set_wielded_item(wielded)
                    save_player_data(name)
                end
            end
            
            show_infinite_inventory_formspec(player)
            return true
        end
    end
end)
