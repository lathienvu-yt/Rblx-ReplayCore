local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local soundsFolder = ReplicatedStorage:WaitForChild("Platformer"):WaitForChild("Sounds")
local playSoundFromSource = require(ReplicatedStorage.Utility.playSoundFromSource)

local ReplayEvent = ReplicatedStorage:WaitForChild("ReplayEvent")
local RoundStateRemote = ReplicatedStorage:WaitForChild("ParkourOpsRemotes"):WaitForChild("RoundState")

local Player = Players.LocalPlayer

local Character
local Humanoid
local RootPart
local Animator

local isRecording = false
local replayData = {}
local startTime = 0
local frameCounter = 0
local frameSeq = 0
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
local KEYFRAME_INTERVAL = 30

local currentPrecision = 3
local captureFrame
local humanoidJumpConnection
local currentPlaybackSessionId = nil
local C = {
	BG          = Color3.fromRGB(15, 15, 15),
	Card        = Color3.fromRGB(28, 28, 28),
	Card2       = Color3.fromRGB(35, 35, 35),
	Border      = Color3.fromRGB(27, 42, 53),

	Accent      = Color3.fromRGB(80, 180, 255),
	AccentD     = Color3.fromRGB(40, 100, 140),

	Text        = Color3.fromRGB(220, 220, 220),
	TextDim     = Color3.fromRGB(140, 140, 140),

	Red         = Color3.fromRGB(200, 50, 50),
	RedDim      = Color3.fromRGB(70, 25, 25),

	Green       = Color3.fromRGB(50, 160, 80),
	GreenDim    = Color3.fromRGB(30, 80, 45),

	Yellow      = Color3.fromRGB(255, 210, 70),
	YellowDim   = Color3.fromRGB(110, 90, 25),

	Orange      = Color3.fromRGB(255, 145, 50),

	Track       = Color3.fromRGB(45, 45, 45),
	White       = Color3.fromRGB(255, 255, 255),
}


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
	CurrentTimer = 0,
	TotalDuration = 0,
	ProcessedUntilChunk = -1,
	ProcessingChunks = {},
	LiveFromChunk = nil,
	LiveUntilChunk = -1,
	ChunkSize = CHUNK_SIZE,
	FPS = 60,
	IsFastload = false,
	ReplayId = nil,
	LiveMatchId = nil,

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

local function isZeroVector(v)
	return type(v) == "table"
		and v[1] == 0
		and v[2] == 0
		and v[3] == 0
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
				local dp = vectorDelta(pos, old.p)
				local dr = vectorDelta(rot, old.r)

				if not isZeroVector(dp) or not isZeroVector(dr) then
					snapshot[partKey] = {
						dp = dp,
						dr = dr,
					}
				end
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

	local serverNow = workspace:GetServerTimeNow()
	local elapsed = serverNow - startTime
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

			local absoluteCharacterFrame = firstFrame
				or isNewCharacter
				or previousPlayerParts[key] == nil
				or frameCounter % KEYFRAME_INTERVAL == 0
				or frameSeq % CHUNK_SIZE == 1

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
		or frameSeq % CHUNK_SIZE == 1

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
		elseif isZeroVector(dp) and isZeroVector(dl) then
			cameraData = {}
		else
			cameraData = { dp = dp, dl = dl }
		end
	end

	previousCameraPos = cameraPos
	previousCameraLook = cameraLook

	local ownKey = getPlayerKey(Player)

	local camerasSnapshot = {}
	if cameraData.pos or cameraData.dp then
		camerasSnapshot[ownKey] = cameraData
	end

	for playerKey, sample in pairs(remoteCameraSamples) do
		if playerKey ~= ownKey
			and type(sample) == "table"
			and sample.pos
			and sample.look
		then
			camerasSnapshot[playerKey] = sample
		end
	end

	-- Build a per-player timer map for the multi-timer overlay.
	-- The recorder's own timer is the smooth locally-interpolated value;
	-- other players' timers come from the server broadcast.
	local timers = {}
	timers[ownKey] = _G.ParkourTimerElapsed or 0
	for uid, elapsed in pairs(_G.ParkourPlayerTimers or {}) do
		local key = tostring(uid)
		if key ~= ownKey then
			timers[key] = elapsed
		end
	end

	frameSeq += 1
	local frame = {
		t = roundNumber(elapsed),
		seq = frameSeq,
		st = serverNow,
		players = playersSnapshot,
		cameras = next(camerasSnapshot) and camerasSnapshot or nil,
		a = actionTag or "",
		timer = _G.ParkourTimerElapsed or 0,
		timers = timers,
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
	frameSeq = 0
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
-- LIVE PLAYBACK STATE
--------------------------------------------------

local livePlayback = {
	active = false,
	sessionId = nil,
	data = nil,
	offset = Vector3.zero,
	connection = nil,
	frameIndex = 1,
	dummies = {},
	focusKey = nil,
}
local livePendingData = nil
local livePlaybackOffset = Vector3.zero
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

	if type(data.players) == "table" then
		for key, pdata in pairs(data.players) do
			if type(pdata) == "table" then
				roster[tostring(key)] = {
					userId = pdata.userId,
					name = pdata.name,
					displayName = pdata.displayName,
					isRecorder = pdata.isRecorder == true,
				}
			end
		end
	end

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

--------------------------------------------------
-- FRAME INTERPOLATION (smooth live playback)
--------------------------------------------------

-- Decode a single frame into an absolute per-part state, given the previous
-- absolute state (so delta-encoded frames resolve correctly).
local function getAbsolutePlayerState(frame, prevState)
	local state = {}
	for partName, partData in pairs(frame.parts or {}) do
		if type(partData) ~= "table" then continue end
		if partData.p and partData.r then
			state[partName] = {
				p = { partData.p[1], partData.p[2], partData.p[3] },
				r = { partData.r[1], partData.r[2], partData.r[3] },
			}
		elseif partData.dp and partData.dr and prevState and prevState[partName] then
			local ps = prevState[partName]
			state[partName] = {
				p = { ps.p[1] + partData.dp[1], ps.p[2] + partData.dp[2], ps.p[3] + partData.dp[3] },
				r = { ps.r[1] + partData.dr[1], ps.r[2] + partData.dr[2], ps.r[3] + partData.dr[3] },
			}
		end
	end
	return state
end

-- Apply an interpolated pose (between stateA and stateB) to a dummy.
local function applyInterpolatedStateToDummy(dummy, stateA, stateB, alpha, offset)
	if not dummy then return end
	for partName, partStateA in pairs(stateA or {}) do
		if not partStateA.p or not partStateA.r then continue end
		local targetPart = dummy:FindFirstChild(partName, true)
		if not targetPart or not targetPart:IsA("BasePart") then continue end

		local partStateB = stateB and stateB[partName]
		local pA = Vector3.new(partStateA.p[1], partStateA.p[2], partStateA.p[3])
		local pB = partStateB and partStateB.p and Vector3.new(partStateB.p[1], partStateB.p[2], partStateB.p[3]) or pA
		local pos = pA:Lerp(pB, alpha)

		local rA = partStateA.r
		local rB = partStateB and partStateB.r or rA
		local cfA = CFrame.fromEulerAnglesXYZ(rA[1], rA[2], rA[3])
		local cfB = CFrame.fromEulerAnglesXYZ(rB[1], rB[2], rB[3])
		local rot = cfA:Lerp(cfB, alpha)

		targetPart.CFrame = CFrame.new(pos + offset) * rot
	end
end

-- Interpolate the POV camera between the current and next decoded camera state.
local function applyInterpolatedCamera(timeline, offset, alpha)
	if not timeline or not timeline.IsActive or timeline.CameraMode ~= "POV" then return end
	local camera = workspace.CurrentCamera
	if not camera then return end

	local focusKey = tostring(timeline.FocusPlayer or timeline.TargetPlayer or timeline.Data.recorderUserId or Player.UserId)
	local camA = playbackCameraState[focusKey]
	if not camA or not camA.pos or not camA.look then return end

	local frames = timeline.Data and timeline.Data.frames or {}
	local targetIndex = getFrameIndexForTime(frames, timeline.CurrentTime)
	local nextFrame = frames[math.min(targetIndex + 1, #frames)]

	local posA = camA.pos
	local lookA = camA.look
	local posB, lookB = posA, lookA

	if nextFrame then
		local camData = nextFrame.cameras and nextFrame.cameras[focusKey]
		if not camData then
			if nextFrame.cameraPos then
				camData = { pos = nextFrame.cameraPos, look = nextFrame.cameraLook }
			elseif nextFrame.cameraDP then
				camData = { dp = nextFrame.cameraDP, dl = nextFrame.cameraDL }
			end
		end
		if camData then
			if camData.pos then
				posB = Vector3.new(camData.pos[1], camData.pos[2], camData.pos[3])
				lookB = Vector3.new(camData.look[1], camData.look[2], camData.look[3])
			elseif camData.dp and camData.dl then
				posB = camA.pos + Vector3.new(camData.dp[1], camData.dp[2], camData.dp[3])
				lookB = camA.look + Vector3.new(camData.dl[1], camData.dl[2], camData.dl[3])
			end
		end
	end

	local pos = posA:Lerp(posB, alpha)
	local look = lookA:Lerp(lookB, alpha)
	if look.Magnitude < 0.001 or look.X ~= look.X then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(pos + offset, pos + offset + look)
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

local function ensureTimelineTables(timeline)
	if type(timeline) ~= "table" then return false end
	timeline.ProcessingChunks = type(timeline.ProcessingChunks) == "table" and timeline.ProcessingChunks or {}
	timeline.ChunkStates = type(timeline.ChunkStates) == "table" and timeline.ChunkStates or {}
	timeline.LoadedChunks = type(timeline.LoadedChunks) == "table" and timeline.LoadedChunks or {}
	timeline.ChunkData = type(timeline.ChunkData) == "table" and timeline.ChunkData or {}
	timeline.RequestedChunks = type(timeline.RequestedChunks) == "table" and timeline.RequestedChunks or {}
	return true
end

local function seekPlayback(targetTime)
	local timeline = _G.ReplayTimeline
	if not timeline or not timeline.IsActive then
		return false
	end

	ensureTimelineTables(timeline)
	targetTime = tonumber(targetTime) or 0

	if timeline.HybridLive then
		local processedUntil = tonumber(timeline.ProcessedUntilTime)
		local liveFrom = tonumber(timeline.LiveFromTime)

		if processedUntil
			and liveFrom
			and liveFrom > processedUntil
			and targetTime > processedUntil
			and targetTime < liveFrom
		then
			if targetTime - processedUntil <= liveFrom - targetTime then
				targetTime = processedUntil
			else
				targetTime = liveFrom
			end
		end
	end

	if timeline.IsFastload then
		local chunkSize = timeline.ChunkSize or CHUNK_SIZE
		local fps = timeline.FPS or 60
		local targetSeq = math.max(1, math.floor(targetTime * fps) + 1)
		local targetChunk = math.floor((targetSeq - 1) / chunkSize)

		local state = timeline.ChunkStates[targetChunk]

		if state == "PROCESSING" then
			-- Processing is a hard hole in the timeline. Snap toward the
			-- nearest valid side.
			local left = timeline.ProcessedUntilChunk or -1
			local right = timeline.LiveFromChunk

			if right
				and targetChunk >= right
			then
				targetChunk = right
			else
				targetChunk = math.max(0, left)
			end
		end

		if timeline.RequestChunk then
			timeline.RequestChunk(targetChunk)
		end

		if not timeline.LoadedChunks[targetChunk] then
			timeline.Buffering = true
			timeline.IsPaused = true
			return false
		end

		local frames = timeline.Data and timeline.Data.frames or {}
		if #frames == 0 then
			return false
		end

		-- Because the recorder forces an absolute keyframe at every sequence
		-- chunk boundary, a direct chunk seek can safely rebuild from the
		-- beginning of that chunk without downloading the entire replay.
		local chunk = timeline.ChunkData[targetChunk]
		if chunk and type(chunk.frames) == "table" and #chunk.frames > 0 then
			resetPlaybackDecoder()

			local focusKey = tostring(
				timeline.FocusPlayer
					or timeline.TargetPlayer
					or timeline.Data.recorderUserId
					or Player.UserId
			)

			for i, frame in ipairs(chunk.frames) do
				decodePlaybackFrame(frame)
				decodeCameraFrame(frame, focusKey)

				if (tonumber(frame.t) or 0) >= targetTime then
					break
				end
			end

			local localIndex = getFrameIndexForTime(
				chunk.frames,
				targetTime
			)

			local frame = chunk.frames[localIndex]
			timeline.CurrentTime =
				math.clamp(
					targetTime,
					tonumber(chunk.frames[1].t) or 0,
					tonumber(chunk.frames[#chunk.frames].t) or targetTime
				)

			playbackFrameIndex =
				math.max(1, localIndex)

			for playerKey, dummy in pairs(timeline.Dummies or {}) do
				applyPlayerStateToDummy(
					dummy,
					playerKey,
					dynamicPlaybackOffset
				)
			end

			if timeline.CameraMode == "POV" then
				refreshCurrentPOV(
					timeline,
					dynamicPlaybackOffset
				)
			end

			timeline.IsPaused = false
			timeline.Buffering = false
			return true
		end
	end

	local frames = timeline.Data and timeline.Data.frames or {}
	if #frames == 0 then
		return false
	end

	targetTime = math.clamp(
		targetTime,
		0,
		timeline.TotalDuration
	)

	local targetIndex = getFrameIndexForTime(
		frames,
		targetTime
	)

	rebuildPlaybackToFrame(
		targetIndex,
		frames,
		dynamicPlaybackOffset,
		timeline.FocusPlayer,
		timeline.Dummies or {}
	)

	timeline.CurrentTime = targetTime

	if timeline.CameraMode == "POV" then
		refreshCurrentPOV(
			timeline,
			dynamicPlaybackOffset
		)
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
		_G.ReplayTimeline.Buffering = false
		_G.ReplayTimeline.Dummies = {}
		_G.ReplayTimeline.Dummy = nil
	end
	restoreLivePlayers()
end
_G.StopPlayback = stopPlayback
_G.StopReplayPlayback = stopPlayback
_G.IsPlaybackActive = function()
	return _G.ReplayTimeline and _G.ReplayTimeline.IsActive == true
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
	local isFastload = data.isFastload == true

	if not isFastload and #frames == 0 then
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

	local totalDuration = tonumber(
		data.totalDuration
			or (frames[#frames] and frames[#frames].t)
			or 0
	) or 0

	if totalDuration <= 0 and not isFastload then
		totalDuration = 0.1
	end

	local emitter = Instance.new("Part")
	emitter.Name = "ReplayAudioEmitter"
	emitter.Transparency = 1
	emitter.CanCollide = false
	emitter.Anchored = true
	emitter.Position = offset
	emitter.Parent = workspace

	local timeline = {
		IsActive = true,
		IsPaused = false,
		CurrentTime = 0,
		CurrentTimer = 0,
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

		IsFastload = isFastload,
		ReplayId = data.replayId or data.ChunkKey,
		LiveMatchId = data.liveMatchId or data.LiveMatchId,
		ChunkSize = tonumber(data.chunkSize) or CHUNK_SIZE,
		FPS = tonumber(data.fps) or 60,

		ProcessedUntilChunk = tonumber(data.ProcessedUntilChunk) or -1,

		ProcessingChunks =
			type(data.ProcessingChunks) == "table"
			and data.ProcessingChunks
			or {},

		ChunkStates = type(data.ChunkStates) == "table" and data.ChunkStates or {},

		LiveFromChunk = tonumber(data.LiveFromChunk),
		LiveUntilChunk = tonumber(data.LiveUntilChunk) or -1,

		ProcessedUntilTime =
			type(data.ProcessedUntilTime) == "number"
			and data.ProcessedUntilTime
			or (not data.IsLive and totalDuration > 0 and totalDuration or nil),

		LiveFromTime = tonumber(data.LiveFromTime),
		LiveUntilTime = tonumber(data.LiveUntilTime),

		LoadedChunks = {},
		ChunkData = {},
		RequestedChunks = {},
		AutoPausedForBuffer = false,

		Buffering = isFastload and #frames == 0,
		IsLive = data.IsLive == true,
	}

	_G.ReplayTimeline = timeline

	if #frames > 0 then
		timeline.ChunkData[0] = {
			frames = frames,
			state = "PROCESSED",
		}
		timeline.LoadedChunks[0] = true
		timeline.ChunkStates[0] = "PROCESSED"
	end

	resetPlaybackDecoder()
	playbackFrameIndex = 1
	lastAppliedCameraMode = "POV"
	lastAppliedFocusPlayer = focusKey
	cameraNeedsRefresh = true

	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	if #frames > 0 then
		rebuildPlaybackToFrame(1, frames, offset, focusKey, dummies)
		refreshCurrentPOV(timeline, offset)
	end

	local function requestChunk(chunkIndex)
		if chunkIndex < 0 then
			return
		end

		local state = timeline.ChunkStates[chunkIndex]

		if state == "PROCESSING" then
			return
		end

		if timeline.LoadedChunks[chunkIndex]
			or timeline.RequestedChunks[chunkIndex]
		then
			return
		end

		timeline.RequestedChunks[chunkIndex] = true

		ReplayEvent:FireServer(
			"RequestChunk",
			timeline.ReplayId,
			chunkIndex,
			timeline.LiveMatchId
		)
	end

	local function requestStatus()
		if not timeline.ReplayId then
			return
		end

		ReplayEvent:FireServer(
			"RequestReplayStatus",
			timeline.ReplayId,
			timeline.LiveMatchId
		)
	end

	local function rebuildLoadedFrames()
		local merged = {}

		local indexes = {}
		for index in pairs(timeline.ChunkData) do
			table.insert(indexes, index)
		end

		table.sort(indexes)

		for _, index in ipairs(indexes) do
			local chunk = timeline.ChunkData[index]
			for _, frame in ipairs(chunk.frames or {}) do
				table.insert(merged, frame)
			end
		end

		table.sort(merged, function(a, b)
			return (tonumber(a.t) or 0) < (tonumber(b.t) or 0)
		end)

		timeline.Data.frames = merged
		return merged
	end

	timeline.RequestChunk = requestChunk
	timeline.RequestStatus = requestStatus
	timeline.RebuildLoadedFrames = rebuildLoadedFrames

	-- Start with the first chunk and immediately AOT a few future chunks.
	if isFastload then
		requestChunk(0)

		for i = 1, 3 do
			requestChunk(i)
		end

		if timeline.LiveMatchId or timeline.IsLive then
			requestStatus()
		end

		-- Buffering safety watchdog
		task.spawn(function()
			local bufferStart = os.clock()
			while currentPlaybackSessionId == sessionId do
				task.wait(0.5)
				local curTimeline = _G.ReplayTimeline
				if not curTimeline or not curTimeline.IsActive then break end
				local loaded = curTimeline.Data and curTimeline.Data.frames or {}
				if #loaded > 0 then break end
				if os.clock() - bufferStart > 6 then
					warn("[ReplaySystem] Fastload initial chunk buffering timed out. Aborting playback.")
					stopPlayback()
					if _G.SetReplayStatus then
						_G.SetReplayStatus("Status: Replay Load Timed Out", C.Red, C.Red)
					end
					break
				end
			end
		end)
	end

	playbackConnection = RunService.RenderStepped:Connect(function(dt)
		if currentPlaybackSessionId ~= sessionId then
			stopPlayback()
			return
		end

		local currentTimeline = _G.ReplayTimeline
		if not currentTimeline or not currentTimeline.IsActive then
			stopPlayback()
			return
		end

		local currentMode = currentTimeline.CameraMode
		if currentMode ~= lastAppliedCameraMode then
			lastAppliedCameraMode = currentMode
			applyCameraModeChange(currentTimeline)
		end

		local currentFocus = tostring(
			currentTimeline.FocusPlayer
				or currentTimeline.TargetPlayer
				or currentTimeline.Data.recorderUserId
				or Player.UserId
		)

		if currentFocus ~= lastAppliedFocusPlayer then
			lastAppliedFocusPlayer = currentFocus
			currentTimeline.FocusPlayer = currentFocus
			currentTimeline.TargetPlayer = tonumber(currentFocus)

			local loadedFrames = currentTimeline.Data.frames or {}
			if #loadedFrames > 0 then
				local targetIndex = getFrameIndexForTime(
					loadedFrames,
					currentTimeline.CurrentTime
				)

				rebuildPlaybackToFrame(
					targetIndex,
					loadedFrames,
					offset,
					currentFocus,
					currentTimeline.Dummies or {}
				)
			end

			cameraNeedsRefresh = true
		end

		local loadedFrames = currentTimeline.Data.frames or {}

		if currentTimeline.IsFastload and #loadedFrames == 0 then
			currentTimeline.Buffering = true
			if not currentTimeline.IsPaused then
				currentTimeline.CurrentTime = 0
			end

			requestChunk(0)
			return
		end

		if not currentTimeline.IsPaused then
			currentTimeline.CurrentTime += dt * (currentTimeline.PlaybackSpeed or 1)
		end

		local knownDuration = currentTimeline.TotalDuration

		if currentTimeline.IsFastload then
			local lastLoaded = loadedFrames[#loadedFrames]
			local loadedDuration = tonumber(lastLoaded and lastLoaded.t) or 0

			if loadedDuration > 0 then
				-- Never advance through a gap in loaded data.
				if currentTimeline.CurrentTime >= loadedDuration
					and knownDuration > loadedDuration
				then
					currentTimeline.CurrentTime = loadedDuration
					currentTimeline.Buffering = true
					currentTimeline.AutoPausedForBuffer = currentTimeline.IsLive == true
					currentTimeline.IsPaused = true
				end
			end
		end

		local current = math.clamp(
			currentTimeline.CurrentTime,
			0,
			math.max(knownDuration, 0.1)
		)

		currentTimeline.CurrentTime = current

		if #loadedFrames == 0 then
			currentTimeline.Buffering = true
			return
		end

		local targetIndex = getFrameIndexForTime(
			loadedFrames,
			current
		)

		if targetIndex < playbackFrameIndex then
			rebuildPlaybackToFrame(
				targetIndex,
				loadedFrames,
				offset,
				currentFocus,
				currentTimeline.Dummies or {}
			)
		elseif targetIndex > playbackFrameIndex then
			advancePlaybackToFrame(
				targetIndex,
				loadedFrames,
				offset,
				currentFocus,
				currentTimeline.Dummies or {}
			)
		end

		currentTimeline.CurrentTimer =
			loadedFrames[targetIndex]
			and loadedFrames[targetIndex].timer
			or 0

		local nextFrame =
			loadedFrames[math.min(targetIndex + 1, #loadedFrames)]

		local currentFrame = loadedFrames[targetIndex]
		local frameStart = currentFrame and currentFrame.t or 0
		local frameEnd = nextFrame and nextFrame.t or frameStart
		local alpha = 0

		if frameEnd > frameStart then
			alpha = math.clamp(
				(current - frameStart) / (frameEnd - frameStart),
				0,
				1
			)
		end

		local interpolatedTimers = {}

		for key, elapsed in pairs(
			(currentFrame and currentFrame.timers) or {}
			) do
			local nextVal =
				nextFrame
				and nextFrame.timers
				and nextFrame.timers[key]

			if nextVal then
				interpolatedTimers[key] =
					elapsed + (nextVal - elapsed) * alpha
			else
				interpolatedTimers[key] = elapsed
			end
		end

		currentTimeline.CurrentTimers = interpolatedTimers

		if currentTimeline.CameraMode == "Freecam" then
			if not freecam.enabled then
				freecamEnable()
			end
		elseif currentTimeline.CameraMode == "POV" then
			if freecam.enabled then
				freecamDisable()
			end
			applyInterpolatedCamera(
				currentTimeline,
				offset,
				alpha
			)
		end

		-- AOT. Never request a PROCESSING chunk.
		if currentTimeline.IsFastload then
			local currentChunkIndex =
				math.floor(
					((tonumber(currentFrame and currentFrame.seq) or 1) - 1)
					/ currentTimeline.ChunkSize
				)

			for ahead = 1, 3 do
				local targetChunk = currentChunkIndex + ahead
				if currentTimeline.ChunkStates[targetChunk] ~= "PROCESSING" then
					requestChunk(targetChunk)
				end
			end

			if (currentTimeline.LiveMatchId or currentTimeline.IsLive)
				and os.clock() % 1 < dt
			then
				requestStatus()
			end
		end

		if not currentTimeline.IsLive
			and not currentTimeline.IsFastload
			and knownDuration > 0
			and current >= knownDuration
		then
			currentTimeline.CurrentTime = knownDuration
			stopPlayback()
			return
		end
	end)
end
_G.SeekReplayLive = function()
	local timeline = _G.ReplayTimeline
	if not timeline or not timeline.IsActive or not timeline.IsLive then
		return false
	end
	ensureTimelineTables(timeline)
	local target = tonumber(timeline.LiveUntilTime) or tonumber(timeline.TotalDuration) or 0
	timeline.IsPaused = false
	timeline.Buffering = false
	timeline.AutoPausedForBuffer = false
	return seekPlayback(target)
end

_G.InitializePlayback = InitializePlayback
_G.StartReplayPlayback = InitializePlayback

--------------------------------------------------
-- LIVE PLAYBACK (LivePlayCore spectator)
--------------------------------------------------

local function stopLivePlayback()
	if livePlayback.connection then
		livePlayback.connection:Disconnect()
		livePlayback.connection = nil
	end
	livePlayback.active = false
	livePlayback.data = nil
	livePlayback.dummies = {}
	stopPlayback()
	if _G.SetReplayStatus then _G.SetReplayStatus("Status: Live playback ended", C.TextDim, C.TextDim) end
end

local function InitializeLivePlayback(data, offset)
	offset = offset or Vector3.zero
	_G.ReplayAutoRecording = false

	local frames = data and data.frames or {}
	if #frames == 0 then
		warn("[LivePlayCore] Live playback failed: no frames in snapshot.")
		return
	end

	local sessionId = HttpService:GenerateGUID(false)
	livePlayback.sessionId = sessionId
	currentPlaybackSessionId = sessionId
	livePlayback.active = true
	livePlayback.data = data
	livePlayback.offset = offset
	livePlayback.frameIndex = 1
	livePlayback.focusKey = tostring(data.recorderUserId or Player.UserId)

	stopPlayback()

	local dummies = createPlaybackDummies(data, sessionId)
	enterReplayWorld()
	if livePlayback.sessionId ~= sessionId or not dummies then
		return
	end
	livePlayback.dummies = dummies

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
		CurrentTimer = 0,
		TotalDuration = totalDuration,
		CameraMode = "POV",
		PlaybackSpeed = 1,
		Dummy = dummies[livePlayback.focusKey],
		Dummies = dummies,
		Emitter = emitter,
		Data = data,
		Players = buildPlaybackRoster(data),
		FocusPlayer = livePlayback.focusKey,
		TargetPlayer = tonumber(livePlayback.focusKey),
		IsLive = true,
		HybridLive = type(data.replayKey) == "string" and data.replayKey ~= "",
		ReplayId = data.replayKey,
		LiveMatchId = data.matchId,
		ProcessedUntilChunk = -1,
		ProcessingChunks = {},
		LiveFromChunk = nil,
		LiveUntilChunk = -1,
		ProcessedUntilTime = nil,
		LiveFromTime = nil,
		LiveUntilTime = totalDuration,
	}
	playbackFrameIndex = 1
	lastAppliedCameraMode = "POV"
	lastAppliedFocusPlayer = livePlayback.focusKey
	cameraNeedsRefresh = true

	local camera = workspace.CurrentCamera
	if camera then camera.CameraType = Enum.CameraType.Scriptable end

	rebuildPlaybackToFrame(1, frames, offset, livePlayback.focusKey, dummies)
	refreshCurrentPOV(_G.ReplayTimeline, offset)

	if _G.ReplayTimeline.HybridLive and _G.ReplayTimeline.ReplayId and _G.ReplayTimeline.LiveMatchId then
		ReplayEvent:FireServer(
			"RequestReplayStatus",
			_G.ReplayTimeline.ReplayId,
			_G.ReplayTimeline.LiveMatchId
		)
	end

	if _G.SetReplayStatus then _G.SetReplayStatus("Status: Live playback started", C.Green, C.Green) end

	livePlayback.connection = RunService.RenderStepped:Connect(function(dt)
		if livePlayback.sessionId ~= sessionId then
			stopLivePlayback()
			return
		end

		local timeline = _G.ReplayTimeline
		if not timeline or not timeline.IsActive then
			stopLivePlayback()
			return
		end

		-- AppendLiveFrames mutates livePlayback.data.frames. Never keep using
		-- the snapshot table captured when playback started, otherwise the live
		-- renderer will receive chunks but continue playing against stale data.
		frames = livePlayback.data and livePlayback.data.frames or frames

		local currentMode = timeline.CameraMode
		if currentMode ~= lastAppliedCameraMode then
			lastAppliedCameraMode = currentMode
			applyCameraModeChange(timeline)
		end

		local currentFocus = tostring(timeline.FocusPlayer or timeline.TargetPlayer or livePlayback.focusKey or Player.UserId)
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

		if timeline.HybridLive then
			local processedUntil = tonumber(timeline.ProcessedUntilTime)
			local liveFrom = tonumber(timeline.LiveFromTime)

			if processedUntil
				and liveFrom
				and liveFrom > processedUntil
				and timeline.CurrentTime > processedUntil
				and timeline.CurrentTime < liveFrom
			then
				timeline.CurrentTime = liveFrom
			end
		end

		local current = math.clamp(timeline.CurrentTime, 0, timeline.TotalDuration)
		timeline.CurrentTime = current

		local targetIndex = getFrameIndexForTime(frames, current)

		-- Decode frames up to targetIndex so playbackPlayerState stays in sync.
		if targetIndex < playbackFrameIndex then
			resetPlaybackDecoder()
			for i = 1, targetIndex do
				decodePlaybackFrame(frames[i])
				decodeCameraFrame(frames[i], currentFocus)
			end
			playbackFrameIndex = targetIndex
		elseif targetIndex > playbackFrameIndex then
			for i = playbackFrameIndex + 1, targetIndex do
				decodePlaybackFrame(frames[i])
				decodeCameraFrame(frames[i], currentFocus)
			end
			playbackFrameIndex = targetIndex
		end

		-- Smoothly interpolate each dummy between the current and next frame.
		local dummies = timeline.Dummies or {}
		local currentFrame = frames[targetIndex]
		local nextFrame = frames[math.min(targetIndex + 1, #frames)]
		local alpha = 0
		if nextFrame and currentFrame and nextFrame.t and currentFrame.t and nextFrame.t > currentFrame.t then
			alpha = math.clamp((current - currentFrame.t) / (nextFrame.t - currentFrame.t), 0, 1)
		end

		for playerKey, dummy in pairs(dummies) do
			local stateA = playbackPlayerState[playerKey]
			local stateB = nextFrame and getAbsolutePlayerState(nextFrame, stateA) or stateA
			applyInterpolatedStateToDummy(dummy, stateA, stateB, alpha, offset)
		end

		local currentFrame = frames[targetIndex]
		timeline.CurrentTimer = currentFrame and currentFrame.timer or 0

		local nextFrame = frames[math.min(targetIndex + 1, #frames)]
		local frameStart = currentFrame and currentFrame.t or 0
		local frameEnd = nextFrame and nextFrame.t or frameStart
		local alpha = 0
		if frameEnd > frameStart then
			alpha = math.clamp((current - frameStart) / (frameEnd - frameStart), 0, 1)
		end

		local interpolatedTimers = {}
		for key, elapsed in pairs((currentFrame and currentFrame.timers) or {}) do
			local nextVal = nextFrame and nextFrame.timers and nextFrame.timers[key]
			if nextVal then
				interpolatedTimers[key] = elapsed + (nextVal - elapsed) * alpha
			else
				interpolatedTimers[key] = elapsed
			end
		end
		timeline.CurrentTimers = interpolatedTimers

		if timeline.CameraMode == "Freecam" then
			if not freecam.enabled then freecamEnable() end
		elseif timeline.CameraMode == "POV" then
			if freecam.enabled then freecamDisable() end
			refreshCurrentPOV(timeline, offset)
		end

		-- Hold at the latest available frame until more live data arrives.
		if current >= timeline.TotalDuration then
			timeline.CurrentTime = timeline.TotalDuration
		end
	end)
end

local function AppendLiveFrames(frames, metrics)
	if not livePlayback.active or not livePlayback.data then
		return
	end

	if type(frames) ~= "table" or #frames == 0 then
		return
	end

	local timeline = _G.ReplayTimeline
	if not timeline or not timeline.IsActive then
		return
	end

	local data = livePlayback.data
	ensureTimelineTables(timeline)

	local seen = {}
	for _, existing in ipairs(data.frames or {}) do
		if type(existing) == "table" then
			local key = existing.seq ~= nil and "s:" .. tostring(existing.seq) or "t:" .. tostring(existing.t)
			seen[key] = true
		end
	end

	for _, frame in ipairs(frames) do
		if type(frame) == "table" then
			local key = frame.seq ~= nil and "s:" .. tostring(frame.seq) or "t:" .. tostring(frame.t)
			if not seen[key] then
				seen[key] = true
				table.insert(data.frames, frame)
			end
		end
	end

	-- Keep chronological order.
	table.sort(data.frames, function(a, b)
		return (tonumber(a.t) or 0) < (tonumber(b.t) or 0)
	end)

	--------------------------------------------------
	-- Register incoming frames as loaded LIVE chunks
	--------------------------------------------------

	local chunkSize = tonumber(timeline.ChunkSize) or CHUNK_SIZE
	local fps = tonumber(timeline.FPS) or 60

	local grouped = {}

	for _, frame in ipairs(frames) do
		local t = tonumber(frame.t) or 0

		-- Convert time -> sequence -> chunk.
		local seq = math.max(1, math.floor(t * fps) + 1)
		local chunkIndex = math.floor((seq - 1) / chunkSize)

		grouped[chunkIndex] = grouped[chunkIndex] or {}
		table.insert(grouped[chunkIndex], frame)
	end

	for chunkIndex, chunkFrames in pairs(grouped) do
		table.sort(chunkFrames, function(a, b)
			return (tonumber(a.t) or 0) < (tonumber(b.t) or 0)
		end)

		-- Merge with an already received chunk instead of replacing it.
		local existing = timeline.ChunkData[chunkIndex]

		if existing and type(existing.frames) == "table" then
			local chunkSeen = {}
			for _, existingFrame in ipairs(existing.frames) do
				local key = existingFrame.seq ~= nil and "s:" .. tostring(existingFrame.seq) or "t:" .. tostring(existingFrame.t)
				chunkSeen[key] = true
			end

			for _, frame in ipairs(chunkFrames) do
				local key = frame.seq ~= nil and "s:" .. tostring(frame.seq) or "t:" .. tostring(frame.t)
				if not chunkSeen[key] then
					chunkSeen[key] = true
					table.insert(existing.frames, frame)
				end
			end

			table.sort(existing.frames, function(a, b)
				return (tonumber(a.t) or 0) < (tonumber(b.t) or 0)
			end)

			existing.state = "LIVE"
		else
			timeline.ChunkData[chunkIndex] = {
				frames = chunkFrames,
				state = "LIVE",
				firstSeq = nil,
				lastSeq = nil,
			}
		end

		timeline.LoadedChunks[chunkIndex] = true
		timeline.ChunkStates[chunkIndex] = "LIVE"
		timeline.RequestedChunks[chunkIndex] = nil
		timeline.ProcessingChunks[chunkIndex] = nil
	end

	--------------------------------------------------
	-- Update live boundaries
	--------------------------------------------------

	local firstFrame = data.frames[1]
	local lastFrame = data.frames[#data.frames]

	if firstFrame then
		local firstTime = tonumber(firstFrame.t) or 0

		if timeline.LiveFromTime == nil then
			timeline.LiveFromTime = firstTime
		else
			timeline.LiveFromTime = math.min(
				timeline.LiveFromTime,
				firstTime
			)
		end
	end

	if lastFrame then
		local lastTime = tonumber(lastFrame.t) or 0

		timeline.TotalDuration = math.max(
			timeline.TotalDuration or 0,
			lastTime
		)

		timeline.LiveUntilTime = lastTime

		local lastSeq = math.max(
			1,
			math.floor(lastTime * fps) + 1
		)

		local lastChunk = math.floor(
			(lastSeq - 1) / chunkSize
		)

		timeline.LiveUntilChunk = math.max(
			tonumber(timeline.LiveUntilChunk) or -1,
			lastChunk
		)

		if timeline.LiveFromChunk == nil then
			local firstTimeValue = tonumber(firstFrame.t) or 0
			local firstSeq = math.max(
				1,
				math.floor(firstTimeValue * fps) + 1
			)

			timeline.LiveFromChunk = math.floor(
				(firstSeq - 1) / chunkSize
			)
		end
	end

	--------------------------------------------------
	-- Rebuild frame index if available
	--------------------------------------------------

	if timeline.RebuildLoadedFrames then
		timeline.RebuildLoadedFrames()
	end

	if timeline.IsLive and timeline.Buffering then
		local loadedFrames = timeline.Data and timeline.Data.frames or {}
		local lastLoaded = loadedFrames[#loadedFrames]
		local loadedDuration = tonumber(lastLoaded and lastLoaded.t) or 0
		if loadedDuration > (timeline.CurrentTime or 0) then
			timeline.Buffering = false
			timeline.IsPaused = false
			timeline.AutoPausedForBuffer = false
		end
	end

	if metrics then
		timeline.LiveMetrics = metrics
	end

	if _G.SetReplayStatus then
		_G.SetReplayStatus(
			"Status: Live frames: " .. tostring(#data.frames),
			C.Accent,
			C.Accent
		)
	end
end

local function EndLivePlayback()
	stopLivePlayback()
end

local function handleLiveSnapshot(snapshot)
	if not snapshot or type(snapshot) ~= "table" then return end
	local frames = snapshot.frames or {}
	if type(snapshot.frames) ~= "table" then
		warn(
			"[LivePlayCore] Snapshot has no frames table."
		)
		return
	end

	if #snapshot.frames == 0 then
		warn(
			"[LivePlayCore] Snapshot frame array is EMPTY:",
			"liveUntilChunk =", snapshot.LiveUntilChunk,
			"liveUntilTime =", snapshot.LiveUntilTime
		)
		return
	end

	print(
		"[LivePlayCore] Snapshot accepted."
	)

	if _G.SetReplayStatus then _G.SetReplayStatus("Status: Processing live snapshot...", C.Yellow, C.Yellow) end

	livePendingData = snapshot
	ReplayEvent:FireServer("RegeneratePlaybackMap", snapshot.mapSeed, snapshot.mapMode or "Linear", true)

	task.delay(2, function()
		if livePendingData == snapshot then
			livePendingData = nil
			InitializeLivePlayback(snapshot, Vector3.zero)
		end
	end)
end

_G.InitializeLivePlayback = InitializeLivePlayback
_G.AppendLiveFrames = AppendLiveFrames
_G.EndLivePlayback = EndLivePlayback

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

ReplayEvent.OnClientEvent:Connect(function(command, payload, extra, extra2, extra3, extra4, extra5)
	if command == "PlaybackFailed" then
		local reason = tostring(payload or "Playback failed.")
		warn("[ReplaySystem] " .. reason)
		stopPlayback()
		if _G.SetReplayStatus then
			_G.SetReplayStatus("Status: " .. reason, C.Red, C.Red)
		end
		return
	elseif command == "LivePlayCoreData" then
		local kind = payload
		local data = extra
		if kind == "snapshot" then
			handleLiveSnapshot(data)
		elseif kind == "frames" then
			AppendLiveFrames(data and data.frames, data and data.metrics)
		elseif kind == "end" then
			EndLivePlayback()
		end
		return
	elseif command == "LivePlayCoreStatus" then
		print("[LivePlayCore] Status:", payload)
		return
	elseif command == "StartCameraCapture" then
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
	elseif command == "ReceiveChunk" then
		local replayId = payload
		local chunkIndex = tonumber(extra)
		local chunkFrames = extra2
		local state = extra3
		local firstSeq = extra4
		local lastSeq = extra5

		local timeline = _G.ReplayTimeline
		if not timeline
			or not timeline.IsActive
			or not timeline.IsFastload
			or timeline.ReplayId ~= replayId
			or not chunkIndex
		then
			return
		end

		ensureTimelineTables(timeline)
		timeline.RequestedChunks[chunkIndex] = nil

		if state == "PROCESSING" then
			timeline.ChunkStates[chunkIndex] = "PROCESSING"
			timeline.ProcessingChunks[chunkIndex] = true
			return
		end

		if type(chunkFrames) ~= "table" or #chunkFrames == 0 then
			return
		end

		timeline.ChunkData[chunkIndex] = {
			frames = chunkFrames,
			state = state or "LIVE",
			firstSeq = firstSeq,
			lastSeq = lastSeq,
		}

		timeline.ChunkStates[chunkIndex] =
			state or "LIVE"

		timeline.LoadedChunks[chunkIndex] = true
		timeline.ProcessingChunks[chunkIndex] = nil

		if timeline.RebuildLoadedFrames then
			timeline.RebuildLoadedFrames()
		else
			for _, frame in ipairs(chunkFrames) do
				table.insert(timeline.Data.frames, frame)
			end

			table.sort(
				timeline.Data.frames,
				function(a, b)
					return (a.t or 0) < (b.t or 0)
				end
			)
		end

		local lastFrame = chunkFrames[#chunkFrames]

		if lastFrame and lastFrame.t then
			timeline.TotalDuration =
				math.max(
					timeline.TotalDuration or 0,
					tonumber(lastFrame.t) or 0
				)
		end

		local currentChunkIndex =
			math.floor(
				math.max(
					0,
					math.floor(
						((timeline.CurrentTime or 0)
							* (timeline.FPS or 60))
						/ (timeline.ChunkSize or CHUNK_SIZE)
					)
				)
			)

		if timeline.Buffering
			and timeline.LoadedChunks[currentChunkIndex]
		then
			timeline.Buffering = false
			timeline.IsPaused = false

			local frames = timeline.Data.frames or {}
			if #frames > 0 then
				local targetIndex =
					getFrameIndexForTime(
						frames,
						timeline.CurrentTime
					)

				rebuildPlaybackToFrame(
					targetIndex,
					frames,
					dynamicPlaybackOffset,
					timeline.FocusPlayer,
					timeline.Dummies or {}
				)
			end
		end

		return

	elseif command == "ChunkUnavailable" then
		local replayId = payload
		local chunkIndex = tonumber(extra)
		local state = extra2

		local timeline = _G.ReplayTimeline
		if not timeline
			or timeline.ReplayId ~= replayId
		then
			return
		end

		ensureTimelineTables(timeline)
		timeline.RequestedChunks[chunkIndex] = nil

		if state == "PROCESSING" then
			timeline.ChunkStates[chunkIndex] = "PROCESSING"
			timeline.ProcessingChunks[chunkIndex] = true
		elseif chunkIndex == 0 and (#(timeline.Data and timeline.Data.frames or {})) == 0 then
			warn("[ReplaySystem] Replay chunk 0 is unavailable (" .. tostring(state) .. "). Aborting playback.")
			stopPlayback()
			if _G.SetReplayStatus then
				_G.SetReplayStatus("Status: Replay Not Found in DataStore", C.Red, C.Red)
			end
		end

		return

	elseif command == "ReplayStatus" then
		local status = payload
		local timeline = _G.ReplayTimeline

		if not timeline
			or not timeline.IsActive
			or type(status) ~= "table"
			or status.replayId ~= timeline.ReplayId
		then
			return
		end

		timeline.ProcessedUntilChunk =
			tonumber(status.processedUntilChunk) or -1

		timeline.LiveFromChunk =
			tonumber(status.liveFromChunk)

		timeline.LiveUntilChunk =
			tonumber(status.liveUntilChunk) or -1

		timeline.TotalDuration =
			tonumber(status.totalDuration)
			or timeline.TotalDuration

		timeline.ProcessedUntilTime =
			tonumber(status.processedUntilTime)

		timeline.LiveFromTime =
			tonumber(status.liveFromTime)

		timeline.LiveUntilTime =
			tonumber(status.liveUntilTime)

		timeline.ChunkSize =
			tonumber(status.chunkSize)
			or timeline.ChunkSize

		timeline.FPS =
			tonumber(status.fps)
			or timeline.FPS

		timeline.IsLive =
			status.liveUntilChunk
			and status.liveUntilChunk >= 0
			or timeline.IsLive
		ensureTimelineTables(timeline)

		if type(status.chunkStates) == "table" then
			timeline.ChunkStates = status.chunkStates
		end

		table.clear(timeline.ProcessingChunks)

		for index, value in pairs(
			status.processingChunks or {}
			) do
			local numericIndex = tonumber(index)
			if numericIndex then
				timeline.ProcessingChunks[numericIndex] = value == true
				timeline.ChunkStates[numericIndex] = "PROCESSING"
			end
		end


		local processedUntil = tonumber(timeline.ProcessedUntilChunk)

		if processedUntil and processedUntil >= 0 then
			for index = 0, processedUntil do
				if timeline.ChunkStates[index] ~= "LIVE" then
					timeline.ChunkStates[index] = "PROCESSED"
				end
			end
		end

		ensureTimelineTables(timeline)

		local liveFrom = tonumber(timeline.LiveFromChunk)
		local liveUntil = tonumber(timeline.LiveUntilChunk)

		if liveFrom and liveUntil and liveUntil >= liveFrom then
			for index = liveFrom, liveUntil do
				if not timeline.ProcessingChunks[index]
					and timeline.ChunkStates[index] ~= "PROCESSED"
				then
					timeline.ChunkStates[index] = "LIVE"
				end
			end
		end

		return
	elseif command == "PlaybackChunk" then
		local playbackId = payload
		local chunkIndex = extra
		local totalChunks = extra2
		local chunkData = extra3
		print(
			"[ReplaySystem] RECEIVED PlaybackChunk:",
			payload,
			"chunk:",
			extra,
			"/",
			extra2,
			"bytes:",
			type(extra3) == "string" and #extra3 or "INVALID"
		)
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
			print(
				"[ReplaySystem] ALL PLAYBACK CHUNKS RECEIVED:",
				playbackId,
				"chunks:",
				buf.total
			)

			local fullData = table.concat(buf.chunks)

			print(
				"[ReplaySystem] Full replay payload:",
				#fullData,
				"bytes"
			)

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

		-- Live playback: if a live snapshot is waiting for the map, start it.
		if livePendingData then
			local liveData = livePendingData
			livePendingData = nil
			livePlaybackOffset = dynamicPlaybackOffset
			local delayTime = (payload and payload > 0) and 1.5 or 0.1
			task.spawn(function()
				task.wait(delayTime)
				InitializeLivePlayback(liveData, livePlaybackOffset)
			end)
		end
	end
end)

-- Signal the server that the live playback client handler is connected,
-- so the server->server->client relay test knows when it is safe to send.
ReplayEvent:FireServer("LivePlaybackReady")

RoundStateRemote.OnClientEvent:Connect(function(state, mode, mapMode, seed, isMultiplayer)
	if _G.ReplayTimeline and _G.ReplayTimeline.IsActive then return end

	if state == "Active" or state == "Started" or state == "InGame" or state == "start" then
		_G.ReplayAutoRecording = true
		StartRecording(seed, mapMode, isMultiplayer == true)
	elseif state == "Ended" or state == "Intermission" or state == "Lobby" or state == "results" then
		if isRecording then
			StopAndSaveRecording("Round state ended")
			_G.ReplayAutoRecording = false
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
