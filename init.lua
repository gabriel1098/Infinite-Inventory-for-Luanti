-- Infinite Inventory (v3)
-- Two-step transfers, like the real inventory:
--   1) click an item (in the bag OR in your inventory) to select it
--   2) click the destination slot (in the bag OR in your inventory)
-- Clicking the same slot again (or the X button) cancels the selection.

local storage = minetest.get_mod_storage()
local S = minetest.formspec_escape

infinite_inventory = {
	players = {},
	current_page = {},
	selected = {}
}

local SLOTS_PER_PAGE = 32
local MAX_PAGES = 100
local MAX_ITEMS_PER_STACK = 999999999
local COLS = 8
local INV_LIST = "main"
local FORMNAME = "infinite_inventory:bag"
local SELECT_COLOR = "#ffd700"

------------------------------------------------------------------
-- Data / persistence
------------------------------------------------------------------

local function empty_page()
	local page = {}
	for i = 1, SLOTS_PER_PAGE do
		page[i] = {name = "", count = 0}
	end
	return page
end

local function load_player_data(player_name)
	if not infinite_inventory.players[player_name] then
		local data
		local saved = storage:get_string(player_name)
		if saved ~= "" then
			data = minetest.deserialize(saved)
		end
		if type(data) ~= "table" or type(data[1]) ~= "table" then
			data = {[1] = empty_page()}
		end
		infinite_inventory.players[player_name] = data
	end
	infinite_inventory.current_page[player_name] =
		infinite_inventory.current_page[player_name] or 1
end

local function save_player_data(player_name)
	local data = infinite_inventory.players[player_name]
	if data then
		storage:set_string(player_name, minetest.serialize(data))
	end
end

------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------

local function msg(name, text)
	minetest.chat_send_player(name, "[Bag] " .. text)
end

local function is_empty_item(item)
	return (not item) or item.name == "" or item.count <= 0
end

-- Makes sure the page/slot exist and returns the slot
local function get_bag_slot(data, page, slot)
	if not data[page] then
		data[page] = empty_page()
	end
	if not data[page][slot] then
		data[page][slot] = {name = "", count = 0}
	end
	return data[page][slot]
end

-- Items with wear or metadata cannot be merged: the whole stack is stored
local function stack_has_meta(stack)
	return stack:get_wear() > 0 or
		next(stack:get_meta():to_table().fields) ~= nil
end

local function stack_to_bag_item(stack)
	local item = {name = stack:get_name(), count = stack:get_count()}
	if stack_has_meta(stack) then
		item.full = stack:to_string()
	end
	return item
end

local function clear_item(item)
	item.name = ""
	item.count = 0
	item.full = nil
end

-- Converts a bag item into ONE stack (nil if it exceeds the stack limit)
local function bag_item_to_single_stack(item)
	if item.full then
		return ItemStack(item.full)
	end
	if item.count > ItemStack(item.name):get_stack_max() then
		return nil
	end
	return ItemStack(item.name .. " " .. item.count)
end

------------------------------------------------------------------
-- Moves (return true, or nil + error message)
------------------------------------------------------------------

-- Inventory -> Bag
local function move_inv_to_bag(inv, idx, data, page, slot)
	local stack = inv:get_stack(INV_LIST, idx)
	if stack:is_empty() then
		return nil, "The selected slot is empty."
	end
	local dest = get_bag_slot(data, page, slot)

	if is_empty_item(dest) then
		data[page][slot] = stack_to_bag_item(stack)
		inv:set_stack(INV_LIST, idx, ItemStack())
		return true
	end

	if not dest.full and not stack_has_meta(stack)
			and dest.name == stack:get_name() then
		if dest.count + stack:get_count() > MAX_ITEMS_PER_STACK then
			return nil, "That bag slot is full."
		end
		dest.count = dest.count + stack:get_count()
		inv:set_stack(INV_LIST, idx, ItemStack())
		return true
	end

	-- Different items: swap places
	local new_stack = bag_item_to_single_stack(dest)
	if not new_stack then
		return nil, "The item in that bag slot exceeds the stack limit and does not fit in a swap. Choose an empty slot or one with the same item."
	end
	data[page][slot] = stack_to_bag_item(stack)
	inv:set_stack(INV_LIST, idx, new_stack)
	return true
end

-- Bag -> Inventory
local function move_bag_to_inv(inv, data, page, slot, idx)
	local item = get_bag_slot(data, page, slot)
	if is_empty_item(item) then
		return nil, "The selected bag slot is empty."
	end
	local dest = inv:get_stack(INV_LIST, idx)

	if dest:is_empty() then
		if item.full then
			inv:set_stack(INV_LIST, idx, ItemStack(item.full))
			clear_item(item)
		else
			local max = ItemStack(item.name):get_stack_max()
			local n = math.min(item.count, max)
			inv:set_stack(INV_LIST, idx, ItemStack(item.name .. " " .. n))
			item.count = item.count - n
			if item.count <= 0 then clear_item(item) end
		end
		return true
	end

	if not item.full and not stack_has_meta(dest)
			and dest:get_name() == item.name then
		local space = dest:get_stack_max() - dest:get_count()
		if space <= 0 then
			return nil, "That inventory slot is already full."
		end
		local n = math.min(space, item.count)
		dest:set_count(dest:get_count() + n)
		inv:set_stack(INV_LIST, idx, dest)
		item.count = item.count - n
		if item.count <= 0 then clear_item(item) end
		return true
	end

	-- Different items: swap places
	local new_stack = bag_item_to_single_stack(item)
	if not new_stack then
		return nil, "That bag item exceeds the stack limit and does not fit in a swap. Choose an empty slot or one with the same item."
	end
	data[page][slot] = stack_to_bag_item(dest)
	inv:set_stack(INV_LIST, idx, new_stack)
	return true
end

-- Bag -> Bag (including across pages)
local function move_bag_to_bag(data, pa, sa, pb, sb)
	local a = get_bag_slot(data, pa, sa)
	local b = get_bag_slot(data, pb, sb)
	if is_empty_item(a) then
		return nil, "The selected bag slot is empty."
	end

	if is_empty_item(b) then
		data[pb][sb] = a
		data[pa][sa] = {name = "", count = 0}
		return true
	end

	if not a.full and not b.full and a.name == b.name then
		local space = MAX_ITEMS_PER_STACK - b.count
		if space <= 0 then
			return nil, "That bag slot is full."
		end
		local n = math.min(space, a.count)
		b.count = b.count + n
		a.count = a.count - n
		if a.count <= 0 then clear_item(a) end
		return true
	end

	data[pa][sa], data[pb][sb] = b, a
	return true
end

-- Inventory -> Inventory (like the real inventory)
local function move_inv_to_inv(inv, a, b)
	local sa = inv:get_stack(INV_LIST, a)
	local sb = inv:get_stack(INV_LIST, b)
	if sa:is_empty() then
		return nil, "The selected slot is empty."
	end

	if sb:is_empty() then
		inv:set_stack(INV_LIST, b, sa)
		inv:set_stack(INV_LIST, a, ItemStack())
		return true
	end

	local before = sa:get_count()
	local leftover = sb:add_item(sa)
	if leftover:get_count() == before then
		-- Nothing was merged: swap places
		inv:set_stack(INV_LIST, a, sb)
		inv:set_stack(INV_LIST, b, sa)
	else
		inv:set_stack(INV_LIST, b, sb)
		inv:set_stack(INV_LIST, a, leftover)
	end
	return true
end

------------------------------------------------------------------
-- Selection
------------------------------------------------------------------

-- Returns the valid selection and a description of it (or nil if invalid)
local function get_selection(player, name)
	local sel = infinite_inventory.selected[name]
	if not sel then return nil end

	local desc
	if sel.kind == "inv" then
		local stack = player:get_inventory():get_stack(INV_LIST, sel.id)
		if not stack:is_empty() then
			desc = stack:get_name() .. " x" .. stack:get_count()
		end
	else
		local page = infinite_inventory.players[name][sel.page]
		local item = page and page[sel.id]
		if not is_empty_item(item) then
			desc = item.name .. " x" .. item.count
		end
	end

	if not desc then
		infinite_inventory.selected[name] = nil
		return nil
	end
	return sel, desc
end

------------------------------------------------------------------
-- Interface
------------------------------------------------------------------

local function show_infinite_inventory_formspec(player)
	local name = player:get_player_name()
	load_player_data(name)

	local page = infinite_inventory.current_page[name]
	local items = infinite_inventory.players[name][page]
	local inv = player:get_inventory()
	local inv_size = inv:get_size(INV_LIST)
	local inv_rows = math.ceil(inv_size / COLS)
	local height = 5.7 + inv_rows + 0.4

	local sel, desc = get_selection(player, name)

	local fs = {"size[9," .. height .. "]"}

	-- Highlight of the selected slot
	if sel then
		if sel.kind == "bag" and sel.page == page then
			fs[#fs + 1] = "style[slot_" .. sel.id .. ";bgcolor=" .. SELECT_COLOR .. "]"
		elseif sel.kind == "inv" then
			fs[#fs + 1] = "style[inv_" .. sel.id .. ";bgcolor=" .. SELECT_COLOR .. "]"
		end
	end

	fs[#fs + 1] = "label[1.3,0.2;Infinite Inventory - Page " .. page .. "]"
	fs[#fs + 1] = "button[0.2,0.2;0.8,0.6;prev_page;<]"
	fs[#fs + 1] = "button[8.0,0.2;0.8,0.6;next_page;>]"

	if sel then
		fs[#fs + 1] = "label[1.3,0.6;Selected: " .. S(desc) .. "]"
		fs[#fs + 1] = "button[7.0,0.2;0.9,0.6;clear_sel;X]"
	else
		fs[#fs + 1] = "label[1.3,0.6;Click an item to select it]"
	end

	-- Bag slots
	for y = 0, 3 do
		for x = 0, COLS - 1 do
			local slot_id = (y * COLS) + x + 1
			local item = items[slot_id] or {name = "", count = 0}
			local sx = 0.5 + x
			local sy = 1.0 + y

			if not is_empty_item(item) then
				fs[#fs + 1] = "item_image_button[" .. sx .. "," .. sy .. ";0.9,0.9;" ..
					S(item.name) .. ";slot_" .. slot_id .. ";]"
				fs[#fs + 1] = "label[" .. sx .. "," .. (sy + 0.6) .. ";" .. item.count .. "]"
			else
				fs[#fs + 1] = "button[" .. sx .. "," .. sy .. ";0.9,0.9;slot_" .. slot_id .. ";.]"
			end
		end
	end

	fs[#fs + 1] = "label[0.5,5.2;Select an item, then click the destination slot (bag or inventory)]"

	-- Player inventory slots (first row = hotbar)
	for i = 1, inv_size do
		local x = (i - 1) % COLS
		local y = math.floor((i - 1) / COLS)
		local sx = 0.5 + x
		local sy = 5.7 + y
		local stack = inv:get_stack(INV_LIST, i)

		if stack:is_empty() then
			fs[#fs + 1] = "button[" .. sx .. "," .. sy .. ";0.9,0.9;inv_" .. i .. ";.]"
		else
			fs[#fs + 1] = "item_image_button[" .. sx .. "," .. sy .. ";0.9,0.9;" ..
				S(stack:get_name()) .. ";inv_" .. i .. ";]"
			if stack:get_count() > 1 then
				fs[#fs + 1] = "label[" .. sx .. "," .. (sy + 0.6) .. ";" .. stack:get_count() .. "]"
			end
		end
	end

	minetest.show_formspec(name, FORMNAME, table.concat(fs))
end

------------------------------------------------------------------
-- Clicks
------------------------------------------------------------------

local function handle_click(player, name, kind, id)
	local inv = player:get_inventory()
	local data = infinite_inventory.players[name]
	local page = infinite_inventory.current_page[name]
	local sel = get_selection(player, name)

	-- Step 1: select
	if not sel then
		if kind == "bag" then
			if is_empty_item(get_bag_slot(data, page, id)) then
				msg(name, "Empty slot. Click an item first to select it.")
				return
			end
			infinite_inventory.selected[name] = {kind = "bag", page = page, id = id}
		else
			if inv:get_stack(INV_LIST, id):is_empty() then
				msg(name, "Empty slot. Click an item first to select it.")
				return
			end
			infinite_inventory.selected[name] = {kind = "inv", id = id}
		end
		return
	end

	-- Clicked the same slot again: cancel
	if sel.kind == kind and sel.id == id and (kind == "inv" or sel.page == page) then
		infinite_inventory.selected[name] = nil
		return
	end

	-- Step 2: move to the destination slot
	local ok, err
	if sel.kind == "inv" and kind == "bag" then
		ok, err = move_inv_to_bag(inv, sel.id, data, page, id)
	elseif sel.kind == "bag" and kind == "inv" then
		ok, err = move_bag_to_inv(inv, data, sel.page, sel.id, id)
	elseif sel.kind == "bag" and kind == "bag" then
		ok, err = move_bag_to_bag(data, sel.page, sel.id, page, id)
	else
		ok, err = move_inv_to_inv(inv, sel.id, id)
	end

	if ok then
		infinite_inventory.selected[name] = nil
		save_player_data(name)
	else
		msg(name, err or "Could not move the item.")
	end
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORMNAME then return end

	local name = player:get_player_name()
	load_player_data(name)
	local data = infinite_inventory.players[name]

	if fields.quit then
		infinite_inventory.selected[name] = nil
		return true
	end

	if fields.clear_sel then
		infinite_inventory.selected[name] = nil
		show_infinite_inventory_formspec(player)
		return true
	end

	if fields.prev_page then
		if infinite_inventory.current_page[name] > 1 then
			infinite_inventory.current_page[name] = infinite_inventory.current_page[name] - 1
		end
		show_infinite_inventory_formspec(player)
		return true
	end

	if fields.next_page then
		local nxt = infinite_inventory.current_page[name] + 1
		if nxt <= MAX_PAGES then
			if not data[nxt] then
				data[nxt] = empty_page()
			end
			infinite_inventory.current_page[name] = nxt
		end
		show_infinite_inventory_formspec(player)
		return true
	end

	for field_name in pairs(fields) do
		local kind, id
		if field_name:sub(1, 5) == "slot_" then
			kind = "bag"
			id = tonumber(field_name:sub(6))
		elseif field_name:sub(1, 4) == "inv_" then
			kind = "inv"
			id = tonumber(field_name:sub(5))
		end

		if kind then
			-- Validate the field sent by the client
			local limit = (kind == "bag") and SLOTS_PER_PAGE
				or player:get_inventory():get_size(INV_LIST)
			if not id or id % 1 ~= 0 or id < 1 or id > limit then
				return true
			end

			handle_click(player, name, kind, id)
			show_infinite_inventory_formspec(player)
			return true
		end
	end
end)

------------------------------------------------------------------
-- Command, join/leave, shutdown
------------------------------------------------------------------

minetest.register_chatcommand("bag", {
	description = "Opens your private infinite inventory backpack",
	func = function(name)
		local player = minetest.get_player_by_name(name)
		if player then
			infinite_inventory.selected[name] = nil
			show_infinite_inventory_formspec(player)
		end
	end
})

minetest.register_on_joinplayer(function(player)
	load_player_data(player:get_player_name())
end)

minetest.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	save_player_data(name)
	infinite_inventory.players[name] = nil
	infinite_inventory.current_page[name] = nil
	infinite_inventory.selected[name] = nil
end)

minetest.register_on_shutdown(function()
	for name in pairs(infinite_inventory.players) do
		save_player_data(name)
	end
end)
