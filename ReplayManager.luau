local DataStoreService = game:GetService("DataStoreService")
local ReplayDataStore = DataStoreService:GetDataStore("ReplayChunks_v2")

local ProfileService = require(game.ServerScriptService.ParkourOps.ProfileService)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local EncodingService = game:GetService("EncodingService")

local roundRecorder = {}
local ReplayEvent = ReplicatedStorage:WaitForChild("ReplayEvent")

local ZSTD_LEVEL = 3
local PROTOCOL = "RCP4" 
local SHARED_SAVE_TIMEOUT = 300
local MAX_REPLAYS = 10
local CHUNK_NET_SIZE = 150000 -- ~150 KB chunk size to safely fit 256 KB RemoteEvent limit

local SecretStore = DataStoreService:GetDataStore("ReplaySecret_v1")
local serverSecret = nil    
local legacyKeys = {}       

local function loadKeyFromStore(keyName)
	local success, result = pcall(function()
		return SecretStore:GetAsync(keyName)
	end)
	if success and result and type(result) == "string" and #result >= 16 then
		return buffer.fromstring(result)
	end
	return nil
end

local function deleteReplayChunk(chunkKey)
	if not chunkKey then return true end
	local success, err = pcall(function()
		ReplayDataStore:RemoveAsync(chunkKey)
	end)
	if not success then
		warn("[ReplayManager] Failed to delete replay chunk:", chunkKey, err)
		return false
	end
	return true
end

local function initServerSecret()
	if serverSecret then return serverSecret end

	local success, result = pcall(function()
		return SecretStore:UpdateAsync("key", function(oldValue)
			if oldValue and type(oldValue) == "string" and #oldValue >= 16 then
				return oldValue
			end
			local guid1 = HttpService:GenerateGUID(false)
			local guid2 = HttpService:GenerateGUID(false)
			return guid1 .. guid2
		end)
	end)
	if success and result and type(result) == "string" and #result >= 16 then
		serverSecret = buffer.fromstring(result)
	else
		warn("[ReplayManager] Failed to initialize server secret: " .. tostring(result))
	end

	for i = 0, 9 do
		local backupKey = loadKeyFromStore("key_v" .. i)
		if backupKey then table.insert(legacyKeys, backupKey) end
	end

	return serverSecret
end

local function b64Encode(buf: buffer): string
	return buffer.tostring(EncodingService:Base64Encode(buf))
end

local function b64Decode(str: string): buffer
	return EncodingService:Base64Decode(buffer.fromstring(str))
end

local HMAC_BLOCK = 64
local function hmacSha256(keyBuf: buffer, msgBuf: buffer): buffer
	if buffer.len(keyBuf) > HMAC_BLOCK then
		keyBuf = EncodingService:ComputeBufferHash(keyBuf, Enum.HashAlgorithm.Sha256)
	end

	local paddedKey = buffer.create(HMAC_BLOCK)
	buffer.copy(paddedKey, 0, keyBuf, 0, buffer.len(keyBuf))

	local ipad = buffer.create(HMAC_BLOCK)
	local opad = buffer.create(HMAC_BLOCK)
	for i = 0, HMAC_BLOCK - 1 do
		local k = buffer.readu8(paddedKey, i)
		buffer.writeu8(ipad, i, bit32.bxor(k, 0x36))
		buffer.writeu8(opad, i, bit32.bxor(k, 0x5c))
	end

	local msgLen = buffer.len(msgBuf)
	local inner = buffer.create(HMAC_BLOCK + msgLen)
	buffer.copy(inner, 0, ipad, 0, HMAC_BLOCK)
	buffer.copy(inner, HMAC_BLOCK, msgBuf, 0, msgLen)
	local innerHash = EncodingService:ComputeBufferHash(inner, Enum.HashAlgorithm.Sha256)

	local outer = buffer.create(HMAC_BLOCK + 32)
	buffer.copy(outer, 0, opad, 0, HMAC_BLOCK)
	buffer.copy(outer, HMAC_BLOCK, innerHash, 0, 32)
	return EncodingService:ComputeBufferHash(outer, Enum.HashAlgorithm.Sha256)
end

local function signBuffer(buf)
	local key = initServerSecret()
	if not key then return nil end
	return b64Encode(hmacSha256(key, buf))
end

local function verifySignature(buf, expectedSigB64)
	local key = initServerSecret()
	if not key then return false end

	local computedSig = b64Encode(hmacSha256(key, buf))
	if computedSig == expectedSigB64 then return true end

	for _, legacyKey in ipairs(legacyKeys) do
		local legacySig = b64Encode(hmacSha256(legacyKey, buf))
		if legacySig == expectedSigB64 then return true end
	end

	return false
end

local activeStreams = {}
local roundRegistry = {}     
local roundParticipants = {} 
local roundFinalized = {}    
local roundPayloads = {}     
local roundBest = {}         
local roundVotedPlayer = {} 
local roundSaved = {}       
local roundTimers = {}      

local function getRoundId(seed, mode)
	local key = tostring(seed) .. ":" .. tostring(mode)
	local rid = roundRegistry[key]

	if not rid then
		rid = "Round_" .. HttpService:GenerateGUID(false)
		roundRegistry[key] = rid
		roundParticipants[rid] = {}
		roundFinalized[rid] = {}
		roundPayloads[rid] = {}      
		roundBest[rid] = nil          
		roundSaved[rid] = nil
		roundRecorder[rid] = nil
	end

	return rid
end

local function expandCameraTrack(payload, userId)
	local track = {}
	local lastPos = nil
	local lastLook = nil
	local key = tostring(userId)

	for _, frame in ipairs(payload.frames or {}) do
		local cameraData = frame.cameras and frame.cameras[key]

		if not cameraData and userId == payload.recorderUserId then
			if frame.cameraPos then
				cameraData = { pos = frame.cameraPos, look = frame.cameraLook }
			elseif frame.cameraDP then
				cameraData = { dp = frame.cameraDP, dl = frame.cameraDL }
			end
		end

		if cameraData then
			if cameraData.pos then
				lastPos = cameraData.pos
				lastLook = cameraData.look
			elseif cameraData.dp and lastPos then
				lastPos = { lastPos[1] + cameraData.dp[1], lastPos[2] + cameraData.dp[2], lastPos[3] + cameraData.dp[3] }
				lastLook = { lastLook[1] + cameraData.dl[1], lastLook[2] + cameraData.dl[2], lastLook[3] + cameraData.dl[3] }
			end

			if lastPos and lastLook then
				table.insert(track, {
					t = frame.t,
					pos = { lastPos[1], lastPos[2], lastPos[3] },
					look = { lastLook[1], lastLook[2], lastLook[3] },
				})
			end
		end
	end

	return track
end

local function cleanupRound(roundId)
	if roundTimers[roundId] then
		task.cancel(roundTimers[roundId])
		roundTimers[roundId] = nil
	end

	roundParticipants[roundId] = nil
	roundFinalized[roundId] = nil
	roundPayloads[roundId] = nil
	roundBest[roundId] = nil
	roundSaved[roundId] = nil
	roundVotedPlayer[roundId] = nil
	roundRecorder[roundId] = nil

	for key, rid in pairs(roundRegistry) do
		if rid == roundId then roundRegistry[key] = nil end
	end
end

local function validateStreamOwnership(player, streamId)
	if type(streamId) ~= "string" then return false end
	local prefix = "Stream_" .. player.UserId .. "_"
	return string.sub(streamId, 1, #prefix) == prefix
end

local function getReplayChunkKey(entry)
	if type(entry) ~= "table" then return nil end
	return entry.ChunkKey or entry.chunkKey or entry.chunk_key
end

local function migrateSavedReplays(profile)
	if not profile then return end
	local sourceTable = profile.savedReplays or profile.SavedReplays
	if type(sourceTable) ~= "table" then
		profile.savedReplays = {}
		profile.SavedReplays = nil
		return
	end

	local newSavedReplays = {}
	for k, entry in pairs(sourceTable) do
		if type(entry) == "table" then
			local chunkKey = getReplayChunkKey(entry)
			local replayId = entry.MatchId or entry.id or (type(k) == "string" and k) or ("Run_" .. HttpService:GenerateGUID(false))

			newSavedReplays[replayId] = {
				MatchId = replayId,
				id = replayId,
				PlayerUserId = entry.PlayerUserId or entry.recorderUserId or profile.UserId,
				Timestamp = tonumber(entry.Timestamp or entry.timestamp or entry.savedAt) or os.time(),
				timestamp = tonumber(entry.Timestamp or entry.timestamp or entry.savedAt) or os.time(),
				ChunkKey = chunkKey,
				chunkKey = chunkKey,
				MultiPOV = entry.MultiPOV or entry.multiplayer or false,
				isShared = entry.isShared or false,
				VotedPlayerUserId = entry.VotedPlayerUserId,
			}
		end
	end

	profile.savedReplays = newSavedReplays
	profile.SavedReplays = nil
end


local function resolveTargetName(target)
	if typeof(target) == "Instance" and target:IsA("Player") then return target.Name
	elseif type(target) == "string" then return target
	elseif type(target) == "number" then return tostring(target)
	end
	return nil
end

local function resolveOnlinePlayer(target)
	if typeof(target) == "Instance" and target:IsA("Player") then return target
	elseif type(target) == "string" then return Players:FindFirstChild(target)
	elseif type(target) == "number" then
		for _, p in ipairs(Players:GetPlayers()) do
			if p.UserId == target then return p end
		end
	end
	return nil
end

local function getProfileData(target)
	local profile = ProfileService.get(target)
	if profile and profile.Data then return profile.Data end
	return profile
end

local function trimSavedReplays(profileData, playerUserId)
	if not profileData or type(profileData.savedReplays) ~= "table" then return end
	playerUserId = tonumber(playerUserId)
	if not playerUserId then return end

	local personalPrefix = "RP_" .. playerUserId .. "_"
	local personalRuns = {}

	for key, entry in pairs(profileData.savedReplays) do
		if type(entry) == "table" then
			if entry.MultiPOV == true
				or entry.isShared == true
				or entry.multiplayer == true
				or entry.VotedPlayerUserId ~= nil
				or (type(key) == "string" and string.sub(key, 1, 6) == "Round_")
			then
				continue
			end

			local chunkKey = getReplayChunkKey(entry)
			if type(chunkKey) == "string" and string.sub(chunkKey, 1, #personalPrefix) == personalPrefix then
				table.insert(personalRuns, {
					key = key,
					timestamp = tonumber(entry.Timestamp or entry.timestamp) or 0,
					chunkKey = chunkKey,
				})
			end
		end
	end

	if #personalRuns <= MAX_REPLAYS then return end

	table.sort(personalRuns, function(a, b) return a.timestamp < b.timestamp end)

	local removeCount = #personalRuns - MAX_REPLAYS
	for i = 1, removeCount do
		local replay = personalRuns[i]
		task.spawn(deleteReplayChunk, replay.chunkKey)
		profileData.savedReplays[replay.key] = nil
	end
end

local function savePersonalReplay(player, payload)
	local guid = HttpService:GenerateGUID(false)
	local replayId = "Run_" .. guid
	local shortGuid = string.gsub(guid, "-", "")
	local chunkKey = "RP_" .. player.UserId .. "_" .. string.sub(shortGuid, 1, 10)

	local profile = getProfileData(player)
	if not profile then
		warn("[ReplayManager] No profile available for", player.Name)
		return false
	end

	local successChunk, errChunk = pcall(function()
		local encoded = HttpService:JSONEncode(payload)
		local inputBuffer = buffer.fromstring(encoded)
		local compressed = EncodingService:CompressBuffer(inputBuffer, Enum.CompressionAlgorithm.Zstd, ZSTD_LEVEL)
		local signature = signBuffer(compressed)

		if not signature then error("Signing failed") end
		local dataB64 = b64Encode(compressed)

		local stored = PROTOCOL .. ":Zstd:b64:hmac256:" .. signature .. ":" .. dataB64
		ReplayDataStore:SetAsync(chunkKey, stored)
	end)

	if not successChunk then
		warn("[ReplayManager] Failed to save replay chunk to DataStore for", player.Name, errChunk)
		return false
	end

	migrateSavedReplays(profile)
	if not profile.savedReplays then profile.savedReplays = {} end

	profile.savedReplays[replayId] = {
		MatchId = replayId,
		id = replayId,
		PlayerUserId = player.UserId,
		Timestamp = os.time(),
		timestamp = os.time(),
		ChunkKey = chunkKey,
		chunkKey = chunkKey,
	}

	trimSavedReplays(profile, player.UserId)

	local saved = ProfileService.saveProfile(player, profile)
	if not saved then
		warn("[ReplayManager] Replay chunk saved, but profile metadata failed to persist:", replayId)
		pcall(function() ReplayDataStore:RemoveAsync(chunkKey) end)
		return false
	end

	print("[ReplayManager] Saved replay successfully:", replayId, "for", player.Name)
	return true
end

local function buildSharedRoundPayload(roundId)
	local participants = roundParticipants[roundId]
	local payloads = roundPayloads[roundId]
	if not participants or not payloads then return nil end

	local votedUserId = roundVotedPlayer[roundId] or roundRecorder[roundId]
	local canonical = payloads[votedUserId]

	if not canonical then
		for userId, payload in pairs(payloads) do
			if payload and payload.frames and #payload.frames >= 2 then
				votedUserId = userId
				canonical = payload
				break
			end
		end
	end

	if not canonical then return nil end

	local shared = {}
	for key, value in pairs(canonical) do shared[key] = value end

	shared.multiplayer = true
	shared.votedPlayerUserId = votedUserId
	shared.recorderUserId = canonical.recorderUserId
	shared.cameraTracks = {}
	shared.cameraPlayers = {}

	for userId in pairs(participants) do
		local source = payloads[userId]
		if source then
			local track = expandCameraTrack(source, userId)
			if #track > 0 then
				local key = tostring(userId)
				shared.cameraTracks[key] = track

				local player = Players:GetPlayerByUserId(userId)
				local playerName = "Player " .. key
				local displayName = playerName

				if player then
					playerName = player.Name
					displayName = player.DisplayName
				else
					for _, frame in ipairs(source.frames or {}) do
						local info = frame.players and frame.players[key]
						if info then
							playerName = info.name or playerName
							displayName = info.displayName or playerName
							break
						end
					end
				end

				table.insert(shared.cameraPlayers, {
					key = key,
					userId = userId,
					name = playerName,
					displayName = displayName,
					isVotedPlayer = userId == votedUserId,
				})
			end
		end
	end

	table.sort(shared.cameraPlayers, function(a, b)
		if a.isVotedPlayer ~= b.isVotedPlayer then return a.isVotedPlayer end
		return a.name < b.name
	end)

	shared.replayPlayers = shared.cameraPlayers
	return shared
end

local function saveSharedRound(roundId)
	if roundSaved[roundId] then return end
	roundSaved[roundId] = true

	if roundTimers[roundId] then
		task.cancel(roundTimers[roundId])
		roundTimers[roundId] = nil
	end

	local payload = buildSharedRoundPayload(roundId)
	if not payload then
		cleanupRound(roundId)
		return
	end

	local guid = HttpService:GenerateGUID(false)
	local replayId = "Run_" .. guid
	local shortGuid = string.gsub(guid, "-", "")
	local chunkKey = "RP_shared_" .. string.sub(shortGuid, 1, 10)

	local successChunk, errChunk = pcall(function()
		local encoded = HttpService:JSONEncode(payload)
		local inputBuffer = buffer.fromstring(encoded)
		local compressed = EncodingService:CompressBuffer(inputBuffer, Enum.CompressionAlgorithm.Zstd, ZSTD_LEVEL)
		local signature = signBuffer(compressed)

		if not signature then error("Signing failed") end
		local dataB64 = b64Encode(compressed)

		local stored = PROTOCOL .. ":Zstd:b64:hmac256:" .. signature .. ":" .. dataB64
		ReplayDataStore:SetAsync(chunkKey, stored)
	end)

	if not successChunk then
		warn("[ReplayManager] Shared round chunk failed to save:", errChunk)
		cleanupRound(roundId)
		return
	end

	for userId in pairs(roundParticipants[roundId] or {}) do
		local target = Players:GetPlayerByUserId(userId)
		if target then
			local profile = getProfileData(target)
			if profile then
				migrateSavedReplays(profile)
				if not profile.savedReplays then profile.savedReplays = {} end
				profile.savedReplays[replayId] = {
					MatchId = replayId,
					PlayerUserId = payload.votedPlayerUserId,
					Timestamp = os.time(),
					ChunkKey = chunkKey,
					VotedPlayerUserId = payload.votedPlayerUserId,
					MultiPOV = true,
					isShared = true,
				}
				ProfileService.saveProfile(target, profile)
			end
		end
	end

	cleanupRound(roundId)
end

local function checkAllCompletion(roundId)
	local allDone = true
	for uid in pairs(roundParticipants[roundId] or {}) do
		if not roundFinalized[roundId][uid] then
			allDone = false
			break
		end
	end

	if allDone then
		saveSharedRound(roundId)
	elseif not roundTimers[roundId] then
		roundTimers[roundId] = task.delay(SHARED_SAVE_TIMEOUT, function()
			saveSharedRound(roundId)
		end)
	end
end

local function addToRound(roundId, player, payload, isRagequit)
	local userId = player.UserId
	roundFinalized[roundId][userId] = true
	roundPayloads[roundId][userId] = payload
	checkAllCompletion(roundId)
end

local function finalizeReplay(player, streamId, payload, sounds, markers, isRagequit)
	if not payload then return end

	activeStreams[streamId] = nil

	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player then
			ReplayEvent:FireClient(p, "StopCameraCapture")
		end
	end

	if type(sounds) == "table" then
		payload.sounds = sounds
	end

	if type(markers) == "table" then
		payload.markers = markers
	else
		payload.markers = payload.markers or {}
	end

	payload.ragequit = isRagequit == true

	local roundId = payload.roundId

	if not payload.frames or #payload.frames < 2 then
		if roundId and roundParticipants[roundId] then
			roundFinalized[roundId][player.UserId] = true
			checkAllCompletion(roundId)
		end
		return
	end

	if payload.multiplayer == true and roundId and roundParticipants[roundId] then
		addToRound(roundId, player, payload, isRagequit)
	else
		savePersonalReplay(player, payload)
	end
end

local function loadDecompressedPayload(chunkKey)
	if type(chunkKey) ~= "string" or chunkKey == "" then return nil end

	local success, result = pcall(function()
		local storedData = ReplayDataStore:GetAsync(chunkKey)
		if not storedData then return nil end

		if string.sub(storedData, 1, 3) == "RCP" then
			local proto, comp, enc, sigAlgo, sigB64, dataB64 =
				string.match(storedData, "^([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):(.*)$")

			if (proto == "RCP3" or proto == "RCP4") and comp == "Zstd" and enc == "b64" and sigAlgo == "hmac256" then
				local compressedBuffer = b64Decode(dataB64)
				if not compressedBuffer then return nil end

				if not verifySignature(compressedBuffer, sigB64) then
					warn("[ReplayManager] Invalid replay signature:", chunkKey)
					return nil
				end

				local decompressedBuffer = EncodingService:DecompressBuffer(
					compressedBuffer,
					Enum.CompressionAlgorithm.Zstd
				)

				return buffer.tostring(decompressedBuffer)
			end
		end

		return storedData
	end)

	if success then return result end
	warn("[ReplayManager] Failed to load replay data:", chunkKey, result)
	return nil
end

local function loadReplayPayload(chunkKey)
	local jsonString = loadDecompressedPayload(chunkKey)
	if jsonString then
		local ok, tableResult = pcall(function() return HttpService:JSONDecode(jsonString) end)
		if ok then return tableResult end
	end
	return nil
end
local function recoverReplayMetadata(profileData)
	if not profileData or type(profileData.savedReplays) ~= "table" then
		return false
	end

	local changed = false

	for key, entry in pairs(profileData.savedReplays) do
		if type(entry) ~= "table" then
			continue
		end

		-- Metadata already exists. DO NOT TOUCH THE REPLAY DATASTORE.
		local needsRecovery =
			entry.MapSeed == nil
			or entry.MapMode == nil
			or entry.RecorderUserId == nil
			or entry.PlayerCount == nil
			or entry.Multiplayer == nil
			or entry.Ragequit == nil
			or entry.Timestamp == nil
			or entry.MatchId == nil

		if not needsRecovery then
			continue
		end

		local chunkKey = getReplayChunkKey(entry)
		if not chunkKey then
			continue
		end

		-- This is the ONLY point where old replay data is read for recovery.
		local replayPayload = loadReplayPayload(chunkKey)

		if not replayPayload then
			continue
		end

		local function recover(field, ...)
			if entry[field] ~= nil then
				return
			end

			local value
			for i = 1, select("#", ...) do
				local candidate = select(i, ...)
				if candidate ~= nil then
					value = candidate
					break
				end
			end

			if value ~= nil then
				entry[field] = value
				changed = true
			end
		end

		recover("MapSeed", replayPayload.mapSeed)
		recover("MapMode", replayPayload.mapMode)
		recover("RecorderUserId", replayPayload.recorderUserId)
		recover("PlayerCount", replayPayload.playerCount)
		recover("Multiplayer", replayPayload.multiplayer)
		recover("Ragequit", replayPayload.ragequit)

		recover(
			"Timestamp",
			replayPayload.timestamp,
			replayPayload.Timestamp,
			replayPayload.savedAt,
			replayPayload.createdAt
		)

		recover(
			"Date",
			replayPayload.date,
			replayPayload.Date
		)

		recover(
			"RunName",
			replayPayload.runName,
			replayPayload.RunName
		)

		recover(
			"MatchId",
			replayPayload.id,
			replayPayload.MatchId,
			replayPayload.replayId
		)

		-- Keep compatibility fields synchronized.
		if entry.Timestamp ~= nil then
			entry.timestamp = entry.Timestamp
		end

		if entry.MatchId ~= nil then
			entry.id = entry.MatchId
		end

		if entry.ChunkKey ~= nil then
			entry.chunkKey = entry.ChunkKey
		end

		if entry.MultiPOV ~= nil then
			entry.multiplayer = entry.MultiPOV
		end
	end

	return changed
end

local function sendPlaybackDataChunked(player, jsonString)
	if not jsonString then return end
	local playbackId = HttpService:GenerateGUID(false)
	local totalLength = #jsonString
	local totalChunks = math.ceil(totalLength / CHUNK_NET_SIZE)

	for i = 1, totalChunks do
		local startPos = (i - 1) * CHUNK_NET_SIZE + 1
		local endPos = math.min(i * CHUNK_NET_SIZE, totalLength)
		local chunkData = string.sub(jsonString, startPos, endPos)

		ReplayEvent:FireClient(player, "PlaybackChunk", playbackId, i, totalChunks, chunkData)
	end
end

--------------------------------------------------
-- NETWORKING & EVENTS
--------------------------------------------------

ReplayEvent.OnServerEvent:Connect(function(player, command, arg1, arg2, arg3)
	if command == "StartStream" then
		local streamId = arg1
		local metadata = arg2 

		if not metadata or not streamId then return end
		if not validateStreamOwnership(player, streamId) then return end

		local roundId = nil
		if metadata.multiplayer == true then
			roundId = getRoundId(metadata.mapSeed, metadata.mapMode)
			roundParticipants[roundId][player.UserId] = true
			roundPayloads[roundId] = roundPayloads[roundId] or {}

			if not roundRecorder[roundId] then
				roundRecorder[roundId] = player.UserId
			end
		end

		activeStreams[streamId] = {
			mapSeed = metadata.mapSeed or 0,
			mapMode = metadata.mapMode or "Linear",
			sounds = metadata.sounds or {},
			recorderUserId = player.UserId,
			recorderRadius = metadata.recorderRadius,
			multiplayer = metadata.multiplayer == true,
			roundId = roundId,
			frames = {}
		}

	elseif command == "EnableCameraCapture" then
		local streamId = arg1
		if not validateStreamOwnership(player, streamId) then return end

		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= player then
				ReplayEvent:FireClient(p, "StartCameraCapture", streamId)
			end
		end

	elseif command == "CameraSample" then
		local streamId = arg1
		local sample = arg2
		local stream = activeStreams[streamId]

		if stream and stream.recorderUserId then
			local recorderPlayer = Players:GetPlayerByUserId(stream.recorderUserId)
			if recorderPlayer then
				ReplayEvent:FireClient(recorderPlayer, "RemoteCameraSample", player.UserId, sample)
			end
		end

	elseif command == "StreamChunk" then
		local streamId = arg1
		local frameChunk = arg2

		if not validateStreamOwnership(player, streamId) then return end

		if activeStreams[streamId] and type(frameChunk) == "table" then
			for _, frame in ipairs(frameChunk) do
				table.insert(activeStreams[streamId].frames, frame)
			end
		end

	elseif command == "FinalizeReplay" then
		local streamId = arg1
		local payload = activeStreams[streamId]
		if not payload then return end
		finalizeReplay(player, streamId, payload, arg2, arg3, false)

	elseif command == "RequestProfileList" then
		local profile = ProfileService.get(player)
		if not profile then return end

		local profileData = profile.Data or profile

		-- Normalize old metadata format first.
		migrateSavedReplays(profileData)

		-- IMPORTANT:
		-- This only touches ReplayDataStore when metadata is actually missing.
		-- Once recovered, the metadata is persisted into ProfileService.
		local recovered = recoverReplayMetadata(profileData)

		if recovered then
			local saved = ProfileService.saveProfile(player, profileData)

			if not saved then
				warn(
					"[ReplayManager] Recovered replay metadata in memory, " ..
						"but failed to persist profile for",
					player.Name
				)
			else
				print(
					"[ReplayManager] Recovered and persisted replay metadata for",
					player.Name
				)
			end
		end

		local payloadList = {}

		if type(profileData.savedReplays) == "table" then
			for key, replayEntry in pairs(profileData.savedReplays) do
				if type(replayEntry) == "table" then
					local entryCopy = {}

					for k, v in pairs(replayEntry) do
						entryCopy[k] = v
					end

					entryCopy.Key = tostring(key)

					entryCopy.MatchId =
						entryCopy.MatchId
						or entryCopy.id
						or "Replay"

					entryCopy.Timestamp =
						tonumber(entryCopy.Timestamp or entryCopy.timestamp)
						or 0

					entryCopy.MapSeed = entryCopy.MapSeed
					entryCopy.MapMode = entryCopy.MapMode
					entryCopy.RecorderUserId = entryCopy.RecorderUserId
					entryCopy.PlayerCount = entryCopy.PlayerCount
					entryCopy.Multiplayer = entryCopy.Multiplayer
					entryCopy.Ragequit = entryCopy.Ragequit

					table.insert(payloadList, entryCopy)
				end
			end
		end

		ReplayEvent:FireClient(player, "SyncProfileList", payloadList)

	elseif command == "RequestPlayback" then
		local chunkKey = arg1
		local profile = ProfileService.get(player)
		if not profile or not profile.savedReplays then return end

		local ownsReplay = false
		for _, replay in pairs(profile.savedReplays) do
			if getReplayChunkKey(replay) == chunkKey then
				ownsReplay = true
				break
			end
		end
		if not ownsReplay then return end

		local jsonString = loadDecompressedPayload(chunkKey)
		if jsonString then
			sendPlaybackDataChunked(player, jsonString)
		end

	elseif command == "RegeneratePlaybackMap" then
		local seed = arg1
		local mode = arg2 or "Linear"
		local isLiveMatch = arg3 

		if type(seed) ~= "number" then return end
		-- go create your own map generator by yourself
	end	
end)

task.spawn(function() initServerSecret() end)

Players.PlayerRemoving:Connect(function(player)
	local prefix = "Stream_" .. player.UserId .. "_"
	for streamId, payload in pairs(activeStreams) do
		if string.sub(streamId, 1, #prefix) == prefix then
			finalizeReplay(player, streamId, payload, nil, nil, true)
		end
	end
end)

--------------------------------------------------
-- COMMAND & UTILITY FUNCTIONS
--------------------------------------------------

_G.PlayReplayForPlayer = function(target, index, viewer)
	if not target or type(index) ~= "number" then return "Invalid arguments." end
	local displayName = resolveTargetName(target)
	if not displayName then return "Invalid target player." end

	local profile = getProfileData(target)
	if not profile or not profile.savedReplays then return displayName .. " has no saved replays." end

	local replays = {}
	for rid, entry in pairs(profile.savedReplays) do
		table.insert(replays, { rid = rid, entry = entry })
	end
	if #replays == 0 then return displayName .. " has no saved replays." end

	table.sort(replays, function(a, b) return (a.entry.Timestamp or 0) > (b.entry.Timestamp or 0) end)

	local replay = replays[index]
	if not replay then return string.format("Invalid index %d. %s has %d saved replays.", index, displayName, #replays) end

	local entry = replay.entry
	local chunkKey = getReplayChunkKey(entry)
	if not chunkKey then return "Replay has no valid chunk key." end

	local targetPlayer = resolveOnlinePlayer(target)
	local viewerPlayer = nil

	if typeof(viewer) == "Instance" and viewer:IsA("Player") then
		viewerPlayer = viewer
	elseif viewer ~= nil then
		viewerPlayer = resolveOnlinePlayer(viewer)
	end

	if not viewerPlayer then viewerPlayer = targetPlayer end
	if not viewerPlayer then return string.format("Replay %d (%s) found for %s, but there is no online viewer.", index, entry.MatchId or replay.rid, displayName) end

	local jsonString = loadDecompressedPayload(chunkKey)
	if jsonString then
		sendPlaybackDataChunked(viewerPlayer, jsonString)
		if targetPlayer then
			return string.format("Playing replay %d (%s) for %s.", index, entry.MatchId or replay.rid, displayName)
		else
			return string.format("Playing offline replay %d (%s) belonging to %s for %s.", index, entry.MatchId or replay.rid, displayName, viewerPlayer.Name)
		end
	else
		return string.format("Could not load replay data for %s.", displayName)
	end
end

_G.FetchReplaysForPlayer = function(target)
	if not target then return "Invalid arguments." end
	local displayName = resolveTargetName(target)
	if not displayName then return "Invalid target player." end

	local profile = getProfileData(target)
	if not profile or not profile.savedReplays then return displayName .. " has no saved replays." end

	local replays = {}
	for rid, entry in pairs(profile.savedReplays) do
		table.insert(replays, { rid = rid, entry = entry })
	end
	if #replays == 0 then return displayName .. " has no saved replays." end
	table.sort(replays, function(a, b) return (a.entry.Timestamp or 0) > (b.entry.Timestamp or 0) end)

	local lines = { string.format("%s has %d saved replays:", displayName, #replays) }
	for i, replay in ipairs(replays) do
		local entry = replay.entry
		local dateStr = os.date("%X - %b %d, %Y", entry.Timestamp or 0)
		table.insert(lines, string.format("  [%d] %s | %s", i, entry.MatchId or replay.rid, dateStr))
	end
	return table.concat(lines, "\n")
end

_G.DeleteReplayForPlayer = function(target, index)
	if not target or type(index) ~= "number" then return "Invalid arguments." end
	local displayName = resolveTargetName(target)
	if not displayName then return "Invalid target player." end

	local profile = getProfileData(target)
	if not profile or not profile.savedReplays then return displayName .. " has no saved replays." end

	local replays = {}
	for rid, entry in pairs(profile.savedReplays) do
		table.insert(replays, { rid = rid, entry = entry })
	end
	if #replays == 0 then return displayName .. " has no saved replays." end
	table.sort(replays, function(a, b) return (a.entry.Timestamp or 0) > (b.entry.Timestamp or 0) end)

	local replay = replays[index]
	if not replay then return string.format("Invalid index %d. %s has %d saved replays.", index, displayName, #replays) end
	local entry = replay.entry

	local delKey = getReplayChunkKey(entry)
	if delKey then deleteReplayChunk(delKey) end
	profile.savedReplays[replay.rid] = nil
	ProfileService.saveProfile(target, profile)
	return string.format("Deleted replay %d (%s) for %s.", index, entry.MatchId or replay.rid, displayName)
end

_G.ClearReplaysForPlayer = function(target)
	if not target then return "Invalid arguments." end
	local displayName = resolveTargetName(target)
	if not displayName then return "Invalid target player." end

	local profile = getProfileData(target)
	if not profile or not profile.savedReplays then return displayName .. " has no saved replays." end

	local count = 0
	for _, entry in pairs(profile.savedReplays) do
		count += 1
		local clearKey = getReplayChunkKey(entry)
		if clearKey then deleteReplayChunk(clearKey) end
	end
	if count == 0 then return displayName .. " has no saved replays." end

	profile.savedReplays = {}
	ProfileService.saveProfile(target, profile)
	return string.format("Cleared %d replays for %s.", count, displayName)
end

_G.SetReplayVotedPlayer = function(userId)
	userId = tonumber(userId)
	if not userId then return false end

	for roundId, participants in pairs(roundParticipants) do
		if participants[userId] then
			roundVotedPlayer[roundId] = userId
			return true
		end
	end

	return false
end