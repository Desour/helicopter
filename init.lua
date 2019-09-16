
--
-- helpers and co.
--

if not minetest.global_exists("matrix3") then
	dofile(minetest.get_modpath("helicopter") .. DIR_DELIM .. "matrix.lua")
end

local creative_exists = minetest.global_exists("creative")
local gravity = tonumber(minetest.settings:get("movement_gravity")) or 9.8
local vector_up = vector.new(0, 1, 0)
local vector_forward = vector.new(0, 0, 1)

local function vector_length_sq(v)
	return v.x * v.x + v.y * v.y + v.z * v.z
end

local function heli_control(self, dtime, touching_ground, vel_before)
	local driver = minetest.get_player_by_name(self.driver_name)
	if not driver then
		-- there is no driver (eg. because driver left)
		self.driver_name = nil
		if self.sound_handle then
			minetest.sound_stop(self.sound_handle)
			self.sound_handle = nil
		end
		self.object:set_animation_frame_speed(0)
		-- gravity
		self.object:set_acceleration(vector.multiply(vector_up, -gravity))
		return
	end

	local ctrl = driver:get_player_control()
	local rot = self.object:get_rotation()

	local vert_vel_goal = 0
	if ctrl.jump then
		vert_vel_goal = vert_vel_goal + 3.5
	end
	if ctrl.sneak then
		vert_vel_goal = vert_vel_goal - 3.5
	end

	-- rotation
	if not touching_ground then
		local tilting_goal = vector.new()
		if ctrl.up then
			tilting_goal.z = tilting_goal.z + 1
		end
		if ctrl.down then
			tilting_goal.z = tilting_goal.z - 1
		end
		if ctrl.right then
			tilting_goal.x = tilting_goal.x + 1
		end
		if ctrl.left then
			tilting_goal.x = tilting_goal.x - 1
		end
		tilting_goal = vector.multiply(vector.normalize(tilting_goal), 0.5)

		-- tilting
		local tilting_current = self.tilting
		if vector_length_sq(vector.subtract(tilting_goal, tilting_current)) > dtime * dtime then
			tilting_current = vector.add(tilting_current,
					vector.multiply(vector.direction(tilting_current, tilting_goal), dtime))
		else
			tilting_current = tilting_goal
		end
		if vector_length_sq(tilting_current) > 1 then
			tilting_current = vector.normalize(tilting_current)
		end
		self.tilting = tilting_current
		local new_up = vector.new(tilting_current)
		new_up.y = 1
		new_up = vector.normalize(new_up) -- this is what vector_up should be after the rotation
		local new_right = vector.cross(new_up, vector_forward)
		local new_forward = vector.cross(new_right, new_up)
		local rot_mat = matrix3.new(
			new_right.x, new_up.x, new_forward.x,
			new_right.y, new_up.y, new_forward.y,
			new_right.z, new_up.z, new_forward.z
		)
		rot = matrix3.to_pitch_yaw_roll(rot_mat)

		rot.y = driver:get_look_horizontal()

	else
		rot.x = 0
		rot.z = 0
	end

	self.object:set_rotation(rot)


	local power = vert_vel_goal - vel_before.y + gravity * dtime
	local rotated_up = matrix3.multiply(matrix3.from_pitch_yaw_roll(rot), vector_up)
	local added_vel = vector.multiply(rotated_up, power)
	added_vel = vector.add(added_vel, vector.multiply(vector_up, -gravity * dtime))
	return vector.add(vel_before, added_vel)
end

--
-- entity
--

minetest.register_entity("helicopter:heli", {
	initial_properties = {
		physical = true,
		collide_with_objects = true,
		collisionbox = {-1,0,-1, 1,0.3,1},
		selectionbox = {-1,0,-1, 1,0.3,1},
		visual = "mesh",
		mesh = "helicopter_heli.x",
		textures = {"helicopter_blades.png", "helicopter_blades.png",
				"helicopter_heli.png", "helicopter_glass.png"},
	},

	driver_name = nil,
	sound_handle = nil,
	tilting = vector.new(),

	on_activate = function(self)
		-- set the animation once and later only change the speed
		self.object:set_animation({x = 0, y = 11}, 0, 0, true)

		self.object:set_armor_groups({immortal=1})

		self.object:set_acceleration(vector.multiply(vector_up, -gravity))
	end,

	on_step = function(self, dtime)
		local pos_below = self.object:get_pos()
		pos_below.y = pos_below.y - 0.1
		local node_below = minetest.get_node(pos_below).name
		local nodedef = minetest.registered_nodes[node_below]
		local touching_ground = not nodedef or -- unknown nodes are solid
				nodedef.walkable

		local vel = self.object:get_velocity()
		if self.driver_name then
			vel = heli_control(self, dtime, touching_ground, vel) or vel
		end

		-- quadratic and constant deceleration
		local speedsq = vector_length_sq(vel)
		vel = vector.apply(vel, function(a)
			local s = math.sign(a)
			a = math.abs(a)
			if not touching_ground then
				a = math.max(0, a - 0.01 * dtime * speedsq - 0.2 * dtime)
			else
				a = math.max(0, a - 1 * dtime * speedsq - 2 * dtime)
			end
			return a * s
		end)

		self.object:set_velocity(vel)
	end,

	on_punch = function(self, puncher)
		if not puncher or not puncher:is_player() then
			return
		end
		local name = puncher:get_player_name()
		if self.driver_name and self.driver_name ~= name then
			-- do not allow other players to remove the object while there is a driver
			return
		end

		if self.sound_handle then
			minetest.sound_stop(self.sound_handle)
			self.sound_handle = nil
		end
		if self.driver_name then
			-- detach the driver first (puncher must be driver)
			puncher:set_detach()
			player_api.player_attached[name] = nil
			-- player should stand again
			player_api.set_animation(puncher, "stand")
			self.driver_name = nil
		end

		self.object:remove()

		minetest.handle_node_drops(self.object:get_pos(), {"helicopter:heli"}, puncher)
	end,

	on_rightclick = function(self, clicker)
		if not clicker or not clicker:is_player() then
			return
		end

		local name = clicker:get_player_name()

		if name == self.driver_name then
			-- driver clicked the object => driver gets off the vehicle
			self.driver_name = nil
			-- sound and animation
			minetest.sound_stop(self.sound_handle)
			self.sound_handle = nil
			self.object:set_animation_frame_speed(0)
			-- detach the player
			clicker:set_detach()
			player_api.player_attached[name] = nil
			-- player should stand again
			player_api.set_animation(clicker, "stand")
			-- gravity
			self.object:set_acceleration(vector.multiply(vector_up, -gravity))

		elseif not self.driver_name then
			-- no driver => clicker is new driver
			self.driver_name = name
			-- sound and animation
			self.sound_handle = minetest.sound_play({name = "helicopter_motor"},
					{object = self.object, gain = 2.0, max_hear_distance = 32, loop = true,})
			self.object:set_animation_frame_speed(30)
			-- attach the driver
			clicker:set_attach(self.object, "", {x = 0, y = 6.7, z = -4}, {x = 0, y = 0, z = 0})
			player_api.player_attached[name] = true
			-- make the driver sit
			minetest.after(0.2, function()
				local player = minetest.get_player_by_name(name)
				if player then
					player_api.set_animation(player, "sit")
				end
			end)
			-- disable gravity
			self.object:set_acceleration(vector.new())
		end
	end,
})


--
-- items
--

-- blades
minetest.register_craftitem("helicopter:blades",{
	description = "Helicopter Blades",
	inventory_image = "helicopter_blades_inv.png",
})
-- cabin
minetest.register_craftitem("helicopter:cabin",{
	description = "Cabin for Helicopter",
	inventory_image = "helicopter_cabin_inv.png",
})
-- heli
minetest.register_craftitem("helicopter:heli", {
	description = "Helicopter",
	inventory_image = "helicopter_heli_inv.png",

	on_place = function(itemstack, placer, pointed_thing)
		if pointed_thing.type ~= "node" then
			return
		end
		if minetest.get_node(pointed_thing.above).name ~= "air" then
			return
		end
		minetest.add_entity(pointed_thing.above, "helicopter:heli")
		if not (creative_exists and placer and
				creative.is_enabled_for(placer:get_player_name())) then
			itemstack:take_item()
		end
		return itemstack
	end,
})

--
-- crafting
--

if minetest.get_modpath("default") then
	minetest.register_craft({
		output = "helicopter:blades",
		recipe = {
			{"",                    "default:steel_ingot", ""},
			{"default:steel_ingot", "group:stick",         "default:steel_ingot"},
			{"",                    "default:steel_ingot", ""},
		}
	})
	minetest.register_craft({
		output = "helicopter:cabin",
		recipe = {
			{"",           "group:wood",           ""},
			{"group:wood", "default:mese_crystal", "default:glass"},
			{"group:wood", "group:wood",           "group:wood"},
		}
	})
	minetest.register_craft({
		output = "helicopter:heli",
		recipe = {
			{"",                  "helicopter:blades"},
			{"helicopter:blades", "helicopter:cabin"},
		}
	})
end
