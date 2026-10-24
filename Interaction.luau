local players = game:GetService("Players")
local replicatedStorage = game:GetService("ReplicatedStorage")
local userInputService = game:GetService("UserInputService")
local runService = game:GetService("RunService")
local collectionService = game:GetService("CollectionService")
local camera = workspace.CurrentCamera

local constant = require(script.Constant)
local interaction_camera = require(replicatedStorage.Modules.InteractionCamera)

local InteractionModule = {}
InteractionModule.__index = InteractionModule

local player = players.LocalPlayer

local grab_overlap_params = OverlapParams.new()
grab_overlap_params.FilterType = Enum.RaycastFilterType.Exclude

local is_left_raised = false
local is_right_raised = false

local left_grabbed_part = nil
local right_grabbed_part = nil
local left_grab_weld = nil
local right_grab_weld = nil

local left_current_angles = constant.LEFT_IDLE_ANGLES
local right_current_angles = constant.RIGHT_IDLE_ANGLES
local left_angular_velocity = Vector3.new()
local right_angular_velocity = Vector3.new()

local last_local_velocity = Vector3.new()
local fall_intensity = 0

local render_connection = nil

local left_cursor_gui = nil
local right_cursor_gui = nil

local function random_kick(strength)
	return Vector3.new(
		math.rad(math.random(-strength, strength)),
		math.rad(math.random(-strength, strength)),
		math.rad(math.random(-strength, strength))
	)
end

local function spring_step(current, velocity, target, dt)
	local accel = (target - current) * constant.SPRING_STIFFNESS - velocity * constant.SPRING_DAMPING
	velocity = velocity + accel * dt
	current = current + velocity * dt
	return current, velocity
end

local function is_interactable(part)
	if not part:IsA("BasePart") then return false end
	if part.Anchored then return false end
	if collectionService:HasTag(part, constant.NON_INTERACTABLE_TAG) then return false end
	return true
end

local function find_nearest_grabbable(grip_attachment)
	local origin = grip_attachment.WorldPosition
	local parts = workspace:GetPartBoundsInRadius(origin, constant.GRAB_RADIUS, grab_overlap_params)

	local nearest_part = nil
	local nearest_distance = math.huge

	for _, part in pairs(parts) do
		if is_interactable(part) then
			local distance = (part.Position - origin).Magnitude
			if distance < nearest_distance then
				nearest_distance = distance
				nearest_part = part
			end
		end
	end

	return nearest_part
end

local function try_grab(grip_attachment)
	local target = find_nearest_grabbable(grip_attachment)
	if not target then return nil, nil end

	local grab_attachment = Instance.new("Attachment")
	grab_attachment.Name = "GrabAttachment"
	grab_attachment.CFrame = target.CFrame:ToObjectSpace(grip_attachment.WorldCFrame)
	grab_attachment.Parent = target

	local align_position = Instance.new("AlignPosition")
	align_position.Name = "GrabAlignPosition"
	align_position.Attachment0 = grab_attachment
	align_position.Attachment1 = grip_attachment
	align_position.RigidityEnabled = false
	align_position.MaxForce = math.sqrt(target.AssemblyMass) * constant.GRAB_FORCE_PER_MASS
	align_position.Responsiveness = constant.GRAB_RESPONSIVENESS
	align_position.Parent = target

	local align_orientation = Instance.new("AlignOrientation")
	align_orientation.Name = "GrabAlignOrientation"
	align_orientation.Attachment0 = grab_attachment
	align_orientation.Attachment1 = grip_attachment
	align_orientation.RigidityEnabled = false
	align_orientation.MaxTorque = target.AssemblyMass * constant.GRAB_TORQUE_PER_MASS
	align_orientation.Responsiveness = constant.GRAB_RESPONSIVENESS
	align_orientation.Parent = target

	return target, {attachment = grab_attachment, position = align_position, orientation = align_orientation}
end

local function release_grab(grab_data)
	if grab_data then
		if grab_data.position then grab_data.position:Destroy() end
		if grab_data.orientation then grab_data.orientation:Destroy() end
		if grab_data.attachment then grab_data.attachment:Destroy() end
	end
end

local function destroy_joint(character, part)
	for _, joint in pairs(character:GetDescendants()) do
		if joint:IsA("Motor6D") or joint:IsA("Weld") or joint:IsA("WeldConstraint") then
			if joint.Part0 == part or joint.Part1 == part then
				joint:Destroy()
			end
		end
	end
end

local function add_physics(character, part)
	destroy_joint(character, part)

	part.CanCollide = false
	part.Anchored = true

	local pivot_offset = (part.Name == "Left Arm") and CFrame.new(-1.5, 0.5, 0) or CFrame.new(1.5, 0.5, 0)
	local roll_offset = (part.Name == "Left Arm") and CFrame.Angles(0, 0, math.rad(35)) or CFrame.Angles(0, 0, math.rad(-35))

	return pivot_offset, roll_offset
end

local function create_cursor_gui(grip_attachment, cursor_asset_id)
	local billboard_gui = Instance.new("BillboardGui")
	billboard_gui.Name = "InteractionCursor"
	billboard_gui.Adornee = grip_attachment
	billboard_gui.Size = constant.CURSOR_SIZE
	billboard_gui.AlwaysOnTop = true
	billboard_gui.Enabled = false
	billboard_gui.Parent = grip_attachment

	local cursor_image = Instance.new("ImageLabel")
	cursor_image.Name = "CursorImage"
	cursor_image.BackgroundTransparency = 1
	cursor_image.Size = UDim2.new(1, 0, 1, 0)
	cursor_image.Image = cursor_asset_id
	cursor_image.Parent = billboard_gui

	return billboard_gui
end

local function on_character_added(character)
	if render_connection then
		render_connection:Disconnect()
		render_connection = nil
	end

	left_grabbed_part = nil
	right_grabbed_part = nil
	left_grab_weld = nil
	right_grab_weld = nil
	is_left_raised = false
	is_right_raised = false
	fall_intensity = 0
	left_current_angles = constant.LEFT_IDLE_ANGLES
	right_current_angles = constant.RIGHT_IDLE_ANGLES
	left_angular_velocity = Vector3.new()
	right_angular_velocity = Vector3.new()
	last_local_velocity = Vector3.new()

	local humanoid_root_part = character:WaitForChild("HumanoidRootPart")

	local left_arm = character:WaitForChild("Left Arm")
	local right_arm = character:WaitForChild("Right Arm")
	local arm_anchor = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")

	local left_pivot_offset, left_roll_offset = add_physics(character, left_arm)
	local right_pivot_offset, right_roll_offset = add_physics(character, right_arm)

	local left_grip_attachment = left_arm:WaitForChild("LeftGripAttachment")
	local right_grip_attachment = right_arm:WaitForChild("RightGripAttachment")

	if left_cursor_gui then
		left_cursor_gui:Destroy()
		left_cursor_gui = nil
	end

	if right_cursor_gui then
		right_cursor_gui:Destroy()
		right_cursor_gui = nil
	end

	left_cursor_gui = create_cursor_gui(left_grip_attachment, constant.GRAB_LEFT_CURSOR_ASSET_ID)
	right_cursor_gui = create_cursor_gui(right_grip_attachment, constant.GRAB_RIGHT_CURSOR_ASSET_ID)

	grab_overlap_params.FilterDescendantsInstances = {character}

	render_connection = runService.RenderStepped:Connect(function(dt)
		local time_clock = os.clock()

		local velocity = humanoid_root_part.AssemblyLinearVelocity
		local local_velocity = humanoid_root_part.CFrame:VectorToObjectSpace(velocity)

		local horizontal_speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		local is_moving = horizontal_speed > 1

		local bob_speed = is_moving and constant.MOVE_BOB_SPEED or constant.IDLE_BOB_SPEED
		local bob_amount = is_moving and constant.MOVE_BOB_AMOUNT or constant.IDLE_BOB_AMOUNT

		local bob_x = math.rad(math.sin(time_clock * bob_speed) * bob_amount)
		local bob_z = math.rad(math.cos(time_clock * bob_speed) * bob_amount)

		local forward_drag = math.rad(math.clamp(local_velocity.Z * constant.FORWARD_DRAG_SCALE, -constant.DRAG_MAX, constant.DRAG_MAX))
		local strafe_drag = math.rad(math.clamp(-local_velocity.X * constant.STRAFE_DRAG_SCALE, -constant.DRAG_MAX, constant.DRAG_MAX))
		local vertical_drag = math.rad(math.clamp(local_velocity.Y * constant.VERTICAL_DRAG_SCALE, -constant.DRAG_MAX, constant.DRAG_MAX))

		local local_acceleration = dt > 0 and (local_velocity - last_local_velocity) / dt or Vector3.new()
		last_local_velocity = local_velocity

		local forward_inertia = math.rad(math.clamp(-local_acceleration.Z * constant.ACCEL_DRAG_SCALE, -constant.ACCEL_DRAG_MAX, constant.ACCEL_DRAG_MAX))
		local strafe_inertia = math.rad(math.clamp(local_acceleration.X * constant.ACCEL_DRAG_SCALE, -constant.ACCEL_DRAG_MAX, constant.ACCEL_DRAG_MAX))

		local drag_x = forward_drag + forward_inertia
		local drag_z = strafe_drag + strafe_inertia
		local drag_y = vertical_drag

		local bob_offset = Vector3.new(bob_x + drag_x, drag_y, bob_z + drag_z)

		local left_base = constant.LEFT_IDLE_ANGLES
		local right_base = constant.RIGHT_IDLE_ANGLES

		if not is_left_raised then
			left_base = left_base:Lerp(constant.LEFT_FALL_ANGLES, fall_intensity)
		else
			left_base = constant.LEFT_RAISE_ANGLES
		end

		if not is_right_raised then
			right_base = right_base:Lerp(constant.RIGHT_FALL_ANGLES, fall_intensity)
		else
			right_base = constant.RIGHT_RAISE_ANGLES
		end

		local left_wobble = Vector3.new()
		if is_left_raised then
			left_wobble = Vector3.new(
				math.rad(math.sin(time_clock * constant.RAISE_WOBBLE_SPEED) * constant.RAISE_WOBBLE_AMOUNT),
				math.rad(math.sin(time_clock * constant.RAISE_WOBBLE_SPEED * 0.6 + 1) * constant.RAISE_WOBBLE_AMOUNT * 0.5),
				math.rad(math.cos(time_clock * constant.RAISE_WOBBLE_SPEED * 0.8) * constant.RAISE_WOBBLE_AMOUNT)
			)
		end

		local right_wobble = Vector3.new()
		if is_right_raised then
			right_wobble = Vector3.new(
				math.rad(math.sin(time_clock * constant.RAISE_WOBBLE_SPEED + 2) * constant.RAISE_WOBBLE_AMOUNT),
				math.rad(math.sin(time_clock * constant.RAISE_WOBBLE_SPEED * 0.6 + 3) * constant.RAISE_WOBBLE_AMOUNT * 0.5),
				math.rad(math.cos(time_clock * constant.RAISE_WOBBLE_SPEED * 0.8 + 2) * constant.RAISE_WOBBLE_AMOUNT)
			)
		end

		local left_fall_wobble = Vector3.new()
		if not is_left_raised then
			left_fall_wobble = Vector3.new(
				math.rad(math.sin(time_clock * constant.FALL_WOBBLE_SPEED) * constant.FALL_WOBBLE_AMOUNT),
				math.rad(math.sin(time_clock * constant.FALL_WOBBLE_SPEED * 0.7 + 1) * constant.FALL_WOBBLE_AMOUNT * 0.6),
				math.rad(math.cos(time_clock * constant.FALL_WOBBLE_SPEED * 0.5) * constant.FALL_WOBBLE_AMOUNT)
			) * fall_intensity
		end

		local right_fall_wobble = Vector3.new()
		if not is_right_raised then
			right_fall_wobble = Vector3.new(
				math.rad(math.sin(time_clock * constant.FALL_WOBBLE_SPEED + 2) * constant.FALL_WOBBLE_AMOUNT),
				math.rad(math.sin(time_clock * constant.FALL_WOBBLE_SPEED * 0.7 + 3) * constant.FALL_WOBBLE_AMOUNT * 0.6),
				math.rad(math.cos(time_clock * constant.FALL_WOBBLE_SPEED * 0.5 + 2) * constant.FALL_WOBBLE_AMOUNT)
			) * fall_intensity
		end

		local target_left_angles = left_base + bob_offset + left_wobble + left_fall_wobble
		local target_right_angles = right_base + bob_offset + right_wobble + right_fall_wobble

		left_current_angles, left_angular_velocity = spring_step(left_current_angles, left_angular_velocity, target_left_angles, dt)
		right_current_angles, right_angular_velocity = spring_step(right_current_angles, right_angular_velocity, target_right_angles, dt)

		local target_fall_intensity = 0
		if velocity.Y < constant.FALL_VELOCITY then
			local overshoot = (constant.FALL_VELOCITY - velocity.Y) / math.abs(constant.FALL_VELOCITY)
			target_fall_intensity = math.clamp(overshoot, 0, 1)
		end

		fall_intensity = fall_intensity + (target_fall_intensity - fall_intensity) * math.clamp(constant.FALL_BLEND_SPEED * dt, 0, 1)

		local camera_rotation = camera.CFrame - camera.CFrame.Position
		local base_world_cframe = CFrame.new(arm_anchor.Position) * camera_rotation

		local left_shoulder_cframe = base_world_cframe * left_pivot_offset * left_roll_offset * CFrame.Angles(left_current_angles.X, left_current_angles.Y, left_current_angles.Z)
		left_arm.CFrame = left_shoulder_cframe * CFrame.new(0, -left_arm.Size.Y / 2, 0)

		local right_shoulder_cframe = base_world_cframe * right_pivot_offset * right_roll_offset * CFrame.Angles(right_current_angles.X, right_current_angles.Y, right_current_angles.Z)
		right_arm.CFrame = right_shoulder_cframe * CFrame.new(0, -right_arm.Size.Y / 2, 0)

		if is_left_raised and not left_grabbed_part then
			left_grabbed_part, left_grab_weld = try_grab(left_grip_attachment)
		end

		if is_right_raised and not right_grabbed_part then
			right_grabbed_part, right_grab_weld = try_grab(right_grip_attachment)
		end
	end)
end

function InteractionModule:Start()
	interaction_camera.startCamera()
	userInputService.InputBegan:Connect(function(input, game_processed)
		if game_processed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			is_left_raised = true
			left_angular_velocity = left_angular_velocity + Vector3.new(math.rad(-constant.RAISE_KICK_STRENGTH * 4), 0, 0) + random_kick(constant.RAISE_KICK_STRENGTH)
			if left_cursor_gui and constant.CURSOR_ENABLED then
				left_cursor_gui.Enabled = true
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			is_right_raised = true
			right_angular_velocity = right_angular_velocity + Vector3.new(math.rad(-constant.RAISE_KICK_STRENGTH * 4), 0, 0) + random_kick(constant.RAISE_KICK_STRENGTH)
			if right_cursor_gui and constant.CURSOR_ENABLED then
				right_cursor_gui.Enabled = true
			end
		end
	end)

	userInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			is_left_raised = false
			left_angular_velocity = left_angular_velocity + random_kick(constant.RELEASE_KICK_STRENGTH)
			release_grab(left_grab_weld)
			left_grabbed_part = nil
			left_grab_weld = nil
			if left_cursor_gui then
				left_cursor_gui.Enabled = false
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			is_right_raised = false
			right_angular_velocity = right_angular_velocity + random_kick(constant.RELEASE_KICK_STRENGTH)
			release_grab(right_grab_weld)
			right_grabbed_part = nil
			right_grab_weld = nil
			if right_cursor_gui then
				right_cursor_gui.Enabled = false
			end
		end
	end)

	player.CharacterAdded:Connect(on_character_added)

	if player.Character then
		on_character_added(player.Character)
	end
end

return InteractionModule
