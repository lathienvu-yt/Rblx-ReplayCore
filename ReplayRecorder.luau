local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local soundsFolder = ReplicatedStorage:WaitForChild("Platformer"):WaitForChild("Sounds")
local playSoundFromSource = require(ReplicatedStorage.Utility.playSoundFromSource)

local ReplayEvent = ReplicatedStorage:WaitForChild("ReplayEvent")


local Player = Players.LocalPlayer

local Character
local Humanoid
local RootPart
local Animator

local isRecording = false
local replayData = {}
local startTime = 0
local frameCounter = 0
local streamId = nil

local pendingFrames = {}
local deathConnections = {}

local hasFirstFrame = false
local previousPlayerParts = {}

local forceAbsoluteCameraFrame = false
local characterReferences = {}
local previousCameraPos
local previousCameraLook

local MULTIPLAYER_RECORD_RADIUS = 180
local CHUNK_SIZE = 100
local MAX_RECORDING_TIME = 180

local currentPrecision = 3
local captureFrame
local humanoidJumpConnection
local currentPlaybackSessionId = nil

--------------------------------------------------
-- CHARACTER BINDING
--------------------------------------------------

local function BindCharacter(character)
	Character = character

	Humanoid = character:WaitForChild("Humanoid")
	RootPart = character:WaitForChild("HumanoidRootPart")
	Animator = Humanoid:WaitForChild("Animator")

	local playerKey = tostring(Player.UserId)

	previousPlayerParts[playerKey] = nil
	characterReferences[playerKey] = character

	previousCameraPos = nil
	previousCameraLook = nil
	forceAbsoluteCameraFrame = true

	if humanoidJumpConnection then
		humanoidJumpConnection:Disconnect()
		humanoidJumpConnection = nil
	end

	humanoidJumpConnection = Humanoid.Jumping:Connect(function(active)
		if active and isRecording and captureFrame then
			captureFrame("Jump")
		end
	end)
end

if Player.Character then
	BindCharacter(Player.Character)
end

Player.CharacterAdded:Connect(BindCharacter)

--------------------------------------------------
-- REPLAY TIMELINE
--------------------------------------------------

_G.ReplayTimeline = {
	IsActive = false,
	IsPaused = false,
	CurrentTime = 0,
	TotalDuration = 0,

	CameraMode = "POV",
	PlaybackSpeed = 1,

	Dummy = nil,
	Dummies = {},
	Emitter = nil,

	Data = nil,

	FocusPlayer = nil,
	TargetPlayer = nil,

	Players = {},
}

--------------------------------------------------
-- FREECAM
--------------------------------------------------

local freecam = {
	enabled = false,
	isPanning = false,

	yaw = 0,
	pitch = 0,

	targetYaw = 0,
	targetPitch = 0,

	position = Vector3.zero,
	velocity = Vector3.zero,

	speed = 8,
	minSpeed = 0.5,
	maxSpeed = 250,

	acceleration = 55,
	deceleration = 70,

	mouseSensitivity = 0.003,

	-- Rotation smoothing.
	-- Lower = smoother/slower
	-- Higher = more responsive
	rotationSmoothness = 12,

	pendingMouseDelta = Vector2.zero,

	boostMultiplier = 4,
	precisionMultiplier = 0.2,

	keys = {},
}

--------------------------------------------------
-- ENABLE
--------------------------------------------------

local function freecamEnable()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	freecam.enabled = true
	freecam.isPanning = false

	-- Start exactly at current camera position
	freecam.position = camera.CFrame.Position
	freecam.velocity = Vector3.zero

	-- Get current camera look direction
	local look = camera.CFrame.LookVector

	-- Convert look direction to yaw/pitch
	freecam.yaw = math.atan2(-look.X, -look.Z)

	freecam.pitch = math.asin(
		math.clamp(look.Y, -1, 1)
	)

	-- IMPORTANT:
	-- Target starts at the same rotation.
	-- This prevents a jump when freecam is enabled.
	freecam.targetYaw = freecam.yaw
	freecam.targetPitch = freecam.pitch

	freecam.pendingMouseDelta = Vector2.zero

	camera.CameraType = Enum.CameraType.Scriptable

	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

--------------------------------------------------
-- DISABLE
--------------------------------------------------

local function freecamDisable()
	freecam.enabled = false
	freecam.isPanning = false

	freecam.velocity = Vector3.zero
	freecam.keys = {}

	freecam.pendingMouseDelta = Vector2.zero

	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

--------------------------------------------------
-- SET ENABLED
--------------------------------------------------

local function setFreecamEnabled(enabled)
	enabled = enabled == true

	if enabled then
		if not freecam.enabled then
			freecamEnable()
		end
	else
		if freecam.enabled then
			freecamDisable()
		end
	end
end

_G.SetFreecamEnabled = setFreecamEnabled

--------------------------------------------------
-- VECTOR APPROACH
--------------------------------------------------

local function approachVector(current, target, amount)
	local difference = target - current
	local distance = difference.Magnitude

	if distance <= amount or distance == 0 then
		return target
	end

	return current + difference.Unit * amount
end

--------------------------------------------------
-- ANGLE APPROACH
--------------------------------------------------

local function lerpAngle(current, target, alpha)
	local difference = math.atan2(
		math.sin(target - current),
		math.cos(target - current)
	)

	return current + difference * alpha
end

--------------------------------------------------
-- FREECAM UPDATE
--------------------------------------------------

local function updateFreecam(dt)
	if not freecam.enabled then
		return
	end

	local timeline = _G.ReplayTimeline

	if not timeline
		or not timeline.IsActive
		or timeline.CameraMode ~= "Freecam"
	then
		freecamDisable()
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	--------------------------------------------------
	-- INPUT VECTOR
	--------------------------------------------------

	local move = Vector3.zero

	if freecam.keys.W then
		move += Vector3.new(0, 0, -1)
	end

	if freecam.keys.S then
		move += Vector3.new(0, 0, 1)
	end

	if freecam.keys.A then
		move += Vector3.new(-1, 0, 0)
	end

	if freecam.keys.D then
		move += Vector3.new(1, 0, 0)
	end

	if freecam.keys.E then
		move += Vector3.new(0, 1, 0)
	end

	if freecam.keys.Q then
		move += Vector3.new(0, -1, 0)
	end

	if move.Magnitude > 1 then
		move = move.Unit
	end

	--------------------------------------------------
	-- MOUSE ROTATION TARGET
	--------------------------------------------------

	local mouseDelta = freecam.pendingMouseDelta

	freecam.pendingMouseDelta = Vector2.zero

	-- Mouse changes the TARGET rotation.
	freecam.targetYaw -=
		mouseDelta.X * freecam.mouseSensitivity

	freecam.targetPitch -=
		mouseDelta.Y * freecam.mouseSensitivity

	freecam.targetPitch = math.clamp(
		freecam.targetPitch,
		-math.rad(89),
		math.rad(89)
	)

	--------------------------------------------------
	-- ROTATION SMOOTHING
	--------------------------------------------------

	local rotationAlpha =
		1 - math.exp(-freecam.rotationSmoothness * dt)

	freecam.yaw = lerpAngle(
		freecam.yaw,
		freecam.targetYaw,
		rotationAlpha
	)

	freecam.pitch = freecam.pitch
		+ (freecam.targetPitch - freecam.pitch)
		* rotationAlpha

	--------------------------------------------------
	-- CAMERA ROTATION
	--------------------------------------------------

	local rotation =
		CFrame.fromEulerAnglesYXZ(
			freecam.pitch,
			freecam.yaw,
			0
		)

	--------------------------------------------------
	-- SPEED
	--------------------------------------------------

	local speedMultiplier = 1

	-- SHIFT = FAST
	if freecam.keys.Shift then
		speedMultiplier *= freecam.boostMultiplier
	end

	-- CTRL = PRECISION
	if freecam.keys.Ctrl then
		speedMultiplier *= freecam.precisionMultiplier
	end

	local targetSpeed =
		freecam.speed * speedMultiplier

	--------------------------------------------------
	-- TARGET VELOCITY
	--------------------------------------------------

	local targetVelocity =
		(rotation * move) * targetSpeed

	--------------------------------------------------
	-- MOVEMENT SMOOTHING
	--------------------------------------------------

	if move.Magnitude > 0 then
		-- Normal acceleration
		freecam.velocity = approachVector(
			freecam.velocity,
			targetVelocity,
			freecam.acceleration * dt
		)
	else
		-- Strong braking when no movement key is held.
		-- Braking gets stronger at higher speeds.
		local speed = freecam.velocity.Magnitude

		local brakeAcceleration = math.max(
			freecam.deceleration,
			speed * 4
		)

		freecam.velocity = approachVector(
			freecam.velocity,
			Vector3.zero,
			brakeAcceleration * dt
		)
	end
	--------------------------------------------------
	-- POSITION
	--------------------------------------------------

	freecam.position +=
		freecam.velocity * dt

	--------------------------------------------------
	-- APPLY CAMERA
	--------------------------------------------------

	camera.CameraType = Enum.CameraType.Scriptable

	camera.CFrame =
		CFrame.new(freecam.position)
		* rotation
end

--------------------------------------------------
-- MOUSE LOOK
--------------------------------------------------

UserInputService.InputChanged:Connect(function(input)
	if not freecam.enabled or not freecam.isPanning then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseMovement then

		-- InputObject.Delta is Vector3.
		-- Freecam rotation only needs X/Y.
		local delta = input.Delta

		freecam.pendingMouseDelta += Vector2.new(
			delta.X,
			delta.Y
		)
	end
end)

--------------------------------------------------
-- INPUT BEGAN
--------------------------------------------------

UserInputService.InputBegan:Connect(function(input, gpe)
	if not freecam.enabled then
		return
	end

	--------------------------------------------------
	-- RIGHT MOUSE = LOOK
	--------------------------------------------------

	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		freecam.isPanning = true

		UserInputService.MouseBehavior =
			Enum.MouseBehavior.LockCurrentPosition

		freecam.pendingMouseDelta = Vector2.zero

		return
	end

	if gpe then
		return
	end

	local code = input.KeyCode

	if code == Enum.KeyCode.W then
		freecam.keys.W = true

	elseif code == Enum.KeyCode.A then
		freecam.keys.A = true

	elseif code == Enum.KeyCode.S then
		freecam.keys.S = true

	elseif code == Enum.KeyCode.D then
		freecam.keys.D = true

	elseif code == Enum.KeyCode.E then
		freecam.keys.E = true

	elseif code == Enum.KeyCode.Q then
		freecam.keys.Q = true

	elseif code == Enum.KeyCode.LeftShift
		or code == Enum.KeyCode.RightShift then
		freecam.keys.Shift = true

	elseif code == Enum.KeyCode.LeftControl
		or code == Enum.KeyCode.RightControl then
		freecam.keys.Ctrl = true
	end
end)

--------------------------------------------------
-- INPUT ENDED
--------------------------------------------------

UserInputService.InputEnded:Connect(function(input)
	if not freecam.enabled then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		freecam.isPanning = false

		UserInputService.MouseBehavior =
			Enum.MouseBehavior.Default

		freecam.pendingMouseDelta = Vector2.zero

		return
	end

	local code = input.KeyCode

	if code == Enum.KeyCode.W then
		freecam.keys.W = nil

	elseif code == Enum.KeyCode.A then
		freecam.keys.A = nil

	elseif code == Enum.KeyCode.S then
		freecam.keys.S = nil

	elseif code == Enum.KeyCode.D then
		freecam.keys.D = nil

	elseif code == Enum.KeyCode.E then
		freecam.keys.E = nil

	elseif code == Enum.KeyCode.Q then
		freecam.keys.Q = nil

	elseif code == Enum.KeyCode.LeftShift
		or code == Enum.KeyCode.RightShift then
		freecam.keys.Shift = nil

	elseif code == Enum.KeyCode.LeftControl
		or code == Enum.KeyCode.RightControl then
		freecam.keys.Ctrl = nil
	end
end)

--------------------------------------------------
-- MOUSE WHEEL SPEED CONTROL
--------------------------------------------------

UserInputService.InputChanged:Connect(function(input)
	if not freecam.enabled then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseWheel then
		local wheel = input.Position.Z

		if wheel > 0 then
			freecam.speed *= 1.25
		elseif wheel < 0 then
			freecam.speed /= 1.25
		end

		freecam.speed = math.clamp(
			freecam.speed,
			freecam.minSpeed,
			freecam.maxSpeed
		)
	end
end)

--------------------------------------------------
-- RENDER LOOP
--------------------------------------------------

RunService.RenderStepped:Connect(updateFreecam)

--------------------------------------------------
-- COMPRESSION & RECORDING UTILS
--------------------------------------------------

local function roundNumber(n)
	local factor = 10 ^ currentPrecision
	return math.round(n * factor) / factor
end

local function compressVector3(v)
	return {
		roundNumber(v.X),
		roundNumber(v.Y),
		roundNumber(v.Z),
	}
end

local function vectorDelta(current, previous)
	if type(current) ~= "table" or type(previous) ~= "table" then return nil end
	if not current[1] or not current[2] or not current[3] then return nil end
	if not previous[1] or not previous[2] or not previous[3] then return nil end

	return {
		roundNumber(current[1] - previous[1]),
		roundNumber(current[2] - previous[2]),
		roundNumber(current[3] - previous[3]),
	}
end

local function getPlayerKey(player)
	return tostring(player.UserId)
end

local remoteCameraSamples = {}
local cameraCaptureEnabled = false
local activeCameraStreamId = nil

local function getCameraSample()
	local camera = workspace.CurrentCamera
	if not camera then return nil end

	return {
		pos = compressVector3(camera.CFrame.Position),
		look = compressVector3(camera.CFrame.LookVector),
	}
end

local function captureCharacterSnapshot(character, playerKey, isFirstFrame)
	local snapshot = {}
	local previous = previousPlayerParts[playerKey] or {}

	for _, instance in ipairs(character:GetDescendants()) do
		if instance:IsA("BasePart") and instance.Parent == character then
			local partKey = instance.Name

			local cf = instance.CFrame
			local pos = compressVector3(cf.Position)
			local rx, ry, rz = cf:ToEulerAnglesXYZ()
			local rot = {
				roundNumber(rx),
				roundNumber(ry),
				roundNumber(rz)
			}

			local old = previous[partKey]

			if isFirstFrame or not old then
				snapshot[partKey] = {
					p = pos,
					r = rot
				}
			else
				snapshot[partKey] = {
					dp = vectorDelta(pos, old.p),
					dr = vectorDelta(rot, old.r),
				}
			end

			previous[partKey] = {
				p = pos,
				r = rot
			}
		end
	end

	previousPlayerParts[playerKey] = previous
	return snapshot
end

local function captureAnimations(character)
	local result = {}
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")

	if not animator then return result end

	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		local animation = track.Animation
		if animation and animation.AnimationId ~= "" then
			table.insert(result, {
				id = animation.AnimationId,
				weight = roundNumber(track.WeightCurrent),
				speed = roundNumber(track.Speed),
				timePos = roundNumber(track.TimePosition),
			})
		end
	end

	return result
end

local function isCharacterInRecorderRadius(character)
	if not RootPart or not character then return false end
	local otherRoot = character:FindFirstChild("HumanoidRootPart")
	if not otherRoot then return false end

	return (otherRoot.Position - RootPart.Position).Magnitude <= MULTIPLAYER_RECORD_RADIUS
end

local function countPlayersInRadius()
	if not RootPart then return 0 end
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character and isCharacterInRecorderRadius(player.Character) then
			count += 1
		end
	end
	return count
end

local function getAdaptiveSettings(playerCount)
	if playerCount <= 1 then return 1, 3
	elseif playerCount <= 2 then return 2, 2
	elseif playerCount <= 4 then return 3, 2
	elseif playerCount <= 6 then return 4, 1
	else return 6, 1
	end
end

--------------------------------------------------
-- FRAME CAPTURE
--------------------------------------------------

captureFrame = function(actionTag)
	local camera = workspace.CurrentCamera
	if not Character or not RootPart then return end

	local elapsed = workspace:GetServerTimeNow() - startTime
	local firstFrame = not hasFirstFrame

	local playersSnapshot = {}
	local seenPlayerKeys = {}

	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character

		if char and isCharacterInRecorderRadius(char) then
			local key = getPlayerKey(player)
			seenPlayerKeys[key] = true

			local isNewCharacter = characterReferences[key] ~= char
			if isNewCharacter then
				characterReferences[key] = char
				previousPlayerParts[key] = nil
			end

			local absoluteCharacterFrame = firstFrame or isNewCharacter or previousPlayerParts[key] == nil

			playersSnapshot[key] = {
				userId = player.UserId,
				name = player.Name,
				displayName = player.DisplayName,
				isRecorder = player == Player,
				parts = captureCharacterSnapshot(char, key, absoluteCharacterFrame),
				anims = captureAnimations(char),
			}
		end
	end

	for key in pairs(previousPlayerParts) do
		if not seenPlayerKeys[key] then
			previousPlayerParts[key] = nil
		end
	end

	local cameraPos = compressVector3(camera.CFrame.Position)
	local cameraLook = compressVector3(camera.CFrame.LookVector)

	local absoluteCameraFrame = firstFrame
		or forceAbsoluteCameraFrame
		or not previousCameraPos
		or not previousCameraLook

	local cameraData

	if absoluteCameraFrame then
		cameraData = { pos = cameraPos, look = cameraLook }
		forceAbsoluteCameraFrame = false
	else
		local dp = vectorDelta(cameraPos, previousCameraPos)
		local dl = vectorDelta(cameraLook, previousCameraLook)

		if not dp or not dl then
			cameraData = { pos = cameraPos, look = cameraLook }
			forceAbsoluteCameraFrame = false
		else
			cameraData = { dp = dp, dl = dl }
		end
	end

	previousCameraPos = cameraPos
	previousCameraLook = cameraLook

	local ownKey = getPlayerKey(Player)
	local recorderSnapshot = playersSnapshot[ownKey]

	local camerasSnapshot = {}
	camerasSnapshot[ownKey] = cameraData

	for playerKey, sample in pairs(remoteCameraSamples) do
		if playerKey ~= ownKey
			and type(sample) == "table"
			and sample.pos
			and sample.look
		then
			camerasSnapshot[playerKey] = sample
		end
	end

	local frame = {
		t = roundNumber(elapsed),
		players = playersSnapshot,
		parts = recorderSnapshot and recorderSnapshot.parts or {},
		anims = recorderSnapshot and recorderSnapshot.anims or {},
		cameras = camerasSnapshot,
		a = actionTag or "",
	}

	if firstFrame then
		frame.cameraPos = cameraPos
		frame.cameraLook = cameraLook
	else
		frame.cameraDP = cameraData.dp
		frame.cameraDL = cameraData.dl
	end

	table.insert(pendingFrames, frame)
	hasFirstFrame = true
end

--------------------------------------------------
-- START / STOP RECORDING
--------------------------------------------------

local function StartRecording(seed, mapMode, isMultiplayer)
	if _G.ReplayTimeline and _G.ReplayTimeline.IsActive then return end

	previousPlayerParts = {}
	previousCameraPos = nil
	previousCameraLook = nil
	forceAbsoluteCameraFrame = true

	streamId = "Stream_" .. Player.UserId .. "_" .. HttpService:GenerateGUID(false)

	replayData = {
		mapSeed = seed or math.random(1, 100000),
		mapMode = mapMode or "Linear",
		sounds = {},
		markers = {},
		recorderUserId = Player.UserId,
		recorderRadius = MULTIPLAYER_RECORD_RADIUS,
		multiplayer = isMultiplayer == true,
	}

	pendingFrames = {}
	hasFirstFrame = false

	startTime = workspace:GetServerTimeNow()
	frameCounter = 0
	isRecording = true

	ReplayEvent:FireServer("StartStream", streamId, replayData)
	ReplayEvent:FireServer("EnableCameraCapture", streamId)
end

local function StopAndSaveRecording(reason)
	if not isRecording then return end
	isRecording = false

	warn(
		"[ReplaySystem] STOP RECORDING:",
		reason or "UNKNOWN",
		"streamId =", streamId,
		"frames =", frameCounter,
		"elapsed =", workspace:GetServerTimeNow() - startTime
	)

	if frameCounter == 0 or not streamId then
		print("[ReplaySystem] Aborting save: No frames captured or missing streamId.")
		ReplayEvent:FireServer("RecordingFailed", "No frames were captured.")
		streamId = nil
		return
	end

	if #pendingFrames > 0 then
		ReplayEvent:FireServer("StreamChunk", streamId, pendingFrames)
		pendingFrames = {}
	end

	ReplayEvent:FireServer(
		"FinalizeReplay",
		streamId,
		replayData.sounds,
		replayData.markers
	)
	streamId = nil

	task.delay(1.5, function()
		ReplayEvent:FireServer("RequestProfileList")
	end)
end

RunService.Heartbeat:Connect(function()
	if not isRecording then return end

	if workspace:GetServerTimeNow() - startTime > MAX_RECORDING_TIME then
		StopAndSaveRecording("Max time reached")
		return
	end

	frameCounter += 1
	local count = countPlayersInRadius()
	local interval, precision = getAdaptiveSettings(count)
	currentPrecision = precision

	if frameCounter % interval ~= 0 then return end

	captureFrame()

	if #pendingFrames >= CHUNK_SIZE then
		ReplayEvent:FireServer("StreamChunk", streamId, pendingFrames)
		pendingFrames = {}
	end
end)

--------------------------------------------------
-- MARKERS & SOUNDS
--------------------------------------------------

_G.RecordReplaySound = function(soundInfo)
	if not isRecording then return end
	soundInfo.t = workspace:GetServerTimeNow() - startTime
	table.insert(replayData.sounds, soundInfo)
end

_G.RecordReplayMarker = function(markerType, data)
	if not isRecording or type(markerType) ~= "string" then return end

	local marker = {
		t = roundNumber(workspace:GetServerTimeNow() - startTime),
		type = markerType,
	}

	if type(data) == "table" then
		for k, v in pairs(data) do
			marker[k] = v
		end
	end

	table.insert(replayData.markers, marker)
end

local lastJogTime = 0

_G.JogReplaySound = function()
	local timeline = _G.ReplayTimeline
	if not timeline or not timeline.IsActive then return end

	local now = os.clock()
	if now - lastJogTime < 0.1 then return end
	lastJogTime = now

	local sounds = timeline.Data and timeline.Data.sounds or {}
	if #sounds == 0 then return end

	local current = timeline.CurrentTime
	local soundInfo

	for i = #sounds, 1, -1 do
		if sounds[i].t <= current then
			soundInfo = sounds[i]
			break
		end
	end

	if not soundInfo then return end

	local template = soundsFolder:FindFirstChild(soundInfo.template)
	local emitter = timeline.Emitter

	if not template or not emitter then return end

	local audioPlayer = template:Clone()
	audioPlayer.PlaybackSpeed = (soundInfo.speed / template.PlaybackSpeed) * timeline.PlaybackSpeed

	local offset = math.max(0, current - soundInfo.t)
	audioPlayer.TimePosition = math.min(offset, math.max(0, audioPlayer.TimeLength - 0.05))

	audioPlayer.Parent = emitter
	audioPlayer:Play()

	task.delay(0.1, function()
		if audioPlayer then audioPlayer:Destroy() end
	end)
end

--------------------------------------------------
-- DECODER & PLAYBACK
--------------------------------------------------

local DICT_ESC = string.char(1)
local DICT_REVERSE = {
	[DICT_ESC .. "a"] = '"cameraPos":',
	[DICT_ESC .. "b"] = '"cameraLook":',
	[DICT_ESC .. "c"] = '"cameraDP":',
	[DICT_ESC .. "d"] = '"cameraDL":',
	[DICT_ESC .. "e"] = '"parts":',
	[DICT_ESC .. "f"] = '"anims":',
	[DICT_ESC .. "g"] = '"weight":',
	[DICT_ESC .. "h"] = '"speed":',
	[DICT_ESC .. "i"] = '"timePos":',
	[DICT_ESC .. "j"] = '"mapSeed":',
	[DICT_ESC .. "k"] = '"sounds":',
	[DICT_ESC .. "l"] = '"frames":',
	[DICT_ESC .. "m"] = '"id":',
	[DICT_ESC .. "n"] = '"template":',
	[DICT_ESC .. "o"] = '"t":',
	[DICT_ESC .. "p"] = '"a":',
	[DICT_ESC .. "q"] = '"p":',
	[DICT_ESC .. "s"] = '"r":',
	[DICT_ESC .. "t"] = '"dp":',
	[DICT_ESC .. "u"] = '"dr":',
	[DICT_ESC .. "v"] = '"Head":',
	[DICT_ESC .. "w"] = '"HumanoidRootPart":',
	[DICT_ESC .. "x"] = '"Torso":',
	[DICT_ESC .. "y"] = '"Left Arm":',
	[DICT_ESC .. "z"] = '"Right Arm":',
	[DICT_ESC .. "A"] = '"Left Leg":',
	[DICT_ESC .. "B"] = '"Right Leg":',
	[DICT_ESC .. "C"] = '"LeftHand":',
	[DICT_ESC .. "D"] = '"RightHand":',
	[DICT_ESC .. "E"] = '"LeftFoot":',
	[DICT_ESC .. "F"] = '"RightFoot":',
	[DICT_ESC .. "G"] = '"LeftLowerLeg":',
	[DICT_ESC .. "H"] = '"RightLowerLeg":',
	[DICT_ESC .. "I"] = '"LeftUpperLeg":',
	[DICT_ESC .. "J"] = '"RightUpperLeg":',
	[DICT_ESC .. "K"] = '"LeftLowerArm":',
	[DICT_ESC .. "L"] = '"RightLowerArm":',
	[DICT_ESC .. "M"] = '"LeftUpperArm":',
	[DICT_ESC .. "N"] = '"RightUpperArm":',
	[DICT_ESC .. "O"] = '"UpperTorso":',
	[DICT_ESC .. "P"] = '"LowerTorso":',
	[DICT_ESC .. "Q"] = "rbxassetid://",
}

local function clientDictDecode(s)
	for token, full in pairs(DICT_REVERSE) do
		local escaped = string.gsub(token, "([^%w])", "%%%1")
		s = string.gsub(s, escaped, full)
	end
	return s
end

local function safeJsonDecode(payload)
	if type(payload) == "table" then
		return payload
	end

	if type(payload) ~= "string" or payload == "" or payload == "null" then
		warn("[ReplaySystem] JSON Decode skipped: Payload is empty or invalid type (" .. type(payload) .. ")")
		return nil
	end

	if string.find(payload, DICT_ESC, 1, true) then
		payload = clientDictDecode(payload)
	end

	local ok, result = pcall(function()
		return HttpService:JSONDecode(payload)
	end)

	if not ok then
		warn("[ReplaySystem] JSON Decode failed:", result, "| Length:", #payload, "| Sample:", string.sub(payload, 1, 50))
		return nil
	end

	return result
end

local finalizedReplayData = nil
local dynamicPlaybackOffset = Vector3.zero
_G.ReplayAutoRecording = false
local playbackConnection = nil
local playbackFrameIndex = 1
local playbackPlayerState = {}
local playbackCameraState = {}
--------------------------------------------------
-- REPLAY WORLD VISIBILITY / FREEZE
--------------------------------------------------

local replayWorldState = {
	active = false,
	characters = {},
	localCharacter = nil,
	localHumanoid = nil,
	localRoot = nil,
}

local lastAppliedCameraMode = nil
local lastAppliedFocusPlayer = nil
local cameraNeedsRefresh = true

local function buildPlaybackRoster(data)
	local roster = {}
	for _, frame in ipairs(data.frames or {}) do
		for key, pdata in pairs(frame.players or {}) do
			if type(pdata) == "table" and not roster[key] then
				roster[key] = {
					userId = pdata.userId,
					name = pdata.name,
					displayName = pdata.displayName,
					isRecorder = pdata.isRecorder == true,
				}
			end
		end
	end
	return roster
end
--------------------------------------------------
-- HIDE CHARACTER LOCALLY
--------------------------------------------------

local function setCharacterHidden(character, hidden)
	if not character then
		return
	end

	for _, obj in ipairs(character:GetDescendants()) do
		if obj:IsA("BasePart") then
			obj.LocalTransparencyModifier = hidden and 1 or 0

		elseif obj:IsA("Decal") or obj:IsA("Texture") then
			obj.Transparency = hidden and 1 or 0

		elseif obj:IsA("ParticleEmitter")
			or obj:IsA("Trail")
			or obj:IsA("Beam") then

			obj.Enabled = not hidden
		end
	end
end

--------------------------------------------------
-- FREEZE LOCAL CHARACTER
--------------------------------------------------

local function freezeLocalCharacter()
	local character = Player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")

	replayWorldState.localCharacter = character
	replayWorldState.localHumanoid = humanoid
	replayWorldState.localRoot = root

	if humanoid then
		replayWorldState.localHumanoidWalkSpeed = humanoid.WalkSpeed
		replayWorldState.localHumanoidJumpPower = humanoid.JumpPower
		replayWorldState.localHumanoidAutoRotate = humanoid.AutoRotate

		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.AutoRotate = false
	end

	if root then
		replayWorldState.localRootAnchored = root.Anchored
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		root.Anchored = true
	end

	setCharacterHidden(character, true)
end

--------------------------------------------------
-- HIDE ALL LIVE PLAYERS
--------------------------------------------------

local function hideLivePlayers()
	replayWorldState.characters = {}

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character

		if character then
			replayWorldState.characters[player] = character
			setCharacterHidden(character, true)
		end
	end
end

--------------------------------------------------
-- RESTORE LIVE PLAYERS
--------------------------------------------------

local function restoreLivePlayers()
	-- Restore visibility
	for player, character in pairs(replayWorldState.characters) do
		if character and character.Parent then
			setCharacterHidden(character, false)
		end
	end

	-- Restore local character
	local character = replayWorldState.localCharacter
	local humanoid = replayWorldState.localHumanoid
	local root = replayWorldState.localRoot

	if character and character.Parent then
		setCharacterHidden(character, false)
	end

	if humanoid and humanoid.Parent then
		if replayWorldState.localHumanoidWalkSpeed ~= nil then
			humanoid.WalkSpeed =
				replayWorldState.localHumanoidWalkSpeed
		end

		if replayWorldState.localHumanoidJumpPower ~= nil then
			humanoid.JumpPower =
				replayWorldState.localHumanoidJumpPower
		end

		if replayWorldState.localHumanoidAutoRotate ~= nil then
			humanoid.AutoRotate =
				replayWorldState.localHumanoidAutoRotate
		end
	end

	if root and root.Parent then
		root.Anchored =
			replayWorldState.localRootAnchored == true
	end

	replayWorldState.active = false
	replayWorldState.characters = {}
	replayWorldState.localCharacter = nil
	replayWorldState.localHumanoid = nil
	replayWorldState.localRoot = nil
end

--------------------------------------------------
-- ENTER REPLAY WORLD
--------------------------------------------------

local function enterReplayWorld()
	if replayWorldState.active then
		return
	end

	replayWorldState.active = true

	-- Freeze and hide the actual player
	freezeLocalCharacter()

	-- Hide everyone else too
	hideLivePlayers()
end

local function FreezeOfflineAvatar(model)
	for _, obj in ipairs(model:GetDescendants()) do
		if obj:IsA("BasePart") then
			obj.AssemblyLinearVelocity = Vector3.zero
			obj.AssemblyAngularVelocity = Vector3.zero
			obj.CanCollide = false

			if not obj.Parent:IsA("Accessory") then
				obj.Anchored = true
			end

		elseif obj:IsA("Humanoid") then
			obj.PlatformStand = true
			obj.AutoRotate = false

		elseif obj:IsA("Animator") then
			obj.Parent = nil
		end
	end
end

local function cloneCharacterForReplay(character)
	if not character then return nil end

	local archivableStates = {}
	for _, instance in ipairs(character:GetDescendants()) do
		archivableStates[instance] = instance.Archivable
		instance.Archivable = true
	end
	archivableStates[character] = character.Archivable
	character.Archivable = true

	local ok, dummy = pcall(function()
		return character:Clone()
	end)

	for instance, oldState in pairs(archivableStates) do
		if instance and instance.Parent then
			instance.Archivable = oldState
		end
	end

	if not ok or not dummy then return nil end
	FreezeOfflineAvatar(dummy)
	return dummy
end

local function createFallbackDummy(userId)
	local dummy = Instance.new("Model")
	dummy.Name = "ReplayDummy_" .. tostring(userId)

	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 1)
	hrp.Transparency = 1
	hrp.Parent = dummy

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.2, 1.2, 1.2)
	head.Parent = dummy

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = dummy

	dummy.PrimaryPart = hrp
	return dummy
end

local function createReplayDummy(playerKey, playerData)
	local userId = playerData and tonumber(playerData.userId) or tonumber(playerKey)
	if not userId then return nil end

	local dummy = nil
	local targetPlayer = Players:GetPlayerByUserId(userId)

	-- 1. If player is in game with an active character, clone directly from workspace
	if targetPlayer and targetPlayer.Character then
		dummy = cloneCharacterForReplay(targetPlayer.Character)
	end

	-- 2. Fall back to Roblox Web API only if the player isn't in the live server
	if not dummy then
		local success, model = pcall(function()
			return Players:CreateHumanoidModelFromUserIdAsync(userId)
		end)
		if success and model then
			dummy = model
		end
	end

	-- 3. Ultimate safety fallback
	if not dummy then
		warn("[ReplaySystem] Failed to fetch character model for user", userId, "- using fallback dummy.")
		dummy = createFallbackDummy(userId)
	end

	local name = playerData and playerData.name or ("Player_" .. tostring(userId))
	dummy.Name = "ReplayDummy_" .. string.gsub(name, "[^%w_]", "_") .. "_" .. tostring(userId)


	FreezeOfflineAvatar(dummy)
	dummy.Parent = workspace
	return dummy
end

local function createPlaybackDummies(data, sessionId)
	local dummies = {}
	local roster = buildPlaybackRoster(data)

	for key, playerData in pairs(roster) do
		if currentPlaybackSessionId ~= sessionId then
			for _, d in pairs(dummies) do
				if d and d.Parent then d:Destroy() end
			end
			return nil
		end

		local dummy = createReplayDummy(key, playerData)

		if currentPlaybackSessionId ~= sessionId then
			if dummy and dummy.Parent then dummy:Destroy() end
			for _, d in pairs(dummies) do
				if d and d.Parent then d:Destroy() end
			end
			return nil
		end

		if dummy then
			dummies[key] = dummy
		end
	end

	return dummies
end

local function decodeCameraFrame(frame, focusKey)
	local camData = frame.cameras and frame.cameras[focusKey]

	if not camData then
		if frame.cameraPos then
			camData = { pos = frame.cameraPos, look = frame.cameraLook }
		elseif frame.cameraDP then
			camData = { dp = frame.cameraDP, dl = frame.cameraDL }
		end
	end

	if not camData then return nil end

	local state = playbackCameraState[focusKey]

	if camData.pos then
		local pos = Vector3.new(camData.pos[1], camData.pos[2], camData.pos[3])
		local look = Vector3.new(camData.look[1], camData.look[2], camData.look[3])
		playbackCameraState[focusKey] = { pos = pos, look = look }
		return pos, look
	elseif camData.dp and camData.dl and state then
		local pos = state.pos + Vector3.new(camData.dp[1], camData.dp[2], camData.dp[3])
		local look = state.look + Vector3.new(camData.dl[1], camData.dl[2], camData.dl[3])
		playbackCameraState[focusKey] = { pos = pos, look = look }
		return pos, look
	end

	return nil
end

local function decodePlayerFrame(playerKey, pdata)
	if type(pdata) ~= "table" or type(pdata.parts) ~= "table" then return end
	local playerState = playbackPlayerState[playerKey] or {}
	playbackPlayerState[playerKey] = playerState

	for partName, partData in pairs(pdata.parts) do
		if type(partData) ~= "table" then continue end
		local state = playerState[partName]

		if partData.p and partData.r then
			playerState[partName] = {
				p = { partData.p[1], partData.p[2], partData.p[3] },
				r = { partData.r[1], partData.r[2], partData.r[3] },
			}
		elseif partData.dp and partData.dr and state and state.p and state.r then
			playerState[partName] = {
				p = { state.p[1] + partData.dp[1], state.p[2] + partData.dp[2], state.p[3] + partData.dp[3] },
				r = { state.r[1] + partData.dr[1], state.r[2] + partData.dr[2], state.r[3] + partData.dr[3] },
			}
		end
	end
end

local function applyPlayerStateToDummy(dummy, playerKey, offset)
	if not dummy then return end

	local state = playbackPlayerState[playerKey]
	if not state then return end

	for partKey, partState in pairs(state) do
		if not partState.p or not partState.r then
			continue
		end

		local targetPart = dummy:FindFirstChild(partKey, true)

		if targetPart and targetPart:IsA("BasePart") then
			targetPart.CFrame =
				CFrame.new(
					Vector3.new(
						partState.p[1],
						partState.p[2],
						partState.p[3]
					) + offset
				)
				* CFrame.fromEulerAnglesXYZ(
					partState.r[1],
					partState.r[2],
					partState.r[3]
				)
		end
	end
end

local function decodePlaybackFrame(frame)
	if not frame then return end
	for playerKey, pdata in pairs(frame.players or {}) do
		decodePlayerFrame(playerKey, pdata)
	end
end

local function resetPlaybackDecoder()
	playbackPlayerState = {}
	playbackCameraState = {}
end

local function getFrameIndexForTime(frames, targetTime)
	if #frames == 0 then return 1 end
	local targetIndex = 1
	for i = 1, #frames do
		if frames[i].t <= targetTime then
			targetIndex = i
		else
			break
		end
	end
	return targetIndex
end

local function applyPOVCamera(timeline, offset)
	if not timeline or not timeline.IsActive then return end
	local camera = workspace.CurrentCamera
	if not camera then return end

	local focusKey = tostring(timeline.FocusPlayer or timeline.TargetPlayer or timeline.Data.recorderUserId or Player.UserId)
	local camState = playbackCameraState[focusKey]

	if camState and camState.pos and camState.look then
		camera.CameraType = Enum.CameraType.Scriptable
		local finalPos = camState.pos + offset
		local look = camState.look

		if not look or look.Magnitude < 0.001 or look.X ~= look.X then
			look = Vector3.new(0, 0, -1)
		else
			look = look.Unit
		end

		camera.CFrame = CFrame.lookAt(finalPos, finalPos + look)
		return
	end

	local dummy = timeline.Dummies and timeline.Dummies[focusKey]
	if not dummy then
		camera.CameraType = Enum.CameraType.Scriptable
		return
	end

	local head = dummy:FindFirstChild("Head", true)
	local root = dummy:FindFirstChild("HumanoidRootPart", true)
	local targetPart = head or root
	if not targetPart or not targetPart:IsA("BasePart") then return end

	camera.CameraType = Enum.CameraType.Scriptable

	local origin = targetPart.Position + offset
	local look = targetPart.CFrame.LookVector
	if look.Magnitude < 0.001 or look.X ~= look.X then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end

	camera.CFrame = CFrame.lookAt(origin, origin + look)
end

local function rebuildPlaybackToFrame(targetIndex, frames, offset, focusKey, dummies)
	if #frames == 0 then return end
	targetIndex = math.clamp(targetIndex, 1, #frames)
	resetPlaybackDecoder()

	for i = 1, targetIndex do
		local frame = frames[i]
		decodePlaybackFrame(frame)
		decodeCameraFrame(frame, focusKey)
	end

	for playerKey, dummy in pairs(dummies) do
		applyPlayerStateToDummy(dummy, playerKey, offset)
	end

	playbackFrameIndex = targetIndex
	cameraNeedsRefresh = true
end

local function advancePlaybackToFrame(targetIndex, frames, offset, focusKey, dummies)
	if targetIndex <= playbackFrameIndex then return end

	for i = playbackFrameIndex + 1, targetIndex do
		local frame = frames[i]
		decodePlaybackFrame(frame)
		decodeCameraFrame(frame, focusKey)
	end

	for playerKey, dummy in pairs(dummies) do
		applyPlayerStateToDummy(dummy, playerKey, offset)
	end

	playbackFrameIndex = targetIndex
	cameraNeedsRefresh = true
end

local function applyCameraModeChange(timeline)
	if not timeline then return end

	if timeline.CameraMode == "Freecam" then
		if not freecam.enabled then freecamEnable() end
		return
	end

	if freecam.enabled then freecamDisable() end
	local camera = workspace.CurrentCamera
	if camera then camera.CameraType = Enum.CameraType.Scriptable end
	cameraNeedsRefresh = true
end

local function refreshCurrentPOV(timeline, offset)
	if not timeline or not timeline.IsActive or timeline.CameraMode ~= "POV" then return end
	applyPOVCamera(timeline, offset)
	cameraNeedsRefresh = false
end

local function seekPlayback(targetTime)
	local timeline = _G.ReplayTimeline
	if not timeline or not timeline.IsActive or not timeline.Data then return false end

	local frames = timeline.Data.frames or {}
	if #frames == 0 then return false end

	targetTime = math.clamp(tonumber(targetTime) or 0, 0, timeline.TotalDuration)
	local targetIndex = getFrameIndexForTime(frames, targetTime)

	rebuildPlaybackToFrame(targetIndex, frames, dynamicPlaybackOffset, timeline.FocusPlayer, timeline.Dummies or {})
	timeline.CurrentTime = targetTime

	if timeline.CameraMode == "POV" then
		refreshCurrentPOV(timeline, dynamicPlaybackOffset)
	end

	return true
end

_G.SeekReplay = seekPlayback

_G.SetReplayCameraMode = function(mode)
	local timeline = _G.ReplayTimeline
	if not timeline or not timeline.IsActive then return false end
	if mode ~= "POV" and mode ~= "Freecam" then return false end

	if timeline.CameraMode == mode then
		if mode == "POV" then
			cameraNeedsRefresh = true
			refreshCurrentPOV(timeline, dynamicPlaybackOffset)
		end
		return true
	end

	timeline.CameraMode = mode
	applyCameraModeChange(timeline)

	if mode == "POV" then
		refreshCurrentPOV(timeline, dynamicPlaybackOffset)
	end

	return true
end

_G.SetReplayFocusPlayer = function(playerId)
	local timeline = _G.ReplayTimeline
	if not timeline or not timeline.IsActive then return false end

	local focusKey = tostring(playerId)
	if not timeline.Dummies or not timeline.Dummies[focusKey] then
		warn("[Replay] Cannot focus player:", playerId)
		return false
	end

	timeline.FocusPlayer = focusKey
	timeline.TargetPlayer = tonumber(focusKey)

	local frames = timeline.Data and timeline.Data.frames or {}
	if #frames > 0 then
		local targetIndex = getFrameIndexForTime(frames, timeline.CurrentTime)
		rebuildPlaybackToFrame(targetIndex, frames, dynamicPlaybackOffset, focusKey, timeline.Dummies or {})
	end

	cameraNeedsRefresh = true

	if timeline.CameraMode == "POV" then
		refreshCurrentPOV(timeline, dynamicPlaybackOffset)
	end

	return true
end

_G.SetReplayTargetPlayer = _G.SetReplayFocusPlayer
local function stopPlayback()
	if playbackConnection then
		playbackConnection:Disconnect()
		playbackConnection = nil
	end

	local timeline = _G.ReplayTimeline
	if timeline then
		for _, dummy in pairs(timeline.Dummies or {}) do
			if dummy and dummy.Parent then dummy:Destroy() end
		end
		if timeline.Dummy and timeline.Dummy.Parent then timeline.Dummy:Destroy() end
	end

	for _, child in ipairs(workspace:GetChildren()) do
		if string.sub(child.Name, 1, 12) == "ReplayDummy_" or child.Name == "ReplayAudioEmitter" then
			child:Destroy()
		end
	end

	if freecam.enabled then freecamDisable() end
	resetPlaybackDecoder()

	lastAppliedCameraMode = nil
	lastAppliedFocusPlayer = nil
	cameraNeedsRefresh = true

	-- Restore client camera and humanoid focus
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		local char = Player.Character
		if char then
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum then
				camera.CameraSubject = hum
			end
		end
	end

	UserInputService.MouseBehavior = Enum.MouseBehavior.Default

	if _G.ReplayTimeline then
		_G.ReplayTimeline.IsActive = false
		_G.ReplayTimeline.Dummies = {}
		_G.ReplayTimeline.Dummy = nil
	end
	restoreLivePlayers()
end
local function InitializePlayback(data, offset)
	offset = offset or Vector3.zero
	_G.ReplayAutoRecording = false

	if type(data) == "string" then
		data = safeJsonDecode(data)
	end

	if not data or type(data) ~= "table" then
		warn("[ReplaySystem] Playback failed: Invalid replay data structure.")
		return
	end

	local sessionId = HttpService:GenerateGUID(false)
	currentPlaybackSessionId = sessionId

	stopPlayback()

	local frames = data.frames or {}
	if #frames == 0 then
		warn("[ReplaySystem] Playback failed: Replay contains 0 frames.")
		return
	end

	local dummies = createPlaybackDummies(data, sessionId)
	enterReplayWorld()
	if currentPlaybackSessionId ~= sessionId or not dummies then
		return
	end

	local focusKey = tostring(data.recorderUserId or Player.UserId)
	local recorderDummy = dummies[focusKey]

	local totalDuration = tonumber(frames[#frames].t) or 0
	if totalDuration <= 0 then totalDuration = 0.1 end

	local emitter = Instance.new("Part")
	emitter.Name = "ReplayAudioEmitter"
	emitter.Transparency = 1
	emitter.CanCollide = false
	emitter.Anchored = true
	emitter.Position = offset
	emitter.Parent = workspace

	_G.ReplayTimeline = {
		IsActive = true,
		IsPaused = false,
		CurrentTime = 0,
		TotalDuration = totalDuration,
		CameraMode = "POV",
		PlaybackSpeed = 1,
		Dummy = recorderDummy,
		Dummies = dummies,
		Emitter = emitter,
		Data = data,
		Players = buildPlaybackRoster(data),
		FocusPlayer = focusKey,
		TargetPlayer = tonumber(focusKey),
	}

	resetPlaybackDecoder()
	playbackFrameIndex = 1
	lastAppliedCameraMode = "POV"
	lastAppliedFocusPlayer = focusKey
	cameraNeedsRefresh = true

	local camera = workspace.CurrentCamera
	if camera then camera.CameraType = Enum.CameraType.Scriptable end

	rebuildPlaybackToFrame(1, frames, offset, focusKey, dummies)
	refreshCurrentPOV(_G.ReplayTimeline, offset)

	playbackConnection = RunService.RenderStepped:Connect(function(dt)
		if currentPlaybackSessionId ~= sessionId then
			stopPlayback()
			return
		end

		local timeline = _G.ReplayTimeline
		if not timeline or not timeline.IsActive then
			stopPlayback()
			return
		end

		local currentMode = timeline.CameraMode
		if currentMode ~= lastAppliedCameraMode then
			lastAppliedCameraMode = currentMode
			applyCameraModeChange(timeline)
		end

		local currentFocus = tostring(timeline.FocusPlayer or timeline.TargetPlayer or timeline.Data.recorderUserId or Player.UserId)
		if currentFocus ~= lastAppliedFocusPlayer then
			lastAppliedFocusPlayer = currentFocus
			timeline.FocusPlayer = currentFocus
			timeline.TargetPlayer = tonumber(currentFocus)

			local targetIndex = getFrameIndexForTime(frames, timeline.CurrentTime)
			rebuildPlaybackToFrame(targetIndex, frames, offset, currentFocus, timeline.Dummies or {})
			cameraNeedsRefresh = true
		end

		if not timeline.IsPaused then
			timeline.CurrentTime += dt * (timeline.PlaybackSpeed or 1)
		end

		local current = math.clamp(timeline.CurrentTime, 0, totalDuration)
		timeline.CurrentTime = current

		local targetIndex = getFrameIndexForTime(frames, current)

		if targetIndex < playbackFrameIndex then
			rebuildPlaybackToFrame(targetIndex, frames, offset, currentFocus, timeline.Dummies or {})
		elseif targetIndex > playbackFrameIndex then
			advancePlaybackToFrame(targetIndex, frames, offset, currentFocus, timeline.Dummies or {})
		end

		if timeline.CameraMode == "Freecam" then
			if not freecam.enabled then freecamEnable() end
		elseif timeline.CameraMode == "POV" then
			if freecam.enabled then freecamDisable() end
			refreshCurrentPOV(timeline, offset)
		end

		if current >= totalDuration then
			timeline.CurrentTime = totalDuration
			stopPlayback()
			return
		end
	end)
end

_G.InitializePlayback = InitializePlayback
_G.StartReplayPlayback = InitializePlayback

local CAMERA_SAMPLE_INTERVAL = 1 / 15
local lastCameraSampleTime = 0

RunService.RenderStepped:Connect(function()
	if not cameraCaptureEnabled or not activeCameraStreamId then return end

	local now = os.clock()
	if now - lastCameraSampleTime < CAMERA_SAMPLE_INTERVAL then return end
	lastCameraSampleTime = now

	local sample = getCameraSample()
	if sample then
		ReplayEvent:FireServer("CameraSample", activeCameraStreamId, sample)
	end
end)

--------------------------------------------------
-- NETWORKING & EVENTS
--------------------------------------------------

local playbackBuffer = {}

local function processPlaybackData(fullJsonData)
	local data = safeJsonDecode(fullJsonData)
	if not data then return end

	finalizedReplayData = data


	-- 2. Request map setup from server, with a safety timeout so playback never completely hangs
	local offsetConfirmed = false

	ReplayEvent:FireServer("RegeneratePlaybackMap", data.mapSeed, data.mapMode or "Linear", _G.ReplayAutoRecording == true)

	-- Fallback timeout: If the server map generator fails/hangs, force playback on the existing map after 2 seconds
	task.delay(2, function()
		if not offsetConfirmed and finalizedReplayData == data then
			warn("[ReplaySystem] RegeneratePlaybackMap timed out or failed. Starting playback on current local map.")
			offsetConfirmed = true
			finalizedReplayData = nil
			InitializePlayback(data, Vector3.zero)
		end
	end)
end

ReplayEvent.OnClientEvent:Connect(function(command, payload, extra, extra2, extra3)
	if command == "StartCameraCapture" then
		activeCameraStreamId = payload
		cameraCaptureEnabled = true
		return
	elseif command == "StopCameraCapture" then
		cameraCaptureEnabled = false
		activeCameraStreamId = nil
		return
	elseif command == "RemoteCameraSample" then
		local userId = payload
		local sample = extra
		if userId and type(sample) == "table" then
			remoteCameraSamples[tostring(userId)] = sample
		end
		return
	elseif command == "PlaybackChunk" then
		local playbackId = payload
		local chunkIndex = extra
		local totalChunks = extra2
		local chunkData = extra3

		if not playbackBuffer[playbackId] then
			playbackBuffer[playbackId] = {
				chunks = {},
				received = 0,
				total = totalChunks
			}
		end

		local buf = playbackBuffer[playbackId]
		if not buf.chunks[chunkIndex] then
			buf.chunks[chunkIndex] = chunkData
			buf.received += 1
		end

		if buf.received == buf.total then
			local fullData = table.concat(buf.chunks)
			playbackBuffer[playbackId] = nil
			processPlaybackData(fullData)
		end

	elseif command == "ConfirmPlaybackOffset" then
		dynamicPlaybackOffset = Vector3.new(0, payload or 0, 0)
		local dataToPlay = finalizedReplayData
		finalizedReplayData = nil

		if dataToPlay then
			local delayTime = (payload and payload > 0) and 1.5 or 0.1
			task.spawn(function()
				task.wait(delayTime)
				InitializePlayback(dataToPlay, dynamicPlaybackOffset)
			end)
		end
	end
end)

local function watchPlayerDeath(player)
	if deathConnections[player] then deathConnections[player]:Disconnect() end
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	deathConnections[player] = humanoid.Died:Connect(function()
		if not isRecording then return end
		_G.RecordReplayMarker("Death", {
			playerUserId = player.UserId,
			playerName = player.Name,
			displayName = player.DisplayName,
		})
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	watchPlayerDeath(player)
	player.CharacterAdded:Connect(function()
		task.wait(0.1)
		watchPlayerDeath(player)
	end)
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		task.wait(0.1)
		watchPlayerDeath(player)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	if deathConnections[player] then
		deathConnections[player]:Disconnect()
		deathConnections[player] = nil
	end
end)

_G.StartRecordingReplay = StartRecording
_G.StopRecordingReplay = StopAndSaveRecording
_G.IsReplayRecording = function() return isRecording end
_G.SetReplayTime = seekPlayback
_G.RewindReplay = function(seconds)
	local timeline = _G.ReplayTimeline
	return timeline and timeline.IsActive and seekPlayback(timeline.CurrentTime - (tonumber(seconds) or 5)) or false
end
_G.FastForwardReplay = function(seconds)
	local timeline = _G.ReplayTimeline
	return timeline and timeline.IsActive and seekPlayback(timeline.CurrentTime + (tonumber(seconds) or 5)) or false
end
_G.PauseReplay = function()
	local timeline = _G.ReplayTimeline
	if timeline then
		timeline.IsPaused = true
		if timeline.CameraMode == "POV" then
			cameraNeedsRefresh = true
			refreshCurrentPOV(timeline, dynamicPlaybackOffset)
		end
	end
end
_G.ResumeReplay = function()
	local timeline = _G.ReplayTimeline
	if timeline then timeline.IsPaused = false end
end
_G.SetReplaySpeed = function(speed)
	local timeline = _G.ReplayTimeline
	if timeline then timeline.PlaybackSpeed = math.clamp(tonumber(speed) or 1, 0.05, 10) end
end
_G.StopReplay = stopPlayback
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		if replayWorldState.active then
			task.wait()

			setCharacterHidden(character, true)

			replayWorldState.characters[player] = character
		end
	end)
end)
for _, player in ipairs(Players:GetPlayers()) do
	player.CharacterAdded:Connect(function(character)
		if replayWorldState.active then
			task.wait()

			setCharacterHidden(character, true)

			replayWorldState.characters[player] = character
		end
	end)
end