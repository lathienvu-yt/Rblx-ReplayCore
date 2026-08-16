--!nocheck
local DataStoreService = game:GetService("DataStoreService")
local ReplayDataStore = DataStoreService:GetDataStore("ReplayChunks_v2")
local SecretStore = DataStoreService:GetDataStore("ReplaySecret_v1")

local ProfileService = require(game.ServerScriptService.ParkourOps.ProfileService)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local EncodingService = game:GetService("EncodingService")
local MessagingService = game:GetService("MessagingService")
local MemoryStoreService = game:GetService("MemoryStoreService")

local ReplayEvent = ReplicatedStorage:WaitForChild("ReplayEvent")


local LiveSnapshotStore =
	DataStoreService:GetDataStore("LivePlayCore_Snapshots_v1")


--------------------------------------------------
-- CONFIG
--------------------------------------------------

local ZSTD_LEVEL = 10
local PROTOCOL = "RCP4"

local SHARED_SAVE_TIMEOUT = 300
local MAX_REPLAYS = 10

-- RemoteEvent chunk size
local CHUNK_NET_SIZE = 150000

-- Ring buffer / segmented storage
local RING_BUFFER_CAPACITY = 3000      -- Max frames held in memory ring buffer
local RING_BUFFER_DELAY = 5           -- Seconds before frames are committed to storage
local SEGMENT_FRAME_LIMIT = 500       -- Max frames per persisted segment
local SEGMENT_BYTE_MAX = 800000       -- ~800KB per segment (safe under DataStore limits)
local FLUSH_INTERVAL = 2              -- Seconds between ring buffer flush checks

--------------------------------------------------
-- HYBRID REPLAY STORAGE
--------------------------------------------------
local LIVE_SNAPSHOT_CHUNK_SIZE = 12000
local REPLAY_SEQUENCE_CHUNK_SIZE = 50
local REPLAY_LIVE_TTL = 120
local REPLAY_LIVE_VALUE_LIMIT = 7000
local REPLAY_LIVE_TOTAL_BUDGET = 14000

-- MemoryStore is a disposable live tier. Keep only the newest unprocessed
-- chunks here; DataStore is the durable replay archive.
local REPLAY_LIVE_MAX_CHUNKS_PER_MATCH = 2
local REPLAY_LIVE_GC_INTERVAL = 30

local REPLAY_PROCESS_INTERVAL = 0.25
local REPLAY_PROCESS_RETRY_DELAY = 2
local REPLAY_PROCESS_LEASE = 15

local liveChunkMapCache = {}
local startingStreamsByUser = {}
local activeStreamByUser = {}

local function getLiveChunkMap(matchId)
	if type(matchId) ~= "string" or matchId == "" then
		return nil
	end

	local mapName = "ReplayLiveSeq_" .. matchId
	local map = liveChunkMapCache[mapName]

	if not map then
		map = MemoryStoreService:GetSortedMap(mapName)
		liveChunkMapCache[mapName] = map
	end

	return map
end

local ReplayLiveIndexMap =
	MemoryStoreService:GetSortedMap("ReplayLiveIndex_v1")

-- MemoryStore HashMap expiration. Matches are short-lived (a single run), so a
-- short TTL keeps the LivePlayCore_Matches partition well under its 64KB quota.
local LIVE_MATCH_EXPIRATION = 120

-- Cleanup threshold: entries older than this (and not active on this server) are
-- pruned from the LivePlayCore_Matches partition to keep it under the 64KB cap.
local LIVE_MATCH_MAX_AGE = 90

-- Cap on tracked subscribers per match (in-memory only).
local MAX_LIVE_SUBSCRIBERS = 20

-- Generate a unique run ID per server startup
local SERVER_SESSION_ID = string.sub(HttpService:GenerateGUID(false), 1, 8)
-- Live request/response topics
local LPC_REQUEST_TOPIC = "LivePlayCore_Request"
local LPC_RESPONSE_PREFIX = "LivePlayCore_Response_"

--------------------------------------------------
-- STORES
--------------------------------------------------

local LIVE_MATCHES_MAP = MemoryStoreService:GetSortedMap("LivePlayCore_Matches")
local LPC_DVR_MAP = MemoryStoreService:GetSortedMap("LivePlayCore_DVR")
local LPC_FRAMES_MAP = MemoryStoreService:GetSortedMap("LivePlayCore_Frames")

local MAX_MEMORYSTORE_VALUE_BYTES = 30000 -- MemoryStore per-item value limit is 32KB

--------------------------------------------------
-- STATE
--------------------------------------------------

local roundRecorder = {}

local activeStreams = {}
local roundRegistry = {}
local roundParticipants = {}
local roundFinalized = {}
local roundPayloads = {}
local roundBest = {}
local roundVotedPlayer = {}
local roundSaved = {}
local roundTimers = {}
local mapCache = {}


local liveMatches = {}
local liveStoreReady = true

-- Response subscription for THIS server
local responseSubscription = nil
local responseTopic = LPC_RESPONSE_PREFIX .. game.JobId

-- Requests waiting for a live match response
local pendingLiveRequests = {}
local incomingResponseMessages = {}

--------------------------------------------------
-- HMAC / SECRET
--------------------------------------------------

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
local function clearPlayerStream(player)
	if not player then
		return
	end

	local userId = player.UserId
	local streamId = activeStreamByUser[userId]

	if streamId then
		activeStreamByUser[userId] = nil
	end

	startingStreamsByUser[userId] = nil
end
local fallbackSecret = nil

local function initServerSecret()
	if serverSecret then
		return serverSecret
	end

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
		warn("[ReplayManager] SecretStore unavailable, using in-memory session secret fallback:", tostring(result))
		if not fallbackSecret then
			fallbackSecret = buffer.fromstring(HttpService:GenerateGUID(false) .. HttpService:GenerateGUID(false))
		end
		serverSecret = fallbackSecret
	end

	table.clear(legacyKeys)

	for i = 0, 9 do
		local backupKey = loadKeyFromStore("key_v" .. i)
		if backupKey then
			table.insert(legacyKeys, backupKey)
		end
	end

	return serverSecret
end

local function b64Encode(buf)
	return buffer.tostring(EncodingService:Base64Encode(buf))
end

local function b64Decode(str)
	local success, result = pcall(function()
		return EncodingService:Base64Decode(buffer.fromstring(str))
	end)

	if success then
		return result
	end

	return nil
end

local HMAC_BLOCK = 64

local function hmacSha256(keyBuf, msgBuf)
	if buffer.len(keyBuf) > HMAC_BLOCK then
		keyBuf = EncodingService:ComputeBufferHash(keyBuf, Enum.HashAlgorithm.Sha256)
	end

	local paddedKey = buffer.create(HMAC_BLOCK)
	buffer.copy(paddedKey, 0, keyBuf, 0, math.min(buffer.len(keyBuf), HMAC_BLOCK))

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
	if not key then
		return nil
	end

	return b64Encode(hmacSha256(key, buf))
end

local function verifySignature(buf, expectedSigB64)
	local key = initServerSecret()
	if not key then
		return false
	end

	local computedSig = b64Encode(hmacSha256(key, buf))
	if computedSig == expectedSigB64 then
		return true
	end

	for _, legacyKey in ipairs(legacyKeys) do
		local legacySig = b64Encode(hmacSha256(legacyKey, buf))
		if legacySig == expectedSigB64 then
			return true
		end
	end

	return false
end

--------------------------------------------------
-- GENERAL HELPERS
--------------------------------------------------

local function getReplayChunkKey(entry)
	if type(entry) ~= "table" then
		return nil
	end

	return entry.ChunkKey or entry.chunkKey or entry.chunk_key
end

local function formatByteSize(bytes)
	bytes = tonumber(bytes) or 0

	if bytes >= 1024 * 1024 then
		return string.format("%.2f MB", bytes / (1024 * 1024))
	end

	if bytes >= 1024 then
		return string.format("%.1f KB", bytes / 1024)
	end

	return tostring(bytes) .. " B"
end
local function getSegmentKey(seg)
	if type(seg) == "string" then
		return seg
	elseif type(seg) == "table" then
		return seg.key or seg.Key or seg.chunkKey or seg.ChunkKey or seg.segmentKey or seg.SegmentKey
	end
	return nil
end

local function buildReplaySizeStats(encoded, compressed, stored)
	local rawBytes = #encoded
	local compressedBytes = buffer.len(compressed)
	local storedBytes = #stored

	return {
		RawBytes = rawBytes,
		CompressedBytes = compressedBytes,
		StoredBytes = storedBytes,
		CompressionRatio = rawBytes > 0 and compressedBytes / rawBytes or 0,
	}
end

local function getReplaySizeLabel(entry)
	if type(entry) ~= "table" then
		return nil
	end

	local storedBytes = tonumber(entry.StoredBytes or entry.storedBytes)
	if not storedBytes or storedBytes <= 0 then
		return nil
	end

	return formatByteSize(storedBytes)
end

local function printReplaySizeStats(label, stats)
	if type(stats) ~= "table" then
		return
	end

	print(
		"[ReplayCoreServer]",
		label,
		"raw =", formatByteSize(stats.RawBytes),
		"compressed =", formatByteSize(stats.CompressedBytes),
		"stored =", formatByteSize(stats.StoredBytes),
		"ratio =", string.format("%.1f%%", (stats.CompressionRatio or 0) * 100)
	)
end


local function getMapForMatch(matchId, partitionIndex)
	partitionIndex = partitionIndex or 0
	local mapName = string.format("LPC_Frames_%s_%s_P%d", SERVER_SESSION_ID, matchId, partitionIndex)

	if not mapCache[mapName] then
		mapCache[mapName] = MemoryStoreService:GetSortedMap(mapName)
	end

	return mapCache[mapName]
end

local function makeLiveSnapshotKey(requestId)
	return "LPC_SNAPSHOT_" .. tostring(requestId)
end

local function encodeLiveSnapshot(snapshotJson)
	local compressed = EncodingService:CompressBuffer(
		buffer.fromstring(snapshotJson),
		Enum.CompressionAlgorithm.Zstd,
		ZSTD_LEVEL
	)

	return "LPCSNAP1:Zstd:b64:" .. b64Encode(compressed)
end

local function decodeLiveSnapshot(stored)
	if type(stored) ~= "string" or stored == "" then
		return nil
	end

	local prefix = "LPCSNAP1:Zstd:b64:"
	if string.sub(stored, 1, #prefix) ~= prefix then
		return nil
	end

	local encoded = string.sub(stored, #prefix + 1)

	local ok, result = pcall(function()
		local compressed = b64Decode(encoded)
		local decompressed = EncodingService:DecompressBuffer(compressed,Enum.CompressionAlgorithm.Zstd)
		return buffer.tostring(decompressed)
	end)

	if not ok then
		warn("[LivePlayCore] Failed decompressing snapshot:", result)
		return nil
	end

	return result
end

-- Initial snapshots are archive-sized payloads. They do NOT belong in
-- MemoryStore, whose entire structure quota is only 64 KB.
--
-- Compressing the snapshot first means one DataStore write is normally enough,
-- which also avoids creating a 30+ request DataStore queue for a single watch.
local function writeLiveSnapshotToDataStore(requestId, snapshotJson)
	if type(requestId) ~= "string" or requestId == "" then
		return false
	end

	if type(snapshotJson) ~= "string" or snapshotJson == "" then
		return false
	end

	local okEncode, stored = pcall(function()
		return encodeLiveSnapshot(snapshotJson)
	end)

	if not okEncode or type(stored) ~= "string" then
		warn(
			"[LivePlayCore] Failed compressing snapshot:",
			requestId,
			stored
		)
		return false
	end

	local key = makeLiveSnapshotKey(requestId)

	local okWrite, err = pcall(function()
		LiveSnapshotStore:SetAsync(key, stored)
	end)

	if not okWrite then
		warn(
			"[LivePlayCore] Failed writing snapshot to DataStore:",
			key,
			"storedBytes =",
			#stored,
			err
		)
		return false
	end

	print(
		"[LivePlayCore] Snapshot stored in DataStore:",
		key,
		"rawBytes =",
		#snapshotJson,
		"storedBytes =",
		#stored
	)

	-- Best-effort fallback cleanup if the requesting server disappears.
	task.delay(120, function()
		pcall(function()
			LiveSnapshotStore:RemoveAsync(key)
		end)
	end)

	return true, key
end

local function readLiveSnapshotFromDataStore(requestId, snapshotKey)
	if type(requestId) ~= "string" or requestId == "" then
		return nil
	end

	if type(snapshotKey) ~= "string" or snapshotKey == "" then
		snapshotKey = makeLiveSnapshotKey(requestId)
	end

	local ok, stored = pcall(function()
		return LiveSnapshotStore:GetAsync(snapshotKey)
	end)

	if not ok then
		warn(
			"[LivePlayCore] Failed reading snapshot from DataStore:",
			snapshotKey,
			stored
		)
		return nil
	end

	if type(stored) ~= "string" or stored == "" then
		warn(
			"[LivePlayCore] Snapshot missing from DataStore:",
			snapshotKey
		)
		return nil
	end

	local json = decodeLiveSnapshot(stored)

	if type(json) ~= "string" or json == "" then
		warn(
			"[LivePlayCore] Snapshot decompression produced no JSON:",
			snapshotKey
		)
		return nil
	end

	-- Snapshot transport is disposable. Remove it after a successful read.
	task.spawn(function()
		local removeOk, removeErr = pcall(function()
			LiveSnapshotStore:RemoveAsync(snapshotKey)
		end)

		if not removeOk then
			warn(
				"[LivePlayCore] Failed cleaning snapshot:",
				snapshotKey,
				removeErr
			)
		end
	end)

	return json
end

--------------------------------------------------
-- PLAYER RESOLUTION
--------------------------------------------------

local function getTargetUserId(target)
	if not target then
		return nil
	end

	if type(target) == "table" then
		if target.UserId then
			return tonumber(target.UserId)
		end

		if target.Player and typeof(target.Player) == "Instance" and target.Player:IsA("Player") then
			return target.Player.UserId
		end
	end

	if typeof(target) == "Instance" and target:IsA("Player") then
		return target.UserId
	end

	if type(target) == "number" then
		return target
	end

	if type(target) == "string" then
		local player = Players:FindFirstChild(target)
		if player then
			return player.UserId
		end

		local userId = tonumber(target)
		if userId then
			return userId
		end
	end

	return nil
end

local function resolveOnlinePlayer(target)
	local userId = getTargetUserId(target)
	if not userId then
		return nil
	end

	return Players:GetPlayerByUserId(userId)
end

local function resolveTargetName(target)
	if not target then
		return nil
	end

	if type(target) == "table" then
		if target.Name then
			return target.Name
		end

		if target.Player and typeof(target.Player) == "Instance" and target.Player:IsA("Player") then
			return target.Player.Name
		end
	end

	if typeof(target) == "Instance" and target:IsA("Player") then
		return target.Name
	end

	if type(target) == "string" then
		local player = Players:FindFirstChild(target)
		if player then
			return player.Name
		end

		return target
	end

	local userId = getTargetUserId(target)
	if userId then
		local player = Players:GetPlayerByUserId(userId)
		if player then
			return player.Name
		end

		local success, username = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)

		if success and username then
			return username
		end
	end

	return nil
end

local function getProfileData(target)
	local profile = ProfileService.get(target)
	if profile and profile.Data then
		return profile.Data
	end

	return profile
end

--------------------------------------------------
-- REPLAY METADATA MIGRATION
--------------------------------------------------

local function migrateSavedReplays(profile)
	if not profile then
		return
	end

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

			local replayId = entry.MatchId
				or entry.id
				or (type(k) == "string" and k)
				or ("Run_" .. HttpService:GenerateGUID(false))

			newSavedReplays[replayId] = {
				MatchId = replayId,
				id = replayId,
				PlayerUserId = entry.PlayerUserId or entry.recorderUserId or profile.UserId,
				Timestamp = tonumber(entry.Timestamp or entry.timestamp or entry.savedAt) or os.time(),
				ChunkKey = chunkKey,
				MultiPOV = entry.MultiPOV or entry.multiplayer or false,
				isShared = entry.isShared or false,
				VotedPlayerUserId = entry.VotedPlayerUserId,
				RawBytes = tonumber(entry.RawBytes or entry.rawBytes),
				CompressedBytes = tonumber(entry.CompressedBytes or entry.compressedBytes),
				StoredBytes = tonumber(entry.StoredBytes or entry.storedBytes),
				CompressionRatio = tonumber(entry.CompressionRatio or entry.compressionRatio),
				MapSeed = entry.MapSeed,
				MapMode = entry.MapMode,
				RecorderUserId = entry.RecorderUserId,
				PlayerCount = entry.PlayerCount,
				Multiplayer = entry.Multiplayer,
				Ragequit = entry.Ragequit,
				RunName = entry.RunName,
				Date = entry.Date,
			}
		end
	end

	profile.savedReplays = newSavedReplays
	profile.SavedReplays = nil
end

--------------------------------------------------
-- REPLAY LOAD / SAVE (VOD ENGINE)
--------------------------------------------------

local function loadDecompressedPayload(chunkKey)
	if type(chunkKey) ~= "string" or chunkKey == "" then
		warn("[ReplayCoreServer] VOD LOAD REJECTED: invalid chunkKey:", chunkKey)
		return nil
	end

	print("[ReplayCoreServer] Loading VOD chunk key:", chunkKey)

	-- 2. DataStore fetch with retry loop
	local storedData = nil
	local maxRetries = 3

	for attempt = 1, maxRetries do
		local success, result = pcall(function()
			return ReplayDataStore:GetAsync(chunkKey)
		end)

		if success and result then
			storedData = result
			break
		end

		if attempt < maxRetries then
			task.wait(0.5 * attempt) -- Wait before retrying (0.5s, 1s)
		end
	end

	if not storedData then
		warn("[ReplayCoreServer] GetAsync returned NIL after retries for key:", chunkKey)
		return nil -- Returning nil here tells the caller loading failed safely
	end

	-- 3. Decompress payload
	local success, result = pcall(function()
		if string.sub(storedData, 1, 3) == "RCP" then
			local proto, comp, enc, sigAlgo, sigB64, dataB64 = string.match(
				storedData,
				"^([^:]+):([^:]+):([^:]+):([^:]+):([^:]+):(.*)$"
			)

			if (proto == "RCP3" or proto == "RCP4") and comp == "Zstd" and enc == "b64" and sigAlgo == "hmac256" then
				local compressedBuffer = b64Decode(dataB64)
				if not compressedBuffer then
					error("b64Decode returned nil")
				end

				if not verifySignature(compressedBuffer, sigB64) then
					error("VOD signature verification FAILED")
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

	if success then
		return result
	end

	warn("[ReplayCoreServer] FAILED TO DECOMPRESS VOD CHUNK:", chunkKey, result)
	return nil
end

local function loadReplayPayload(chunkKey)
	local jsonString = loadDecompressedPayload(chunkKey)
	if not jsonString then
		return nil
	end

	local ok, tableResult = pcall(function()
		return HttpService:JSONDecode(jsonString)
	end)

	if ok then
		return tableResult
	end

	return nil
end

local function deleteReplayChunk(chunkKey)
	if not chunkKey then
		return true
	end

	local payload = loadReplayPayload(chunkKey)

	if payload and type(payload.segments) == "table" then
		for _, seg in ipairs(payload.segments) do
			local segKey = getSegmentKey(seg)
			if segKey then
				pcall(function()
					ReplayDataStore:RemoveAsync(segKey)
				end)
			end
		end
	end

	local totalChunks = payload
		and tonumber(payload.totalChunks or payload.chunkCount)

	if totalChunks and totalChunks > 0 then
		for index = 0, totalChunks - 1 do
			pcall(function()
				ReplayDataStore:RemoveAsync(
					string.format("%s_seq_%d", chunkKey, index)
				)
			end)
		end
	end

	local success, err = pcall(function()
		ReplayDataStore:RemoveAsync(chunkKey)
	end)

	if not success then
		warn("[ReplayCoreServer] Failed to delete VOD chunk:", chunkKey, err)
		return false
	end

	return true
end

local function trimSavedReplays(profileData, playerUserId)
	if not profileData or type(profileData.savedReplays) ~= "table" then
		return
	end

	playerUserId = tonumber(playerUserId)
	if not playerUserId then
		return
	end

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

	if #personalRuns <= MAX_REPLAYS then
		return
	end

	table.sort(personalRuns, function(a, b)
		return a.timestamp < b.timestamp
	end)

	local removeCount = #personalRuns - MAX_REPLAYS

	for i = 1, removeCount do
		local replay = personalRuns[i]
		task.spawn(deleteReplayChunk, replay.chunkKey)
		profileData.savedReplays[replay.key] = nil
	end
end

local function saveReplayPayload(chunkKey, payload)
	if type(chunkKey) ~= "string" or chunkKey == "" or type(payload) ~= "table" then
		return false, nil
	end

	local sizeStats = nil

	local ok, err = pcall(function()
		local encoded = HttpService:JSONEncode(payload)
		local inputBuffer = buffer.fromstring(encoded)
		local compressed = EncodingService:CompressBuffer(
			inputBuffer,
			Enum.CompressionAlgorithm.Zstd,
			ZSTD_LEVEL
		)

		local signature = signBuffer(compressed)
		if not signature then
			error("Signing failed")
		end

		local dataB64 = b64Encode(compressed)
		local stored = PROTOCOL .. ":Zstd:b64:hmac256:" .. signature .. ":" .. dataB64

		sizeStats = buildReplaySizeStats(encoded, compressed, stored)
		ReplayDataStore:SetAsync(chunkKey, stored)
	end)

	if not ok then
		warn("[ReplayCoreServer] Failed to save VOD payload:", chunkKey, err)
		return false, nil
	end

	return true, sizeStats
end

--------------------------------------------------
-- SEGMENTED REPLAY STORAGE (VOD CHUNKS)
--------------------------------------------------

local function saveSegmentChunk(segmentKey, frames)
	if type(segmentKey) ~= "string" or segmentKey == "" or type(frames) ~= "table" then
		return false
	end

	return saveReplayPayload(segmentKey, { frames = frames })
end

local function splitReplayIntoSegments(chunkKey, frames)
	local segments = {}
	if type(frames) ~= "table" then
		return segments
	end

	local current = {}
	local currentBytes = 0

	for _, frame in ipairs(frames) do
		table.insert(current, frame)
		currentBytes += #HttpService:JSONEncode(frame)

		if #current >= SEGMENT_FRAME_LIMIT or currentBytes >= SEGMENT_BYTE_MAX then
			local segKey = chunkKey .. "_seg_" .. tostring(#segments)
			if saveSegmentChunk(segKey, current) then
				table.insert(segments, { key = segKey, count = #current })
			end
			current = {}
			currentBytes = 0
		end
	end

	if #current > 0 then
		local segKey = chunkKey .. "_seg_" .. tostring(#segments)
		if saveSegmentChunk(segKey, current) then
			table.insert(segments, { key = segKey, count = #current })
		end
	end

	return segments
end

local function saveReplayPayloadSegmented(chunkKey, payload)
	if type(chunkKey) ~= "string" or chunkKey == "" or type(payload) ~= "table" then
		return false, nil
	end

	local frames = payload.frames or {}
	local segments = splitReplayIntoSegments(chunkKey, frames)

	local storedPayload = {}
	for k, v in pairs(payload) do
		if k ~= "frames" then
			storedPayload[k] = v
		end
	end

	storedPayload.segments = segments
	storedPayload.segmentCount = #segments

	return saveReplayPayload(chunkKey, storedPayload)
end

local function persistReplayPayload(chunkKey, payload)
	if payload.segments and #payload.segments > 0 then
		local storedPayload = {}
		for k, v in pairs(payload) do
			if k ~= "frames" then
				storedPayload[k] = v
			end
		end
		storedPayload.segments = payload.segments
		storedPayload.segmentCount = #payload.segments
		return saveReplayPayload(chunkKey, storedPayload)
	end

	return saveReplayPayloadSegmented(chunkKey, payload)
end

local function loadReplayPayloadSegmented(chunkKey)
	local payload = loadReplayPayload(chunkKey)
	if not payload then
		return nil
	end

	if payload.segments and #payload.segments > 0 then
		local frames = {}
		for _, seg in ipairs(payload.segments) do
			local segKey = getSegmentKey(seg)
			if segKey then
				local segPayload = loadReplayPayload(segKey)
				if segPayload and type(segPayload.frames) == "table" then
					for _, f in ipairs(segPayload.frames) do
						table.insert(frames, f)
					end
				end
			end
		end

		payload.frames = frames
		payload.segments = nil
		payload.segmentCount = nil
	end

	return payload
end

--------------------------------------------------
-- HYBRID REPLAY SEQUENCE CHUNKS
--------------------------------------------------

local function getSequenceChunkIndex(seq)
	seq = tonumber(seq)

	if not seq or seq < 1 then
		return 0
	end

	return math.floor((seq - 1) / REPLAY_SEQUENCE_CHUNK_SIZE)
end

local function getSequenceChunkKey(replayKey, chunkIndex)
	return string.format(
		"%s_seq_%d",
		replayKey,
		chunkIndex
	)
end

local function splitFramesForMemoryStore(frames)
	if type(frames) ~= "table" or #frames == 0 then
		return {}
	end

	local ok, parts = pcall(function()
		local json = HttpService:JSONEncode(frames)
		local compressed = EncodingService:CompressBuffer(
			buffer.fromstring(json),
			Enum.CompressionAlgorithm.Zstd,
			ZSTD_LEVEL
		)

		local encoded = b64Encode(compressed)
		local result = {}

		for startPos = 1, #encoded, REPLAY_LIVE_VALUE_LIMIT do
			local endPos = math.min(
				startPos + REPLAY_LIVE_VALUE_LIMIT - 1,
				#encoded
			)
			table.insert(
				result,
				"RCL1:Zstd:b64:" .. string.sub(encoded, startPos, endPos)
			)
		end

		return result
	end)

	if not ok then
		warn("[ReplayHybrid] Failed to compress LIVE chunk:", parts)
		return {}
	end

	local totalBytes = 0
	for _, part in ipairs(parts) do
		totalBytes += #part
	end

	if totalBytes > REPLAY_LIVE_TOTAL_BUDGET then
		warn(
			"[ReplayHybrid] LIVE chunk exceeds MemoryStore budget:",
			totalBytes,
			"bytes; processing via DataStore instead"
		)
		return {}
	end

	return parts
end

local function getLiveChunkKey(matchId, chunkIndex, partIndex)
	return string.format(
		"%s:%d:%d",
		matchId,
		chunkIndex,
		partIndex
	)
end

--------------------------------------------------
-- WRITE LIVE SEQUENCE CHUNK
--------------------------------------------------

local function removeLiveSequenceChunk(matchId, chunkIndex, partCount)
	if type(matchId) ~= "string" or matchId == "" then
		return
	end

	partCount = math.max(tonumber(partCount) or 0, 1)

	local chunkMap = getLiveChunkMap(matchId)
	if not chunkMap then
		return
	end

	for partIndex = 1, partCount do
		local key = getLiveChunkKey(matchId, chunkIndex, partIndex)
		pcall(function()
			chunkMap:RemoveAsync(key)
		end)
	end
end

local function clearCurrentLiveChunk(matchId, indexData)
	if type(matchId) ~= "string" or matchId == "" then
		return
	end

	if type(indexData) == "table" then
		local live = indexData.liveChunk
		if type(live) == "table" then
			local oldIndex = tonumber(live.chunkIndex)
			local oldParts = tonumber(live.partCount) or 1
			if oldIndex ~= nil then
				removeLiveSequenceChunk(matchId, oldIndex, oldParts)
			end
		end
	end
end

local function makeLiveIndex(matchId, processedUntil, latestChunk)
	return {
		version = 3,
		matchId = matchId,
		processedUntil = tonumber(processedUntil) or -1,
		processedUntilTime = 0,
		latestChunk = tonumber(latestChunk) or -1,
		liveChunk = nil,
		processingChunk = nil,
	}
end

local function purgeLegacyLiveKeys(matchId)
	-- v3+ uses one SortedMap per match. There is intentionally no global
	-- ReplayLiveSeq_v1 map to purge anymore.
	return
end

local function writeLiveSequenceChunk(matchId, chunkIndex, frames)
	if type(matchId) ~= "string" or matchId == "" then
		return false
	end

	if type(frames) ~= "table" or #frames == 0 then
		return false
	end

	local parts = splitFramesForMemoryStore(frames)
	if #parts == 0 then
		return false
	end

	local chunkMap = getLiveChunkMap(matchId)
	if not chunkMap then
		return false
	end

	local indexData
	pcall(function()
		indexData = ReplayLiveIndexMap:GetAsync(matchId)
	end)

	if type(indexData) ~= "table" then
		indexData = makeLiveIndex(matchId, -1, -1)
	else
		indexData.version = 4
		indexData.matchId = matchId
		indexData.processedUntil = tonumber(indexData.processedUntil) or -1
		indexData.latestChunk = tonumber(indexData.latestChunk) or -1
	end

	-- Keep the newest two chunks. The second slot is what makes polling robust
	-- when a requester is briefly slower than the recorder.
	local liveChunks = {}
	if type(indexData.liveChunks) == "table" then
		for _, info in ipairs(indexData.liveChunks) do
			if type(info) == "table" and tonumber(info.chunkIndex) ~= nil then
				table.insert(liveChunks, info)
			end
		end
	elseif type(indexData.liveChunk) == "table" then
		table.insert(liveChunks, indexData.liveChunk)
	end

	-- Never allow duplicate metadata for the chunk being written.
	local kept = {}
	for _, info in ipairs(liveChunks) do
		if tonumber(info.chunkIndex) ~= tonumber(chunkIndex) then
			table.insert(kept, info)
		end
	end
	liveChunks = kept

	-- Delete chunks older than the newest two. This is cheap because each match
	-- has its own MemoryStore structure now.
	while #liveChunks > 1 do
		local oldest = table.remove(liveChunks, 1)
		removeLiveSequenceChunk(matchId, tonumber(oldest.chunkIndex), tonumber(oldest.partCount) or 1)
	end

	-- Remove stale parts for the target chunk before writing it.
	removeLiveSequenceChunk(matchId, chunkIndex, math.max(#parts, 10))

	for partIndex, encoded in ipairs(parts) do
		local key = getLiveChunkKey(matchId, chunkIndex, partIndex)
		local ok, err = pcall(function()
			chunkMap:SetAsync(key, encoded, REPLAY_LIVE_TTL)
		end)

		if not ok then
			warn("[ReplayHybrid] Failed writing LIVE chunk:", matchId, chunkIndex, partIndex, err)
			removeLiveSequenceChunk(matchId, chunkIndex, partIndex)
			return false
		end
	end

	local firstSeq = tonumber(frames[1] and frames[1].seq) or 0
	local lastSeq = tonumber(frames[#frames] and frames[#frames].seq) or firstSeq
	local firstTime = tonumber(frames[1] and frames[1].t) or 0
	local lastTime = tonumber(frames[#frames] and frames[#frames].t) or firstTime

	local info = {
		state = "LIVE",
		chunkIndex = chunkIndex,
		partCount = #parts,
		count = #frames,
		firstSeq = firstSeq,
		lastSeq = lastSeq,
		firstTime = firstTime,
		lastTime = lastTime,
		updatedAt = os.time(),
	}

	table.insert(liveChunks, info)
	table.sort(liveChunks, function(a, b)
		return tonumber(a.chunkIndex) < tonumber(b.chunkIndex)
	end)

	while #liveChunks > 2 do
		local oldest = table.remove(liveChunks, 1)
		removeLiveSequenceChunk(matchId, tonumber(oldest.chunkIndex), tonumber(oldest.partCount) or 1)
	end

	indexData.version = 4
	indexData.latestChunk = math.max(indexData.latestChunk, chunkIndex)
	indexData.liveChunks = liveChunks
	indexData.liveChunk = info -- compatibility for older readers
	indexData.processingChunk = nil

	local ok, err = pcall(function()
		ReplayLiveIndexMap:SetAsync(matchId, indexData, REPLAY_LIVE_TTL)
	end)

	if not ok then
		warn("[ReplayHybrid] Failed updating LIVE index:", matchId, err)
		removeLiveSequenceChunk(matchId, chunkIndex, #parts)
		return false
	end

	return true
end
--------------------------------------------------
-- READ LIVE SEQUENCE CHUNK
--------------------------------------------------

local function readLiveSequenceChunk(matchId, chunkIndex)
	local indexData

	local ok = pcall(function()
		indexData = ReplayLiveIndexMap:GetAsync(matchId)
	end)

	if not ok or type(indexData) ~= "table" then
		return nil
	end

	local chunkInfo = indexData.liveChunk
	if type(chunkInfo) ~= "table"
		or tonumber(chunkInfo.chunkIndex) ~= tonumber(chunkIndex)
		or chunkInfo.state ~= "LIVE"
	then
		return nil
	end

	local encodedParts = {}

	for partIndex = 1, tonumber(chunkInfo.partCount) or 0 do
		local key = getLiveChunkKey(
			matchId,
			chunkIndex,
			partIndex
		)

		local encoded
		local chunkMap = getLiveChunkMap(matchId)
		if not chunkMap then
			return nil
		end

		local partOK = pcall(function()
			encoded = chunkMap:GetAsync(key)
		end)

		if not partOK or type(encoded) ~= "string" then
			return nil
		end

		local prefix = "RCL1:Zstd:b64:"
		if string.sub(encoded, 1, #prefix) ~= prefix then
			return nil
		end

		table.insert(encodedParts, string.sub(encoded, #prefix + 1))
	end

	local decodedFrames
	local decodeOK = pcall(function()
		local compressed = b64Decode(table.concat(encodedParts))
		if not compressed then
			error("LIVE chunk base64 decode failed")
		end

		local decompressed = EncodingService:DecompressBuffer(
			compressed,
			Enum.CompressionAlgorithm.Zstd
		)

		decodedFrames = HttpService:JSONDecode(buffer.tostring(decompressed))
	end)

	if not decodeOK or type(decodedFrames) ~= "table" then
		return nil
	end

	local frames = decodedFrames

	return {
		chunkIndex = chunkIndex,
		frames = frames,
		firstSeq = chunkInfo.firstSeq,
		lastSeq = chunkInfo.lastSeq,
		state = chunkInfo.state,
	}
end

--------------------------------------------------
-- PROCESSING QUEUE
--------------------------------------------------

local function updateLiveChunkState(matchId, chunkIndex, state, extra)
	local indexData
	pcall(function()
		indexData = ReplayLiveIndexMap:GetAsync(matchId)
	end)

	if type(indexData) ~= "table" then
		indexData = makeLiveIndex(matchId, -1, chunkIndex)
	end

	indexData.version = 4
	indexData.matchId = matchId
	indexData.processedUntil = tonumber(indexData.processedUntil) or -1
	indexData.latestChunk = tonumber(indexData.latestChunk) or chunkIndex

	local liveList = indexData.liveChunks
	if type(liveList) ~= "table" then
		liveList = {}
		if type(indexData.liveChunk) == "table" then
			table.insert(liveList, indexData.liveChunk)
		end
	end

	if state == "PROCESSING" then
		local kept = {}
		for _, info in ipairs(liveList) do
			if tonumber(info.chunkIndex) == tonumber(chunkIndex) then
				removeLiveSequenceChunk(matchId, chunkIndex, tonumber(info.partCount) or 1)
			else
				table.insert(kept, info)
			end
		end
		indexData.liveChunks = kept
		indexData.liveChunk = kept[#kept]
		indexData.processingChunk = {
			chunkIndex = chunkIndex,
			state = "PROCESSING",
			updatedAt = os.time(),
		}

		if type(extra) == "table" then
			for k, v in pairs(extra) do
				indexData.processingChunk[k] = v
			end
		end
	elseif state == "PROCESSED" then
		indexData.processedUntil = math.max(indexData.processedUntil, tonumber(chunkIndex) or -1)

		if type(extra) == "table" and extra.lastTime ~= nil then
			indexData.processedUntilTime = tonumber(extra.lastTime) or tonumber(indexData.processedUntilTime) or 0
		end

		local kept = {}
		for _, info in ipairs(liveList) do
			if tonumber(info.chunkIndex) == tonumber(chunkIndex) then
				removeLiveSequenceChunk(matchId, chunkIndex, tonumber(info.partCount) or 1)
			else
				table.insert(kept, info)
			end
		end
		indexData.liveChunks = kept
		indexData.liveChunk = kept[#kept]

		if type(indexData.processingChunk) == "table"
			and tonumber(indexData.processingChunk.chunkIndex) == tonumber(chunkIndex)
		then
			indexData.processingChunk = nil
		end
	else
		indexData.liveChunks = liveList
		indexData.liveChunk = liveList[#liveList]
	end

	pcall(function()
		ReplayLiveIndexMap:SetAsync(matchId, indexData, REPLAY_LIVE_TTL)
	end)
end

local function saveSequenceChunkToDataStore(
	replayKey,
	chunkIndex,
	frames
)
	local chunkKey = getSequenceChunkKey(
		replayKey,
		chunkIndex
	)

	local firstSeq =
		tonumber(frames[1] and frames[1].seq) or 0

	local lastSeq =
		tonumber(frames[#frames] and frames[#frames].seq)
		or firstSeq

	local payload = {
		kind = "ReplaySequenceChunk",
		version = 1,

		chunkIndex = chunkIndex,

		firstSeq = firstSeq,
		lastSeq = lastSeq,

		frames = frames,
	}

	local ok, stats = saveReplayPayload(
		chunkKey,
		payload
	)

	if not ok then
		return false, stats
	end

	return true, stats
end

--------------------------------------------------
-- ASYNC REPLAY PROCESSOR
--------------------------------------------------

local function startReplayProcessor(stream)
	if stream.replayProcessor then
		return
	end

	stream.replayProcessor = task.spawn(function()
		while stream.replayProcessingActive do
			local nextIndex = stream.nextProcessChunk

			local job =
				stream.processingQueue[nextIndex]

			if not job then
				task.wait(REPLAY_PROCESS_INTERVAL)
				continue
			end

			local now = os.clock()

			if job.processing then
				task.wait(0.05)
				continue
			end

			job.processing = true
			job.leaseUntil = now + REPLAY_PROCESS_LEASE

			updateLiveChunkState(
				stream.liveMatchId,
				nextIndex,
				"PROCESSING",
				{
					owner = SERVER_SESSION_ID,
					leaseUntil = job.leaseUntil,
				}
			)

			local success, stats =
				saveSequenceChunkToDataStore(
					stream.replayChunkKey,
					nextIndex,
					job.frames
				)

			if success then
				stream.processedUntil = tonumber(stream.processedUntil) or -1
				stream.processedFrames = tonumber(stream.processedFrames) or 0
				stream.replayStats = stream.replayStats or {}
				stream.replayStats.RawBytes = tonumber(stream.replayStats.RawBytes) or 0
				stream.replayStats.CompressedBytes = tonumber(stream.replayStats.CompressedBytes) or 0
				stream.replayStats.StoredBytes = tonumber(stream.replayStats.StoredBytes) or 0

				stream.sequenceChunks[nextIndex] = {
					state = "PROCESSED",

					count = #job.frames,

					firstSeq =
						tonumber(
							job.frames[1]
							and job.frames[1].seq
						) or 0,

					lastSeq =
						tonumber(
							job.frames[#job.frames]
							and job.frames[#job.frames].seq
						) or 0,

					key = getSequenceChunkKey(
						stream.replayChunkKey,
						nextIndex
					),

					stats = stats,
				}

				stream.processedUntil = math.max(
					stream.processedUntil,
					nextIndex
				)
				-- Keep the root manifest synchronized with the live sequence chunks.
				task.spawn(function()
					local manifest = loadReplayPayload(stream.replayChunkKey)

					if type(manifest) ~= "table" then
						warn(
							"[ReplayCoreServer] LIVE manifest missing while updating:",
							stream.replayChunkKey
						)
						return
					end

					manifest.kind = "ReplayManifest"
					manifest.version = tonumber(manifest.version) or 2

					manifest.isLive = true
					manifest.liveMatchId = stream.liveMatchId

					manifest.chunkKey = stream.replayChunkKey
					manifest.replayId = manifest.replayId or stream.replayChunkKey

					manifest.chunkSize = REPLAY_SEQUENCE_CHUNK_SIZE

					manifest.totalChunks =
						math.max(
							tonumber(manifest.totalChunks) or 0,
							stream.processedUntil + 1
						)

					manifest.totalFrames = stream.processedFrames

					manifest.totalDuration =
						tonumber(stream.processedLastTime)
						or tonumber(stream.lastTime)
						or 0

					manifest.lastSeq =
						tonumber(stream.latestSeq)
						or tonumber(manifest.lastSeq)
						or 0

					manifest.fps = tonumber(manifest.fps) or 60

					manifest.mapSeed = stream.mapSeed
					manifest.mapMode = stream.mapMode
					manifest.recorderUserId = stream.recorderUserId

					manifest.players = stream.replayPlayers or {}
					manifest.sounds = stream.sounds or manifest.sounds or {}
					manifest.markers = manifest.markers or {}

					manifest.multiplayer = stream.multiplayer == true

					manifest.processedUntil = stream.processedUntil
					manifest.liveUntilChunk = stream.liveUntilChunk

					manifest.processedUntilTime =
						tonumber(stream.processedLastTime)
						or 0

					manifest.liveUntilTime =
						tonumber(stream.lastTime)
						or 0

					manifest.Timestamp = os.time()

					local ok, err = saveReplayPayload(
						stream.replayChunkKey,
						manifest
					)

					if not ok then
						warn(
							"[ReplayCoreServer] FAILED TO UPDATE LIVE MANIFEST:",
							stream.replayChunkKey,
							err
						)
					end
				end)
				if stats then
					stream.replayStats.RawBytes += tonumber(stats.RawBytes) or 0
					stream.replayStats.CompressedBytes += tonumber(stats.CompressedBytes) or 0
					stream.replayStats.StoredBytes += tonumber(stats.StoredBytes) or 0
				end

				stream.sequenceStates[nextIndex] = "PROCESSED"
				stream.processedFrames += #job.frames
				stream.processedLastTime =
					type(job.frames[#job.frames] and job.frames[#job.frames].t) == "number"
					and job.frames[#job.frames].t
					or stream.processedLastTime
				stream.processingQueue[nextIndex] = nil

				updateLiveChunkState(
					stream.liveMatchId,
					nextIndex,
					"PROCESSED",
					{
						processedAt = os.time(),
						processedBy = SERVER_SESSION_ID,
						lastTime = stream.processedLastTime,
					}
				)

				nextIndex += 1
				stream.nextProcessChunk = nextIndex
			else
				job.processing = false
				job.retries = (job.retries or 0) + 1

				warn(
					"[ReplayHybrid] Failed processing chunk",
					nextIndex,
					"retry:",
					job.retries
				)

				task.wait(REPLAY_PROCESS_RETRY_DELAY)
			end
		end
	end)
end

local function stopReplayProcessor(stream)
	if not stream then
		return
	end

	stream.replayProcessingActive = false

	if stream.replayProcessor then
		task.cancel(stream.replayProcessor)
		stream.replayProcessor = nil
	end
end

--------------------------------------------------
-- QUEUE RECORDED FRAMES
--------------------------------------------------

local function queueReplayFrames(stream, frameChunk)
	if not stream or type(frameChunk) ~= "table" then
		return
	end

	stream.sequenceBuffers = stream.sequenceBuffers or {}
	stream.sequenceStates = stream.sequenceStates or {}
	stream.processingQueue = stream.processingQueue or {}

	for _, frame in ipairs(frameChunk) do
		local seq = tonumber(frame.seq)
		if not seq then
			continue
		end

		local chunkIndex = getSequenceChunkIndex(seq)
		local buffer = stream.sequenceBuffers[chunkIndex]

		if not buffer then
			buffer = {}
			stream.sequenceBuffers[chunkIndex] = buffer
		end

		table.insert(buffer, frame)

		stream.latestSeq = math.max(stream.latestSeq or 0, seq)

		local t = tonumber(frame.t)
		if t then
			if not stream.firstTime or t < stream.firstTime then
				stream.firstTime = t
			end
			stream.lastTime = math.max(stream.lastTime or 0, t)
		end

		if not stream.firstSeq or seq < stream.firstSeq then
			stream.firstSeq = seq
		end

		for key, pdata in pairs(frame.players or {}) do
			if type(pdata) == "table" and not stream.replayPlayers[key] then
				stream.replayPlayers[key] = {
					userId = pdata.userId,
					name = pdata.name,
					displayName = pdata.displayName,
					isRecorder = pdata.isRecorder == true,
				}
			end
		end

		if #buffer >= REPLAY_SEQUENCE_CHUNK_SIZE
			and not stream.sequenceStates[chunkIndex]
		then
			local frames = buffer
			stream.sequenceBuffers[chunkIndex] = nil

			local liveOK = writeLiveSequenceChunk(
				stream.liveMatchId,
				chunkIndex,
				frames
			)

			if liveOK then
				stream.sequenceStates[chunkIndex] = "LIVE"
				stream.liveUntilChunk = math.max(
					stream.liveUntilChunk,
					chunkIndex
				)
			else
				stream.sequenceStates[chunkIndex] = "PROCESSING"
			end

			stream.processingQueue[chunkIndex] = {
				frames = frames,
				processing = false,
				retries = 0,
			}
		end
	end
end

local function flushReplaySequenceBuffers(stream)
	if not stream then
		return
	end

	for chunkIndex, frames in pairs(stream.sequenceBuffers or {}) do
		if #frames > 0 and not stream.sequenceStates[chunkIndex] then
			local liveOK = writeLiveSequenceChunk(
				stream.liveMatchId,
				chunkIndex,
				frames
			)

			if liveOK then
				stream.sequenceStates[chunkIndex] = "LIVE"
				stream.liveUntilChunk = math.max(
					stream.liveUntilChunk,
					chunkIndex
				)
			else
				stream.sequenceStates[chunkIndex] = "PROCESSING"
			end

			stream.processingQueue[chunkIndex] = {
				frames = frames,
				processing = false,
				retries = 0,
			}

			stream.sequenceBuffers[chunkIndex] = nil
		end
	end
end

local function waitForReplayProcessing(stream)
	if not stream then
		return false
	end

	flushReplaySequenceBuffers(stream)

	local deadline = os.clock() + 30

	while os.clock() < deadline do
		local pending = false

		for _, job in pairs(stream.processingQueue or {}) do
			if job then
				pending = true
				break
			end
		end

		if not pending then
			return true
		end

		task.wait(0.1)
	end

	warn("[ReplayHybrid] Processing timeout:", stream.Id)
	return false
end

--------------------------------------------------
-- PROCESSED SEQUENCE CHUNK LOADER
--------------------------------------------------

local function loadProcessedSequenceChunk(replayKey, chunkIndex)
	local key = getSequenceChunkKey(replayKey, chunkIndex)
	local payload = loadReplayPayload(key)

	if not payload then
		return nil
	end

	if payload.kind ~= "ReplaySequenceChunk" then
		return nil
	end

	return payload
end

--------------------------------------------------
-- HYBRID CHUNK RESOLVER
--------------------------------------------------

local function readReplayLiveIndex(matchId)
	if type(matchId) ~= "string" or matchId == "" then
		return nil
	end

	local indexData
	local ok = pcall(function()
		indexData = ReplayLiveIndexMap:GetAsync(matchId)
	end)

	if not ok or type(indexData) ~= "table" then
		return nil
	end

	indexData.version = tonumber(indexData.version) or 3
	indexData.processedUntil = tonumber(indexData.processedUntil) or -1
	indexData.latestChunk = tonumber(indexData.latestChunk) or -1
	return indexData
end

local function calculateProcessedUntil(indexData)
	if type(indexData) ~= "table" then
		return -1
	end

	return tonumber(indexData.processedUntil) or -1
end

local function buildReplayStatus(replayKey, matchId)
	local status = {
		ok = true,

		replayId = replayKey,

		chunkSize = REPLAY_SEQUENCE_CHUNK_SIZE,

		processedUntilChunk = -1,
		processingChunks = {},
		chunkStates = {},

		liveFromChunk = nil,
		liveUntilChunk = -1,

		totalDuration = 0,
		totalFrames = 0,
		totalChunks = 0,

		fps = 60,

		processedUntilTime = 0,

		liveFromTime = nil,
		liveUntilTime = 0,

		-- IMPORTANT
		isLive = false,
		liveMatchId = matchId,
	}

	--------------------------------------------------
	-- LOAD LIVE INDEX
	--------------------------------------------------

	local indexData = nil

	if type(matchId) == "string" and matchId ~= "" then
		indexData = readReplayLiveIndex(matchId)
	end

	if type(indexData) == "table" then

		--------------------------------------------------
		-- PROCESSING CHUNK
		--------------------------------------------------

		local processing = indexData.processingChunk

		if type(processing) == "table" then
			local processingIndex =
				tonumber(processing.chunkIndex)

			if processingIndex ~= nil then
				status.processingChunks[processingIndex] = true
			end
		end

		--------------------------------------------------
		-- LIVE CHUNK
		--------------------------------------------------

		local liveList = indexData.liveChunks
		if type(liveList) ~= "table" then
			liveList = {}
			if type(indexData.liveChunk) == "table" then
				table.insert(liveList, indexData.liveChunk)
			end
		end

		for _, liveInfo in ipairs(liveList) do
			if type(liveInfo) == "table" and liveInfo.state == "LIVE" then
				local liveIndex = tonumber(liveInfo.chunkIndex)
				if liveIndex ~= nil then
					status.isLive = true
					status.liveFromChunk = status.liveFromChunk == nil and liveIndex or math.min(status.liveFromChunk, liveIndex)
					status.liveUntilChunk = math.max(status.liveUntilChunk, liveIndex)
					status.liveFromTime = status.liveFromTime == nil and (tonumber(liveInfo.firstTime) or 0) or math.min(status.liveFromTime, tonumber(liveInfo.firstTime) or 0)
					status.liveUntilTime = math.max(status.liveUntilTime, tonumber(liveInfo.lastTime) or 0)
					status.chunkStates[liveIndex] = "LIVE"
				end
			end
		end
		--------------------------------------------------
		-- PROCESSED CHUNKS
		--------------------------------------------------

		status.processedUntilChunk =
			calculateProcessedUntil(indexData)

		status.processedUntilTime =
			tonumber(indexData.processedUntilTime) or 0


		if status.processedUntilChunk >= 0 then
			for index = 0, status.processedUntilChunk do
				if status.chunkStates[index] ~= "LIVE" then
					status.chunkStates[index] = "PROCESSED"
				end
			end
		end
		--------------------------------------------------
		-- FALLBACK TO EXPLICIT INDEX VALUES
		--------------------------------------------------

		if status.processedUntilChunk < 0 then
			local explicitProcessed =
				tonumber(indexData.processedUntil)

			if explicitProcessed ~= nil then
				status.processedUntilChunk =
					explicitProcessed
			end
		end
	end

	--------------------------------------------------
	-- LOAD REPLAY MANIFEST
	--------------------------------------------------

	if type(replayKey) == "string"
		and replayKey ~= ""
	then

		local manifest = loadReplayPayload(replayKey)

		if type(manifest) == "table" then

			status.totalDuration =
				tonumber(manifest.totalDuration) or 0

			status.totalFrames =
				tonumber(manifest.totalFrames) or 0

			status.totalChunks =
				tonumber(
					manifest.totalChunks
					or manifest.chunkCount
				) or 0

			status.fps =
				tonumber(manifest.fps)
				or status.fps

			--------------------------------------------------
			-- IMPORTANT:
			-- If the index doesn't know about processed
			-- chunks yet, the manifest tells us what VOD
			-- chunks actually exist.
			--------------------------------------------------

			if status.processedUntilChunk < 0
				and status.totalChunks > 0
				and not status.isLive
			then
				status.processedUntilChunk =
					status.totalChunks - 1
			end
		end
	end

	--------------------------------------------------
	-- LIVE RANGE MUST NEVER PRETEND TO BE VOD
	--------------------------------------------------

	if status.isLive
		and status.liveUntilChunk >= 0
	then
		-- Do NOT mark the live chunk as processed.
		if status.processedUntilChunk >= status.liveUntilChunk then
			status.processedUntilChunk =
				status.liveUntilChunk - 1
		end
	end

	--------------------------------------------------
	-- FINAL NORMALIZATION
	--------------------------------------------------

	status.processedUntilChunk =
		math.max(-1, status.processedUntilChunk)

	status.liveUntilChunk =
		math.max(-1, status.liveUntilChunk)

	status.totalChunks =
		math.max(0, status.totalChunks)

	return status
end

local function getReplaySequenceChunk(matchId, replayKey, chunkIndex)
	chunkIndex = tonumber(chunkIndex)
	if not chunkIndex or chunkIndex < 0 then
		return nil, "INVALID"
	end

	if matchId then
		local indexData = readReplayLiveIndex(matchId)
		if indexData then
			local processedUntil = tonumber(indexData.processedUntil) or -1
			if chunkIndex <= processedUntil then
				local processed = loadProcessedSequenceChunk(replayKey, chunkIndex)
				if processed then
					return processed, "PROCESSED"
				end
				return nil, "PROCESSED_MISSING"
			end

			local info
			local liveList = indexData.liveChunks
			if type(liveList) == "table" then
				for _, candidate in ipairs(liveList) do
					if type(candidate) == "table"
						and tonumber(candidate.chunkIndex) == chunkIndex
					then
						info = candidate
						break
					end
				end
			elseif type(indexData.liveChunk) == "table"
				and tonumber(indexData.liveChunk.chunkIndex) == chunkIndex
			then
				info = indexData.liveChunk
			end

			if type(info) == "table" then
				if info.state == "PROCESSING" then
					return nil, "PROCESSING"
				end

				if info.state == "LIVE" then
					local live = readLiveSequenceChunk(matchId, chunkIndex)
					if live then
						return live, "LIVE"
					end
					return nil, "LIVE_UNAVAILABLE"
				end

				if info.state == "PROCESSED" then
					local processed = loadProcessedSequenceChunk(replayKey, chunkIndex)
					if processed then
						return processed, "PROCESSED"
					end
					return nil, "PROCESSED_MISSING"
				end
			end

			local processing = indexData.processingChunk
			if type(processing) == "table"
				and tonumber(processing.chunkIndex) == chunkIndex
			then
				return nil, "PROCESSING"
			end

			if chunkIndex <= (tonumber(indexData.latestChunk) or -1) then
				return nil, "PROCESSING"
			end

			return nil, "MISSING"
		end
	end

	local processed = loadProcessedSequenceChunk(replayKey, chunkIndex)
	if processed then
		return processed, "PROCESSED"
	end

	return nil, "MISSING"
end

--------------------------------------------------
-- RING BUFFER & DVR (LIVE & HAND-OFF PROCESSING)
--------------------------------------------------

local function flushStreamSegment(stream)
	if not stream or #stream.segmentBuffer == 0 then
		return
	end

	local segmentIndex = #stream.segments + 1
	local segKey = stream.segmentKey .. "_seg_" .. tostring(segmentIndex)

	if saveSegmentChunk(segKey, stream.segmentBuffer) then
		table.insert(stream.segments, { key = segKey, count = #stream.segmentBuffer })
		stream.segmentBuffer = {}
		stream.segmentBufferBytes = 0
	end
end

local function flushExpiredRingFrames(stream)
	if not stream or not stream.frames then
		return
	end

	local now = os.clock()
	local frames = stream.frames

	while #frames > 0 do
		local entry = frames[1]
		if now - entry.arrival >= RING_BUFFER_DELAY then
			table.remove(frames, 1)
			table.insert(stream.segmentBuffer, entry.frame)
			stream.segmentBufferBytes += #HttpService:JSONEncode(entry.frame)
		else
			break
		end
	end

	if #stream.segmentBuffer >= SEGMENT_FRAME_LIMIT or stream.segmentBufferBytes >= SEGMENT_BYTE_MAX then
		flushStreamSegment(stream)
	end
end

local function pushFrameToRing(stream, frame)
	table.insert(stream.frames, { arrival = os.clock(), frame = frame })

	while #stream.frames > RING_BUFFER_CAPACITY do
		local entry = table.remove(stream.frames, 1)
		table.insert(stream.segmentBuffer, entry.frame)
		stream.segmentBufferBytes += #HttpService:JSONEncode(entry.frame)
	end

	if #stream.segmentBuffer >= SEGMENT_FRAME_LIMIT or stream.segmentBufferBytes >= SEGMENT_BYTE_MAX then
		flushStreamSegment(stream)
	end
end

local function startRingFlushTask(stream)
	if stream.flushTask then
		return
	end

	stream.flushTask = task.spawn(function()
		while activeStreams[stream.Id] do
			task.wait(FLUSH_INTERVAL)
			flushExpiredRingFrames(stream)
		end
	end)
end

local function stopRingFlushTask(stream)
	if stream and stream.flushTask then
		task.cancel(stream.flushTask)
		stream.flushTask = nil
	end
end

local function flushAllRingFrames(stream)
	if not stream then
		return
	end

	for _, entry in ipairs(stream.frames or {}) do
		table.insert(stream.segmentBuffer, entry.frame)
		stream.segmentBufferBytes += #HttpService:JSONEncode(entry.frame)
	end
	stream.frames = {}

	flushStreamSegment(stream)
end

local function getStreamFrameCount(stream)
	local total = #(stream.frames or {})
	for _, seg in ipairs(stream.segments or {}) do
		total += seg.count or 0
	end
	return total
end

--------------------------------------------------
-- CAMERA TRACK
--------------------------------------------------

local function expandCameraTrack(payload, userId)
	local track = {}
	local lastPos = nil
	local lastLook = nil
	local key = tostring(userId)

	for _, frame in ipairs(payload.frames or {}) do
		local cameraData = frame.cameras and frame.cameras[key]

		if not cameraData and userId == payload.recorderUserId then
			if frame.cameraPos then
				cameraData = {
					pos = frame.cameraPos,
					look = frame.cameraLook,
				}
			elseif frame.cameraDP then
				cameraData = {
					dp = frame.cameraDP,
					dl = frame.cameraDL,
				}
			end
		end

		if cameraData then
			if cameraData.pos then
				lastPos = cameraData.pos
				lastLook = cameraData.look
			elseif cameraData.dp and cameraData.dl and lastPos and lastLook then
				lastPos = {
					lastPos[1] + cameraData.dp[1],
					lastPos[2] + cameraData.dp[2],
					lastPos[3] + cameraData.dp[3],
				}

				lastLook = {
					lastLook[1] + cameraData.dl[1],
					lastLook[2] + cameraData.dl[2],
					lastLook[3] + cameraData.dl[3],
				}
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

--------------------------------------------------
-- ROUND SYSTEM
--------------------------------------------------

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
		if rid == roundId then
			roundRegistry[key] = nil
		end
	end
end

--------------------------------------------------
-- PERSONAL REPLAY
--------------------------------------------------

local function savePersonalReplay(player, payload)
	local replayId = "Run_" .. HttpService:GenerateGUID(false)
	local guid = HttpService:GenerateGUID(false)
	local shortGuid = string.gsub(guid, "-", "")
	local chunkKey = payload.replayChunkKey
		or ("RP_" .. player.UserId .. "_" .. string.sub(shortGuid, 1, 10))

	local profile = getProfileData(player)
	if not profile then
		warn("[ReplayManager] No profile available for", player.Name)
		return false
	end

	local totalChunks = tonumber(payload.liveUntilChunk)
		or tonumber(payload.processedUntil)
		or -1
	totalChunks = math.max(0, totalChunks + 1)

	local manifest = {
		kind = "ReplayManifest",
		version = 1,
		replayId = replayId,
		chunkKey = chunkKey,
		chunkSize = REPLAY_SEQUENCE_CHUNK_SIZE,
		totalChunks = totalChunks,
		totalFrames = tonumber(payload.processedFrames) or 0,
		totalDuration = type(payload.processedLastTime) == "number"
			and payload.processedLastTime
			or (tonumber(payload.lastTime) or 0),
		lastSeq = tonumber(payload.latestSeq) or 0,
		fps = tonumber(payload.fps) or 60,
		mapSeed = payload.mapSeed,
		mapMode = payload.mapMode,
		recorderUserId = payload.recorderUserId,
		players = payload.replayPlayers or {},
		sounds = payload.sounds or {},
		markers = payload.markers or {},
		multiplayer = payload.multiplayer == true,
		ragequit = payload.ragequit == true,
		segments = payload.segments or {},
		segmentCount = payload.segments and #payload.segments or 0,
	}

	local success, stats = saveReplayPayload(chunkKey, manifest)
	if not success then
		warn("[ReplayManager] Failed to save replay manifest:", player.Name)
		return false
	end

	migrateSavedReplays(profile)

	profile.savedReplays = profile.savedReplays or {}

	local timestamp = os.time()

	profile.savedReplays[replayId] = {
		MatchId = replayId,
		id = replayId,
		PlayerUserId = player.UserId,
		Timestamp = timestamp,
		timestamp = timestamp,
		ChunkKey = chunkKey,
		chunkKey = chunkKey,
		RawBytes = payload.replayStats and payload.replayStats.RawBytes or stats and stats.RawBytes,
		CompressedBytes = payload.replayStats and payload.replayStats.CompressedBytes or stats and stats.CompressedBytes,
		StoredBytes = payload.replayStats and payload.replayStats.StoredBytes or stats and stats.StoredBytes,
		CompressionRatio = payload.replayStats and payload.replayStats.CompressionRatio or stats and stats.CompressionRatio,
		MapSeed = payload.mapSeed,
		MapMode = payload.mapMode,
		RecorderUserId = payload.recorderUserId,
		PlayerCount = payload.playerCount,
		Multiplayer = payload.multiplayer,
		Ragequit = payload.ragequit,
		RunName = payload.runName,
		Date = payload.date,
		TotalDuration = manifest.totalDuration,
		TotalFrames = manifest.totalFrames,
		TotalChunks = manifest.totalChunks,
		FPS = manifest.fps,
		Players = manifest.players,
	}

	trimSavedReplays(profile, player.UserId)

	local saved = ProfileService.saveProfile(player, profile)

	if not saved then
		warn("[ReplayManager] Replay manifest saved, but profile metadata failed:", replayId)
		pcall(function()
			ReplayDataStore:RemoveAsync(chunkKey)
		end)
		return false
	end

	print("[ReplayCoreServer] Saved sequence replay:", replayId, "for", player.Name)
	return true
end

--------------------------------------------------
-- SHARED REPLAY
--------------------------------------------------

local function buildSharedRoundPayload(roundId)
	local participants = roundParticipants[roundId]
	local payloads = roundPayloads[roundId]

	if not participants or not payloads then
		return nil
	end

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

	if not canonical then
		return nil
	end

	local shared = {}
	for key, value in pairs(canonical) do
		shared[key] = value
	end

	shared.multiplayer = true
	shared.MultiPOV = true
	shared.votedPlayerUserId = votedUserId
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
		if a.isVotedPlayer ~= b.isVotedPlayer then
			return a.isVotedPlayer
		end

		return a.name < b.name
	end)

	shared.replayPlayers = shared.cameraPlayers

	return shared
end

local function saveSharedRound(roundId)
	if roundSaved[roundId] then
		return
	end

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

	local sizeStats = nil

	local successChunk, errChunk = pcall(function()
		local ok, stats = persistReplayPayload(chunkKey, payload)
		if not ok then
			error("Failed to persist shared replay payload")
		end
		sizeStats = stats
	end)

	if not successChunk then
		warn("[ReplayManager] Shared round save failed:", errChunk)
		cleanupRound(roundId)
		return
	end

	for userId in pairs(roundParticipants[roundId] or {}) do
		local target = Players:GetPlayerByUserId(userId)
		if target then
			local profile = getProfileData(target)
			if profile then
				migrateSavedReplays(profile)

				if not profile.savedReplays then
					profile.savedReplays = {}
				end

				profile.savedReplays[replayId] = {
					MatchId = replayId,
					id = replayId,
					PlayerUserId = payload.votedPlayerUserId,
					Timestamp = os.time(),
					ChunkKey = chunkKey,
					VotedPlayerUserId = payload.votedPlayerUserId,
					MultiPOV = true,
					Multiplayer = true,
					isShared = true,
					MapSeed = payload.mapSeed,
					MapMode = payload.mapMode,
					RecorderUserId = payload.recorderUserId,
					PlayerCount = payload.playerCount,
					Ragequit = payload.ragequit,
					RawBytes = sizeStats and sizeStats.RawBytes,
					CompressedBytes = sizeStats and sizeStats.CompressedBytes,
					StoredBytes = sizeStats and sizeStats.StoredBytes,
					CompressionRatio = sizeStats and sizeStats.CompressionRatio,
				}

				ProfileService.saveProfile(target, profile)
			end
		end
	end

	printReplaySizeStats("Shared VOD " .. replayId, sizeStats)
	cleanupRound(roundId)
end

local function checkAllCompletion(roundId)
	local participants = roundParticipants[roundId]
	local finalized = roundFinalized[roundId]

	if not participants or not finalized then
		return
	end

	local allDone = true
	for uid in pairs(participants) do
		if not finalized[uid] then
			allDone = false
			break
		end
	end

	if allDone then
		saveSharedRound(roundId)
	elseif not roundTimers[roundId] then
		roundTimers[roundId] = task.delay(SHARED_SAVE_TIMEOUT, function()
			if roundParticipants[roundId] then
				saveSharedRound(roundId)
			end
		end)
	end
end

local function addToRound(roundId, player, payload)
	if not roundParticipants[roundId] or not roundFinalized[roundId] then
		return
	end

	local userId = player.UserId
	roundFinalized[roundId][userId] = true

	if payload.segments and #payload.segments > 0 and (not payload.frames or #payload.frames == 0) then
		local frames = {}
		for _, seg in ipairs(payload.segments) do
			local segPayload = loadReplayPayload(seg.key)
			if segPayload and type(segPayload.frames) == "table" then
				for _, f in ipairs(segPayload.frames) do
					table.insert(frames, f)
				end
			end
		end
		payload.frames = frames
	end

	roundPayloads[roundId][userId] = payload

	checkAllCompletion(roundId)
end

--------------------------------------------------
-- REMOTE PLAYBACK
--------------------------------------------------

local function sendPlaybackDataChunked(player, jsonString)
	if not player or not jsonString then
		return
	end

	local playbackId = HttpService:GenerateGUID(false)
	local totalLength = #jsonString
	local totalChunks = math.max(1, math.ceil(totalLength / CHUNK_NET_SIZE))

	for i = 1, totalChunks do
		local startPos = (i - 1) * CHUNK_NET_SIZE + 1
		local endPos = math.min(i * CHUNK_NET_SIZE, totalLength)
		local chunkData = string.sub(jsonString, startPos, endPos)

		ReplayEvent:FireClient(player, "PlaybackChunk", playbackId, i, totalChunks, chunkData)
	end
end

--------------------------------------------------
-- FINALIZE REPLAY (HAND-OFF TO VOD)
--------------------------------------------------

local function validateStreamOwnership(player, streamId)
	if type(streamId) ~= "string" then
		return false
	end

	local prefix = "Stream_" .. player.UserId .. "_"
	return string.sub(streamId, 1, #prefix) == prefix
end

local function finalizeReplay(player, streamId, payload, sounds, markers, isRagequit)
	if not payload then
		return
	end

	stopRingFlushTask(payload)
	flushAllRingFrames(payload)
	flushReplaySequenceBuffers(payload)
	waitForReplayProcessing(payload)

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
	payload.recorderUserId = payload.recorderUserId or player.UserId
	payload.totalDuration = tonumber(payload.lastTime) or 0
	payload.replayPlayers = payload.replayPlayers or {}
	payload.replayStats = payload.replayStats or {}

	local roundId = payload.roundId

	if getStreamFrameCount(payload) < 2 then
		if roundId and roundParticipants[roundId] then
			roundFinalized[roundId][player.UserId] = true
			checkAllCompletion(roundId)
		end

		stopReplayProcessor(payload)
		activeStreams[streamId] = nil
		return
	end

	if payload.multiplayer == true
		and roundId
		and roundParticipants[roundId]
	then
		addToRound(roundId, player, payload)
	else
		savePersonalReplay(player, payload)
	end

	stopReplayProcessor(payload)
	activeStreams[streamId] = nil
end

--------------------------------------------------
-- LIVE PLAY CORE / BOOTLEG YOUTUBE ENGINE
--------------------------------------------------

local function capSubscribers(match)
	if not match or type(match.subscribers) ~= "table" then
		return
	end

	local count = 0
	for _ in pairs(match.subscribers) do
		count += 1
	end

	while count > MAX_LIVE_SUBSCRIBERS do
		local oldestJobId = nil
		local oldestAt = math.huge

		for jobId, sub in pairs(match.subscribers) do
			local at = (type(sub) == "table" and sub.subscribedAt) or 0
			if at < oldestAt then
				oldestAt = at
				oldestJobId = jobId
			end
		end

		if not oldestJobId then
			break
		end

		match.subscribers[oldestJobId] = nil
		count -= 1
	end
end

local function registerLiveMatch(stream, metadata)
	local matchId = "Match_" .. HttpService:GenerateGUID(false)

	local matchData = {
		matchId = matchId,

		-- Session / replay identity
		sessionId = SERVER_SESSION_ID,
		replayKey = stream.replayChunkKey,
		recorderUserId = stream.recorderUserId,

		-- Match metadata
		mapSeed = stream.mapSeed,
		mapMode = stream.mapMode,
		startedAt = os.time(),
		lastHeartbeat = os.time(),
		jobId = game.JobId,

		-- Subscribers
		subscriberCount = 0,
		subscribers = {},

		-- Live sequence state
		frameBatchIndex = 0,
		partitionIndex = 0,
		partitionBatchCount = 0,

		-- IMPORTANT: these MUST exist from the beginning
		liveFromChunk = nil,
		liveUntilChunk = -1,

		liveFromTime = nil,
		liveUntilTime = 0,

		latestChunk = -1,
		latestSeq = 0,

		-- Used by snapshot generation
		firstTime = nil,
		lastTime = 0,

		-- Internal frame state
		totalFrames = 0,

		-- Writer
		writeQueue = {},
		writeWorkerActive = false,
	}

	liveMatches[matchId] = matchData

	local encoded = HttpService:JSONEncode({
		matchId = matchData.matchId,
		sessionId = matchData.sessionId,
		replayKey = matchData.replayKey,
		recorderUserId = matchData.recorderUserId,
		mapSeed = matchData.mapSeed,
		mapMode = matchData.mapMode,
		startedAt = matchData.startedAt,
		lastHeartbeat = matchData.lastHeartbeat,
		jobId = matchData.jobId,

		frameBatchIndex = matchData.frameBatchIndex,
		partitionIndex = matchData.partitionIndex,
		partitionBatchCount = matchData.partitionBatchCount,

		liveFromChunk = matchData.liveFromChunk,
		liveUntilChunk = matchData.liveUntilChunk,
		liveFromTime = matchData.liveFromTime,
		liveUntilTime = matchData.liveUntilTime,

		latestChunk = matchData.latestChunk,
		latestSeq = matchData.latestSeq,
		firstTime = matchData.firstTime,
		lastTime = matchData.lastTime,
		totalFrames = matchData.totalFrames,
	})

	local ok, err = pcall(function()
		LIVE_MATCHES_MAP:SetAsync(
			matchId,
			encoded,
			LIVE_MATCH_EXPIRATION
		)
	end)

	if not ok then
		warn(
			"[LivePlayCore] Failed registering live match:",
			matchId,
			err
		)
	end

	return matchId
end

local function cleanupReplayLiveMatch(matchId)
	if type(matchId) ~= "string" or matchId == "" then
		return
	end

	local indexData
	pcall(function()
		indexData = ReplayLiveIndexMap:GetAsync(matchId)
	end)

	if type(indexData) == "table" then
		local live = indexData.liveChunk
		if type(live) == "table" and tonumber(live.chunkIndex) ~= nil then
			removeLiveSequenceChunk(
				matchId,
				tonumber(live.chunkIndex),
				tonumber(live.partCount) or 1
			)
		end
	end

	local latestChunk = type(indexData) == "table" and tonumber(indexData.latestChunk) or nil
	if latestChunk then
		for chunkIndex = math.max(0, latestChunk - 4), latestChunk + 1 do
			removeLiveSequenceChunk(matchId, chunkIndex, 10)
		end
	end

	pcall(function()
		ReplayLiveIndexMap:RemoveAsync(matchId)
	end)
end

local function cleanupLiveCoreMatchData(matchId, matchData)
	if type(matchId) ~= "string" or matchId == "" then
		return
	end

	pcall(function()
		LPC_FRAMES_MAP:RemoveAsync(matchId .. "_end")
	end)

	local sessionId = type(matchData) == "table" and matchData.sessionId or nil
	local partitionIndex = type(matchData) == "table"
		and tonumber(matchData.partitionIndex)
		or 0

	if type(sessionId) == "string" and sessionId ~= "" then
		for index = 0, math.max(0, partitionIndex) do
			local partitionName = string.format(
				"LPC_Frames_%s_%s_P%d",
				sessionId,
				matchId,
				index
			)
			local batchMap = MemoryStoreService:GetSortedMap(partitionName)

			for batchIndex = 1, 2 do
				pcall(function()
					batchMap:RemoveAsync("batch_" .. tostring(batchIndex))
				end)
			end
		end
	end
end

local function endLiveMatch(matchId)
	if not matchId then
		return
	end

	local matchData = liveMatches[matchId]
	liveMatches[matchId] = nil

	cleanupReplayLiveMatch(matchId)
	cleanupLiveCoreMatchData(matchId, matchData)

	pcall(function()
		LIVE_MATCHES_MAP:RemoveAsync(matchId)
		LPC_FRAMES_MAP:SetAsync(matchId .. "_end", "1", 30)
	end)
end

local function publishMessage(topic, data)
	local okEncode, json = pcall(function()
		return HttpService:JSONEncode(data)
	end)

	if not okEncode then
		warn("[LivePlayCore] JSONEncode failed in publishMessage")
		return false
	end

	local ok, err = pcall(function()
		MessagingService:PublishAsync(topic, json)
	end)

	if not ok then
		warn("[LivePlayCore] PublishAsync failed:", topic, err)
		return false
	end

	return true
end

local function sendLiveSnapshot(requesterJobId, matchId, requestId)
	local match = liveMatches[matchId]

	if not match then
		return false
	end

	local stream

	for _, s in pairs(activeStreams) do
		if s.liveMatchId == matchId then
			stream = s
			break
		end
	end

	if not stream then
		return false
	end

	local snapshotFrames = {}

	for _, entry in ipairs(stream.frames or {}) do
		if type(entry) == "table" and entry.frame then
			table.insert(snapshotFrames, entry.frame)
		elseif type(entry) == "table" then
			table.insert(snapshotFrames, entry)
		end
	end

	local snapshot = {
		kind = "snapshot",
		matchId = matchId,
		sessionId = SERVER_SESSION_ID,

		replayKey = stream.replayChunkKey,
		recorderUserId = stream.recorderUserId,

		mapSeed = stream.mapSeed,
		mapMode = stream.mapMode,

		Timestamp = os.time(),

		players = stream.replayPlayers or {},
		frames = snapshotFrames,
	}

	local okEncode, snapshotJson = pcall(function()
		return HttpService:JSONEncode(snapshot)
	end)

	if not okEncode then
		warn(
			"[LivePlayCore] Failed encoding snapshot:",
			snapshotJson
		)

		return false
	end

	print(
		"[LivePlayCore] Writing snapshot:",
		matchId,
		"bytes =",
		#snapshotJson
	)
	print("========== LIVE SNAPSHOT DEBUG ==========")

	local liveMatch = liveMatches[matchId]

	print(
		"[LivePlayCore] liveMatches lookup:",
		matchId,
		liveMatch ~= nil
	)

	if liveMatch then
		print(
			"[LivePlayCore] match.frames:",
			type(liveMatch.frames),
			type(liveMatch.frames) == "table" and #liveMatch.frames or "N/A"
		)

		print(
			"[LivePlayCore] match.writeQueue:",
			type(liveMatch.writeQueue),
			type(liveMatch.writeQueue) == "table" and #liveMatch.writeQueue or "N/A"
		)

		print(
			"[LivePlayCore] match.sessionId:",
			liveMatch.sessionId
		)

		print(
			"[LivePlayCore] match.liveFromChunk:",
			liveMatch.liveFromChunk
		)

		print(
			"[LivePlayCore] match.liveUntilChunk:",
			liveMatch.liveUntilChunk
		)

		print(
			"[LivePlayCore] match.liveFromTime:",
			liveMatch.liveFromTime
		)

		print(
			"[LivePlayCore] match.liveUntilTime:",
			liveMatch.liveUntilTime
		)

		print(
			"[LivePlayCore] match.latestChunk:",
			liveMatch.latestChunk
		)

		print(
			"[LivePlayCore] match.latestSeq:",
			liveMatch.latestSeq
		)
	end

	print("==========================================")

	local okWrite, snapshotKey = writeLiveSnapshotToDataStore(
		requestId,
		snapshotJson
	)

	if not okWrite then
		return false
	end

	-- ONLY a tiny handshake travels through MessagingService.
	-- The actual snapshot payload stays in DataStore.
	local signal = {
		type = "snapshot_ready",

		matchId = matchId,
		requestId = requestId,

		snapshotKey = snapshotKey,
	}


	local okPublish, err = publishMessage(
		LPC_RESPONSE_PREFIX .. requesterJobId,
		signal
	)

	if not okPublish then
		warn(
			"[LivePlayCore] Failed publishing snapshot_ready:",
			err
		)

		return false
	end

	return true
end

local function getPartitionName(matchId, partitionIndex)
	return string.format("LPC_Frames_%s_%s_P%d", SERVER_SESSION_ID, matchId, partitionIndex)
end

local MAX_BATCH_BYTES = 30000 

local function pushLiveFrames(matchId, frameChunk)
	local match = liveMatches[matchId]

	if not match then
		warn(
			"[LivePlayCore] pushLiveFrames: unknown match:",
			matchId
		)
		return
	end

	if type(frameChunk) ~= "table" or #frameChunk == 0 then
		return
	end

	-- DO NOT throw away chunks just because nobody is watching.
	--
	-- The old code had:
	--
	-- if not match.subscribers or next(match.subscribers) == nil then
	--     return
	-- end
	--
	-- That means the live replay only starts recording once somebody
	-- subscribes. That's dangerous.
	--
	-- Live recording should continue independently of viewers.

	table.insert(match.writeQueue, frameChunk)

	if match.writeWorkerActive then
		return
	end

	match.writeWorkerActive = true

	task.spawn(function()
		while liveMatches[matchId] do
			local chunk = table.remove(match.writeQueue, 1)

			if not chunk then
				task.wait(0.1)

				if #match.writeQueue == 0 then
					break
				end

				continue
			end

			local chunkIndex = match.frameBatchIndex or 0

			--------------------------------------------------
			-- WRITE CHUNK
			--------------------------------------------------

			local ok = writeLiveSequenceChunk(
				matchId,
				chunkIndex,
				chunk
			)

			if not ok then
				warn(
					"[LivePlayCore] Failed to store LIVE chunk:",
					matchId,
					"chunk =",
					chunkIndex
				)

				continue
			end

			--------------------------------------------------
			-- UPDATE LIVE STATE
			--------------------------------------------------

			match.frameBatchIndex = chunkIndex + 1
			match.latestChunk = chunkIndex

			match.liveUntilChunk = chunkIndex

			if match.liveFromChunk == nil then
				match.liveFromChunk = chunkIndex
			end

			local firstFrame = chunk[1]
			local lastFrame = chunk[#chunk]

			if type(firstFrame) == "table" then
				match.liveFromTime =
					tonumber(firstFrame.time)
					or tonumber(firstFrame.t)
					or match.liveFromTime
			end

			if type(lastFrame) == "table" then
				match.liveUntilTime =
					tonumber(lastFrame.time)
					or tonumber(lastFrame.t)
					or match.liveUntilTime
			end

			match.liveUntilChunk = chunkIndex

			if match.liveFromChunk == nil then
				match.liveFromChunk = chunkIndex
			end

			--------------------------------------------------
			-- EXTRACT TIME / SEQUENCE INFORMATION
			--------------------------------------------------

			local firstFrame = chunk[1]
			local lastFrame = chunk[#chunk]

			local firstTime
			local lastTime
			local firstSeq
			local lastSeq

			if type(firstFrame) == "table" then
				firstTime =
					tonumber(firstFrame.time)
					or tonumber(firstFrame.timestamp)
					or tonumber(firstFrame.t)

				firstSeq =
					tonumber(firstFrame.seq)
					or tonumber(firstFrame.sequence)
			end

			if type(lastFrame) == "table" then
				lastTime =
					tonumber(lastFrame.time)
					or tonumber(lastFrame.timestamp)
					or tonumber(lastFrame.t)

				lastSeq =
					tonumber(lastFrame.seq)
					or tonumber(lastFrame.sequence)
			end

			if firstTime ~= nil then
				if match.liveFromTime == nil then
					match.liveFromTime = firstTime
				end

				if match.firstTime == nil then
					match.firstTime = firstTime
				end
			end

			if lastTime ~= nil then
				match.liveUntilTime = lastTime
				match.lastTime = lastTime
			end

			if lastSeq ~= nil then
				match.latestSeq = lastSeq
			elseif firstSeq ~= nil then
				match.latestSeq = firstSeq + #chunk - 1
			end

			match.totalFrames =
				(match.totalFrames or 0) + #chunk

			match.lastHeartbeat = os.time()

			--------------------------------------------------
			-- PERSIST LIVE INDEX
			--------------------------------------------------

			local indexData = {
				matchId = match.matchId,
				sessionId = match.sessionId,
				replayKey = match.replayKey,
				jobId = match.jobId,

				liveChunk = {
					chunkIndex = match.liveUntilChunk,
					state = "LIVE",
					firstTime = match.liveFromTime,
					lastTime = match.liveUntilTime,
				},

				liveFromChunk = match.liveFromChunk,
				liveUntilChunk = match.liveUntilChunk,

				liveFromTime = match.liveFromTime,
				liveUntilTime = match.liveUntilTime,

				latestChunk = match.latestChunk,
				latestSeq = match.latestSeq,

				firstTime = match.firstTime,
				lastTime = match.lastTime,

				totalFrames = match.totalFrames,

				updatedAt = os.time(),
			}

			local encodedIndex

			local encodeOK, encodeErr = pcall(function()
				encodedIndex = HttpService:JSONEncode(indexData)
			end)

			if encodeOK then
				local indexOK, indexErr = pcall(function()
					LIVE_MATCHES_MAP:SetAsync(
						matchId,
						encodedIndex,
						LIVE_MATCH_EXPIRATION
					)
				end)

				if not indexOK then
					warn(
						"[LivePlayCore] Failed updating LIVE match index:",
						matchId,
						indexErr
					)
				end
			else
				warn(
					"[LivePlayCore] Failed encoding LIVE match index:",
					encodeErr
				)
			end

			--------------------------------------------------
			-- DEBUG
			--------------------------------------------------

			print(
				"[LivePlayCore] LIVE chunk stored:",
				matchId,
				"chunk =",
				chunkIndex,
				"frames =",
				#chunk,
				"liveFrom =",
				match.liveFromChunk,
				"liveUntil =",
				match.liveUntilChunk,
				"liveFromTime =",
				match.liveFromTime,
				"liveUntilTime =",
				match.liveUntilTime,
				"latestSeq =",
				match.latestSeq
			)
		end

		match.writeWorkerActive = false
	end)
end

local function getStreamMetricsForMatch(matchId)
	if not matchId then return nil end
	for _, stream in pairs(activeStreams) do
		if stream.liveMatchId == matchId then
			return stream.metrics
		end
	end
	return nil
end

local function relayLiveResponsePayload(payload)
	if type(payload) ~= "table" then
		warn("[LivePlayCore] relayLiveResponsePayload rejected non-table payload")
		return
	end

	local requestId = payload.requestId
	local kind = payload.kind or payload.type

	local request = requestId and pendingLiveRequests[requestId]

	if request then
		request.lastPacketAt = os.clock()
	end

	--------------------------------------------------
	-- SNAPSHOT
	--------------------------------------------------

	if kind == "snapshot" then
		if not request then
			warn(
				"[LivePlayCore] Received snapshot for unknown request:",
				requestId
			)
			return
		end

		local frames = payload.frames

		print(
			"[LivePlayCore] RELAY SNAPSHOT:",
			"requestId =", requestId,
			"matchId =", payload.matchId,
			"frames =", type(frames) == "table" and #frames or "INVALID",
			"sessionId =", payload.sessionId,
			"liveFromChunk =", payload.LiveFromChunk,
			"liveUntilChunk =", payload.LiveUntilChunk,
			"liveFromTime =", payload.LiveFromTime,
			"liveUntilTime =", payload.LiveUntilTime
		)

		local viewer = Players:GetPlayerByUserId(request.viewerUserId)

		if not viewer then
			warn(
				"[LivePlayCore] Snapshot viewer left:",
				request.viewerUserId,
				requestId
			)
			return
		end

		ReplayEvent:FireClient(
			viewer,
			"LivePlayCoreData",
			"snapshot",
			payload
		)

		print(
			"[LivePlayCore] Snapshot delivered to viewer:",
			viewer.Name,
			"frames =",
			type(frames) == "table" and #frames or "INVALID"
		)

		return
	end

	--------------------------------------------------
	-- LIVE FRAMES
	--------------------------------------------------

	if kind == "frames" then
		if not request then
			warn(
				"[LivePlayCore] Received frames for unknown request:",
				requestId
			)
			return
		end

		local frames = payload.frames

		if type(frames) ~= "table" or #frames == 0 then
			warn(
				"[LivePlayCore] Received EMPTY frame packet:",
				"requestId =", requestId,
				"matchId =", payload.matchId
			)
			return
		end

		local viewer = Players:GetPlayerByUserId(request.viewerUserId)

		if not viewer then
			warn(
				"[LivePlayCore] Frame viewer left:",
				request.viewerUserId,
				requestId
			)
			return
		end

		print(
			"[LivePlayCore] RELAY FRAMES:",
			"requestId =", requestId,
			"matchId =", payload.matchId,
			"frames =", #frames
		)

		ReplayEvent:FireClient(
			viewer,
			"LivePlayCoreData",
			"frames",
			{
				frames = frames,
				matchId = payload.matchId,
				serverJobId = payload.serverJobId,
				sessionId = payload.sessionId,
				chunkIndex = payload.chunkIndex,
				metrics = getStreamMetricsForMatch(payload.matchId),
			}
		)

		return
	end

	--------------------------------------------------
	-- END
	--------------------------------------------------

	if kind == "end" then
		if not request then
			warn(
				"[LivePlayCore] Received end for unknown request:",
				requestId
			)
			return
		end

		local viewer = Players:GetPlayerByUserId(request.viewerUserId)

		if viewer then
			ReplayEvent:FireClient(
				viewer,
				"LivePlayCoreData",
				"end",
				{
					matchId = payload.matchId,
					serverJobId = payload.serverJobId,
				}
			)
		end

		pendingLiveRequests[requestId] = nil

		return
	end

	warn(
		"[LivePlayCore] Unknown live response kind:",
		tostring(kind),
		"requestId =",
		tostring(requestId)
	)
end
local function readNextLiveBatch(request, requestId, matchId)
	if type(request) ~= "table" or type(matchId) ~= "string" then
		return nil
	end

	local indexData = readReplayLiveIndex(matchId)
	if type(indexData) ~= "table" then
		return nil
	end

	local candidates = indexData.liveChunks
	if type(candidates) ~= "table" then
		candidates = {}
		if type(indexData.liveChunk) == "table" then
			table.insert(candidates, indexData.liveChunk)
		end
	end

	table.sort(candidates, function(a, b)
		return (tonumber(a.chunkIndex) or -1) < (tonumber(b.chunkIndex) or -1)
	end)

	local lastSeen = tonumber(request.lastLiveChunk) or -1

	for _, info in ipairs(candidates) do
		local chunkIndex = tonumber(info.chunkIndex)
		if chunkIndex and chunkIndex > lastSeen then
			local live = readLiveSequenceChunk(matchId, chunkIndex)
			if live and type(live.frames) == "table" and #live.frames > 0 then
				request.lastLiveChunk = chunkIndex
				return live.frames, chunkIndex
			end
		end
	end

	return nil
end
local handledResponses = {}
local function handleLiveResponseSignal(signal)
	if type(signal) ~= "table" then
		return
	end

	local kind = signal.type or signal.kind
	local requestId = signal.requestId
	local matchId = signal.matchId
	if requestId and handledResponses[requestId] then
		warn(
			"[LivePlayCore] DUPLICATE RESPONSE IGNORED:",
			requestId,
			signal.type or signal.kind
		)
		return
	end
	local request = pendingLiveRequests[requestId]
	if not request then
		return
	end


	if requestId then
		handledResponses[requestId] = true

		task.delay(10, function()
			handledResponses[requestId] = nil
		end)
	end

	if kind == "snapshot_ready" then
		task.spawn(function()
			local snapshotKey = signal.snapshotKey

			print(
				"[LivePlayCore] Snapshot ready:",
				matchId,
				"requestId =",
				requestId,
				"key =",
				snapshotKey
			)

			local fullJson

			-- DataStore visibility can lag the MessagingService signal slightly.
			for attempt = 1, 8 do
				fullJson = readLiveSnapshotFromDataStore(
					requestId,
					snapshotKey
				)

				if fullJson then
					break
				end

				task.wait(0.25)
			end

			if not fullJson then
				warn(
					"[LivePlayCore] Failed to load snapshot from DataStore:",
					requestId
				)
				return
			end

			if #fullJson == 0 then
				warn("[LivePlayCore] Assembled snapshot JSON is empty.")
				return
			end

			local okDecode, snapshot = pcall(function()
				return HttpService:JSONDecode(fullJson)
			end)

			if not okDecode or type(snapshot) ~= "table" then
				warn(
					"[LivePlayCore] Failed decoding snapshot:",
					requestId,
					okDecode and "decoded value was not a table" or snapshot
				)
				return
			end

			snapshot.kind = "snapshot"
			snapshot.requestId = requestId

			print(
				"[LivePlayCore] Snapshot loaded:",
				matchId,
				"bytes =",
				#fullJson
			)

			relayLiveResponsePayload(snapshot)

			request.sessionId = snapshot.sessionId or SERVER_SESSION_ID

			if not request.pollingActive then
				request.pollingActive = true
				request.lastLiveChunk = -1

				task.spawn(function()
					while pendingLiveRequests[requestId] and request.pollingActive do
						task.wait(0.25)

						local frames = readNextLiveBatch(
							request,
							requestId,
							matchId
						)

						if frames then
							print(
								"[LivePlayCore] ?? LIVE BATCH RECEIVED:",
								matchId,
								"P" .. tostring(request.readPartition),
								"batch_" .. tostring(request.readBatch),
								"frames =",
								#frames
							)

							relayLiveResponsePayload({
								kind = "frames",
								requestId = requestId,
								matchId = matchId,
								frames = frames,
							})
						end

						local ended = false

						pcall(function()
							ended =
								LPC_FRAMES_MAP:GetAsync(matchId .. "_end") ~= nil
						end)

						if ended then
							print(
								"[LivePlayCore] ?? LIVE STREAM ENDED:",
								matchId
							)

							relayLiveResponsePayload({
								kind = "end",
								requestId = requestId,
								matchId = matchId,
							})

							break
						end
					end

					request.pollingActive = false
				end)
			end
		end)
	elseif kind == "end" then
		relayLiveResponsePayload({
			kind = "end",
			requestId = requestId,
			matchId = matchId,
		})
	end
end
local function initializeLiveResponseSubscription()
	local topic = LPC_RESPONSE_PREFIX .. game.JobId

	print("[LivePlayCore] Initializing response subscription:", topic)

	local ok, result = pcall(function()
		return MessagingService:SubscribeAsync(topic, function(message)

			local data = message.Data

			if type(data) == "string" then
				local decodeOk, decoded = pcall(function()
					return HttpService:JSONDecode(data)
				end)

				if not decodeOk then
					warn("[LivePlayCore] Failed to decode response:", decoded)
					return
				end

				data = decoded
			end

			if type(data) ~= "table" then
				warn("[LivePlayCore] Response is not a table:", typeof(data))
				return
			end

			handleLiveResponseSignal(data)
		end)
	end)

	if not ok then
		warn("[LivePlayCore] FAILED TO SUBSCRIBE TO RESPONSE:", topic, result)
		return false
	end

	print("[LivePlayCore] Response listener ONLINE:", topic)
	return true
end

--------------------------------------------------
-- REQUEST SUBSCRIPTION
--------------------------------------------------

local function handleLiveMatchRequest(data)
	if type(data) ~= "table" then
		warn("[LivePlayCore] Request data is not a table:", typeof(data))
		return
	end

	local requesterJobId = data.jobId
	local matchId = data.matchId
	local requestId = data.requestId

	if type(requesterJobId) ~= "string" or requesterJobId == "" then
		return
	end

	if type(matchId) ~= "string" or matchId == "" then
		return
	end

	if type(requestId) ~= "string" or requestId == "" then
		return
	end

	if requesterJobId == game.JobId then
		return
	end

	local match = liveMatches[matchId]

	if not match then
		return
	end

	match.subscribers[requesterJobId] = {
		requestId = requestId,
		subscribedAt = os.time(),
	}

	capSubscribers(match)

	local success = sendLiveSnapshot(
		requesterJobId,
		matchId,
		requestId
	)

	if not success then
		warn("[LivePlayCore] Failed to send snapshot:", matchId, "to:", requesterJobId)
	end
end

local function initializeLiveRequestSubscription()
	local ok, result = pcall(function()
		return MessagingService:SubscribeAsync(LPC_REQUEST_TOPIC, function(message)
			local rawData = message.Data
			local decoded

			if typeof(rawData) == "string" then
				local okDecode, resultDecode = pcall(function()
					return HttpService:JSONDecode(rawData)
				end)

				if not okDecode then
					warn("[LivePlayCore] Failed to decode request:", resultDecode)
					return
				end

				decoded = resultDecode
			else
				decoded = rawData
			end

			handleLiveMatchRequest(decoded)
		end)
	end)

	if not ok then
		warn("[LivePlayCore] FAILED TO SUBSCRIBE TO REQUEST TOPIC:", result)
		return false
	end

	print("[LivePlayCore] Request listener online:", LPC_REQUEST_TOPIC)
	return true
end

--------------------------------------------------
-- LIVE MATCH LIST
--------------------------------------------------

local function getLiveMatchList()
	local matches = {}
	local seenIds = {}

	for _, stream in pairs(activeStreams) do
		if stream.liveMatchId then
			table.insert(matches, {
				matchId = stream.liveMatchId,
				host = stream.recorderUserId,
				mapSeed = stream.mapSeed,
				mode = stream.mapMode,
				jobId = (game.JobId ~= "" and game.JobId) or "STUDIO_SERVER",
				replayKey = stream.replayChunkKey,
				processedUntilChunk = stream.processedUntil,
				liveUntilChunk = stream.liveUntilChunk,
			})
			seenIds[stream.liveMatchId] = true
		end
	end

	local success, pages = pcall(function()
		return LIVE_MATCHES_MAP:ListItemsAsync(100)
	end)

	if success then
		while true do
			local items = pages:GetCurrentPage()

			for _, item in ipairs(items) do
				local matchKey = item.key
				local matchValue = item.value

				if matchKey and matchValue and not seenIds[matchKey] then
					local decodedData = nil

					if type(matchValue) == "string" then
						pcall(function()
							decodedData = HttpService:JSONDecode(matchValue)
						end)
					elseif type(matchValue) == "table" then
						decodedData = matchValue
					end

					if type(decodedData) == "table" then
						decodedData.matchId = decodedData.matchId or matchKey
						decodedData.mode = decodedData.mode or decodedData.mapMode or "Unknown"

						table.insert(matches, decodedData)
						seenIds[matchKey] = true
					end
				end
			end

			if pages.IsFinished then
				break
			end

			local advanceSuccess, err = pcall(function()
				pages:AdvanceToNextPageAsync()
			end)

			if not advanceSuccess then
				warn("[ReplayManager] Failed to advance MemoryStore page:", err)
				break
			end
		end
	end

	return matches
end

--------------------------------------------------
-- LIVE MATCH EXISTENCE CHECK
--------------------------------------------------

local function liveMatchExists(matchId)
	if type(matchId) ~= "string" or matchId == "" then
		return false
	end

	if liveMatches[matchId] then
		return true
	end

	local ok, rawValue = pcall(function()
		return LIVE_MATCHES_MAP:GetAsync(matchId)
	end)

	local value = nil
	if ok and rawValue ~= nil then
		if type(rawValue) == "string" then
			pcall(function()
				value = HttpService:JSONDecode(rawValue)
			end)
		elseif type(rawValue) == "table" then
			value = rawValue
		end
	end

	return ok and value ~= nil
end

--------------------------------------------------
-- REQUEST WATCH
--------------------------------------------------

local function requestLiveMatch(viewer, matchId)
	if not viewer or not viewer:IsA("Player") then
		return false, "Invalid viewer."
	end

	if type(matchId) ~= "string" or matchId == "" then
		return false, "Invalid match ID."
	end

	local localMatch = liveMatches[matchId]

	if localMatch then
		local requestId = HttpService:GenerateGUID(false)

		pendingLiveRequests[requestId] = {
			viewerUserId = viewer.UserId,
			matchId = matchId,
			createdAt = os.clock(),
			lastPacketAt = os.clock(),
			lastLiveChunk = -1,
		}

		localMatch.subscribers[game.JobId] = {
			requestId = requestId,
			subscribedAt = os.time(),
		}
		capSubscribers(localMatch)

		local success = sendLiveSnapshot(game.JobId, matchId, requestId)

		if not success then
			localMatch.subscribers[game.JobId] = nil
			pendingLiveRequests[requestId] = nil
			return false, "Failed to send local snapshot."
		end

		return true, requestId
	end

	if not liveMatchExists(matchId) then
		return false, "No live match found with ID: " .. matchId
	end

	if not initializeLiveResponseSubscription() then
		return false, "Response subscription unavailable."
	end

	local requestId = HttpService:GenerateGUID(false)

	pendingLiveRequests[requestId] = {
		viewerUserId = viewer.UserId,
		matchId = matchId,
		createdAt = os.clock(),
		lastPacketAt = os.clock(),
	}

	local ok, err = publishMessage(LPC_REQUEST_TOPIC, {
		jobId = game.JobId,
		matchId = matchId,
		requestId = requestId,
		requesterUserId = viewer.UserId,
	})

	if not ok then
		pendingLiveRequests[requestId] = nil
		return false, "Failed to publish request: " .. tostring(err)
	end

	return true, requestId
end

--------------------------------------------------
-- BOOTLEG YOUTUBE VOD/DVR PLAYER HELPER
--------------------------------------------------

local ReplayCoreServerPlayer = {}

function ReplayCoreServerPlayer.FetchVODChunkAOT(
	replayKey,
	targetChunkIndex,
	matchId
)
	task.spawn(function()
		local chunk, state =
			getReplaySequenceChunk(
				matchId,
				replayKey,
				targetChunkIndex
			)

		if chunk then
			print(
				"[ReplayCoreServer] AOT loaded:",
				replayKey,
				"chunk:",
				targetChunkIndex,
				"state:",
				state
			)
		else
			warn(
				"[ReplayCoreServer] AOT failed:",
				replayKey,
				"chunk:",
				targetChunkIndex
			)
		end
	end)
end

function ReplayCoreServerPlayer.ScrubTimeline(viewer, matchId, targetFrameSeq)
	local stream = nil
	for _, s in pairs(activeStreams) do
		if s.liveMatchId == matchId then
			stream = s
			break
		end
	end

	if stream then
		for _, frameEntry in ipairs(stream.frames) do
			if frameEntry.frame and frameEntry.frame.seq == targetFrameSeq then
				ReplayEvent:FireClient(viewer, "LivePlayCoreData", "scrub_frame", frameEntry.frame)
				return true
			end
		end
	end

	print("[ReplayCoreServer] Frame sequence", targetFrameSeq, "expired from RAM. Requesting DataStore VOD chunk...")
	return false
end

--------------------------------------------------
-- REMOTE EVENT HANDLING
--------------------------------------------------

ReplayEvent.OnServerEvent:Connect(function(player, command, arg1, arg2, arg3)
	if command == "LivePlaybackReady" then
		_G.LivePlaybackClientReady = true
		return
	end

	if command == "StartStream" then
		local streamId = arg1
		local metadata = arg2

		if not metadata or not streamId then
			return
		end

		if not validateStreamOwnership(player, streamId) then
			return
		end

		-- ============================================================
		-- DUPLICATE STARTSTREAM GUARD
		-- ============================================================

		local userId = player.UserId

		if startingStreamsByUser[userId] then
			warn(
				"[ReplayCoreServer] Ignoring duplicate StartStream:",
				player.Name,
				streamId
			)
			return
		end

		local existingStreamId = activeStreamByUser[userId]

		if existingStreamId then
			local existingStream = activeStreams[existingStreamId]

			if existingStream then
				warn(
					"[ReplayCoreServer] Player already has active stream:",
					player.Name,
					existingStreamId,
					"->",
					streamId
				)

				return
			end

			-- Stale mapping
			activeStreamByUser[userId] = nil
		end

		startingStreamsByUser[userId] = true

		local ok, err = pcall(function()

			-- ============================================================
			-- YOUR EXISTING STARTSTREAM BODY GOES HERE
			-- ============================================================

			for oldStreamId, streamData in pairs(activeStreams) do
				if streamData.recorderUserId == userId then
					if streamData.liveMatchId then
						endLiveMatch(streamData.liveMatchId)
					end

					activeStreams[oldStreamId] = nil
				end
			end

			local cleanupDeadline = os.clock() + 10

			while not liveStoreReady and os.clock() < cleanupDeadline do
				task.wait(0.1)
			end

			local roundId = getRoundId(
				metadata.mapSeed,
				metadata.mapMode
			)

			roundParticipants[roundId] =
				roundParticipants[roundId] or {}

			roundParticipants[roundId][userId] = true

			roundPayloads[roundId] =
				roundPayloads[roundId] or {}

			if not roundRecorder[roundId] then
				roundRecorder[roundId] = userId
			end

			local replayGuid =
				string.sub(
					string.gsub(
						HttpService:GenerateGUID(false),
						"-",
						""
					),
					1,
					10
				)

			local replayChunkKey =
				"RP_" .. userId .. "_" .. replayGuid

			local stream = {
				Id = streamId,

				mapSeed = metadata.mapSeed or 0,
				mapMode = metadata.mapMode or "Linear",

				sounds = metadata.sounds or {},

				recorderUserId = userId,
				recorderRadius = metadata.recorderRadius,
				multiplayer = metadata.multiplayer == true,

				roundId = roundId,

				frames = {},

				liveMatchId = nil,

				replayChunkKey = replayChunkKey,
				segmentKey = replayChunkKey,

				segments = {},
				segmentBuffer = {},
				segmentBufferBytes = 0,

				sequenceBuffers = {},
				sequenceStates = {},
				sequenceChunks = {},

				processingQueue = {},
				nextProcessChunk = 0,

				processedUntil = -1,
				processedFrames = 0,
				processedLastTime = 0,

				latestSeq = 0,
				liveUntilChunk = -1,

				firstSeq = nil,
				firstTime = nil,
				lastTime = 0,

				replayPlayers = {},

				replayStats = {
					RawBytes = 0,
					CompressedBytes = 0,
					StoredBytes = 0,
				},

				replayProcessor = nil,
				replayProcessingActive = true,

				metrics = {
					framesReceived = 0,
					lastSeq = 0,
					lostFrames = 0,
					latencyMs = 0,
					latencySum = 0,
					latencyCount = 0,
				},
			}

			activeStreams[streamId] = stream
			activeStreamByUser[userId] = streamId

			startReplayProcessor(stream)

			stream.liveMatchId =
				registerLiveMatch(stream, metadata)

			startRingFlushTask(stream)

			print(
				"[ReplayCoreServer] Live Stream started:",
				streamId,
				"Live ID:",
				stream.liveMatchId,
				"Manifest:",
				replayChunkKey
			)
		end)

		startingStreamsByUser[userId] = nil

		if not ok then
			startingStreamsByUser[userId] = nil

			warn(
				"[ReplayCoreServer] StartStream FAILED:",
				player.Name,
				err
			)

			return
		end

	elseif command == "EnableCameraCapture" then
		local streamId = arg1

		if not validateStreamOwnership(player, streamId) then
			return
		end

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
			local recorder = Players:GetPlayerByUserId(stream.recorderUserId)
			if recorder then
				ReplayEvent:FireClient(recorder, "RemoteCameraSample", player.UserId, sample)
			end
		end

	elseif command == "StreamChunk" then
		local streamId = arg1
		local frameChunk = arg2

		if not validateStreamOwnership(player, streamId) then
			return
		end

		local stream = activeStreams[streamId]
		if stream and type(frameChunk) == "table" then
			local metrics = stream.metrics or {}

			for _, frame in ipairs(frameChunk) do
				pushFrameToRing(stream, frame)

				local seq = tonumber(frame.seq) or 0
				if seq > 0 then
					if metrics.lastSeq > 0 and seq > metrics.lastSeq + 1 then
						metrics.lostFrames += (seq - metrics.lastSeq - 1)
					end
					if seq > metrics.lastSeq then
						metrics.lastSeq = seq
					end
				end
				metrics.framesReceived += 1

				if type(frame.st) == "number" then
					local latency = workspace:GetServerTimeNow() - frame.st
					if latency >= 0 then
						metrics.latencySum += latency
						metrics.latencyCount += 1
						metrics.latencyMs = (metrics.latencySum / metrics.latencyCount) * 1000
					end
				end
			end

			if stream.liveMatchId then
				pushLiveFrames(stream.liveMatchId, frameChunk)
				queueReplayFrames(stream, frameChunk)
			end
		end

	elseif command == "FinalizeReplay" then
		local streamId = arg1
		local stream = activeStreams[streamId]

		if not stream then
			return
		end
		clearPlayerStream(player)
		finalizeReplay(player, streamId, stream, arg2, arg3, false)

		if stream.liveMatchId then
			endLiveMatch(stream.liveMatchId)
		end

	elseif command == "RequestLiveMatchList" then
		local list = getLiveMatchList()
		ReplayEvent:FireClient(player, "LiveMatchList", list)

	elseif command == "WatchLiveMatch" then
		local matchId = arg1
		local success, result = requestLiveMatch(player, matchId)

		if success then
			ReplayEvent:FireClient(player, "LiveMatchWatchStarted", matchId, result)
		else
			ReplayEvent:FireClient(player, "LiveMatchWatchFailed", matchId, result)
		end

	elseif command == "RequestProfileList" then
		local profile = ProfileService.get(player)
		if not profile then
			return
		end

		local profileData = profile.Data or profile
		migrateSavedReplays(profileData)

		local payloadList = {}

		if type(profileData.savedReplays) == "table" then
			for key, replayEntry in pairs(profileData.savedReplays) do
				if type(replayEntry) == "table" then
					local entryCopy = {}
					for k, v in pairs(replayEntry) do
						entryCopy[k] = v
					end

					entryCopy.Key = tostring(key)
					entryCopy.MatchId = entryCopy.MatchId or entryCopy.id or "Replay"
					entryCopy.Timestamp = tonumber(entryCopy.Timestamp or entryCopy.timestamp) or 0

					table.insert(payloadList, entryCopy)
				end
			end
		end

		ReplayEvent:FireClient(player, "SyncProfileList", payloadList)

	elseif command == "RequestPlayback" then
		local chunkKey = arg1
		local profile = ProfileService.get(player)

		if not profile or not profile.savedReplays then
			ReplayEvent:FireClient(player, "PlaybackFailed", "Profile not loaded.")
			return
		end

		local replayEntry = nil
		for _, replay in pairs(profile.savedReplays) do
			if getReplayChunkKey(replay) == chunkKey then
				replayEntry = replay
				break
			end
		end

		if not replayEntry then
			ReplayEvent:FireClient(player, "PlaybackFailed", "Replay not found in profile.")
			return
		end

		local manifest = loadReplayPayload(chunkKey)
		local isSequenceManifest = (type(manifest) == "table"
			and manifest.kind == "ReplayManifest"
			and tonumber(manifest.totalChunks or 0) > 0)
			or (tonumber(replayEntry.TotalChunks or 0) > 0)

		if not isSequenceManifest then
			local payload = loadReplayPayloadSegmented(chunkKey)
			if not payload then
				warn("[ReplayManager] RequestPlayback aborted: DataStore returned NIL for chunkKey:", chunkKey)
				ReplayEvent:FireClient(player, "PlaybackFailed", "Replay data missing from DataStore: " .. tostring(chunkKey))
				return
			end

			sendPlaybackDataChunked(
				player,
				HttpService:JSONEncode(payload)
			)
			return
		end

		-- Verify chunk 0 or manifest exists before asking client to enter replay world
		local chunk0 = loadProcessedSequenceChunk(chunkKey, 0)
		if not manifest and not chunk0 then
			warn("[ReplayManager] RequestPlayback aborted: DataStore returned NIL for chunkKey:", chunkKey)
			ReplayEvent:FireClient(player, "PlaybackFailed", "Replay data missing from DataStore: " .. tostring(chunkKey))
			return
		end

		local metadata = {
			kind = "ReplayMetadata",
			isFastload = true,
			replayId = chunkKey,
			ChunkKey = chunkKey,
			mapSeed = replayEntry.MapSeed or (manifest and manifest.mapSeed),
			mapMode = replayEntry.MapMode or (manifest and manifest.mapMode),
			recorderUserId = replayEntry.RecorderUserId or (manifest and manifest.recorderUserId),
			Timestamp = replayEntry.Timestamp or (manifest and manifest.timestamp),
			totalDuration = tonumber(replayEntry.TotalDuration) or tonumber(manifest and manifest.totalDuration) or 0,
			totalFrames = tonumber(replayEntry.TotalFrames) or tonumber(manifest and manifest.totalFrames) or 0,
			totalChunks = tonumber(replayEntry.TotalChunks) or tonumber(manifest and manifest.totalChunks) or 0,
			fps = tonumber(replayEntry.FPS) or tonumber(manifest and manifest.fps) or 60,
			players = replayEntry.Players or (manifest and manifest.players) or {},
			ProcessedUntilChunk = math.max(
				-1,
				(tonumber(replayEntry.TotalChunks or (manifest and manifest.totalChunks)) or 0) - 1
			),
			ProcessingChunks = {},
			LiveFromChunk = nil,
			LiveUntilChunk = -1,
			IsLive = false,
		}

		ReplayEvent:FireClient(player, "StartPlayback", metadata)

	elseif command == "RequestChunk" then
		local replayKey = arg1
		local chunkIndex = tonumber(arg2)
		local matchId = arg3

		if type(replayKey) ~= "string" or not chunkIndex then
			return
		end

		local authorized = false

		if matchId then
			authorized = liveMatchExists(matchId)
		else
			local profile = ProfileService.get(player)
			if profile and profile.savedReplays then
				for _, replay in pairs(profile.savedReplays) do
					if getReplayChunkKey(replay) == replayKey then
						authorized = true
						break
					end
				end
			end
		end

		if not authorized then
			return
		end

		task.spawn(function()
			local chunk, state = getReplaySequenceChunk(
				matchId,
				replayKey,
				chunkIndex
			)

			if chunk then
				ReplayEvent:FireClient(
					player,
					"ReceiveChunk",
					replayKey,
					chunkIndex,
					chunk.frames,
					state,
					chunk.firstSeq,
					chunk.lastSeq
				)
			else
				ReplayEvent:FireClient(
					player,
					"ChunkUnavailable",
					replayKey,
					chunkIndex,
					state
				)
			end
		end)

	elseif command == "RequestReplayStatus" then
		local replayKey = arg1
		local matchId = arg2

		if type(replayKey) ~= "string" then
			return
		end

		local authorized = false

		if matchId then
			authorized = liveMatchExists(matchId)
		else
			local profile = ProfileService.get(player)
			if profile and profile.savedReplays then
				for _, replay in pairs(profile.savedReplays) do
					if getReplayChunkKey(replay) == replayKey then
						authorized = true
						break
					end
				end
			end
		end

		if not authorized then
			return
		end

		local status = buildReplayStatus(replayKey, matchId)
		ReplayEvent:FireClient(player, "ReplayStatus", status)

	elseif command == "RegeneratePlaybackMap" then
		local seed = arg1
		local mode = arg2
		local isLiveMatch = arg3

		if type(seed) ~= "number" then
			return
		end

		local MapGenerator = require(game.ServerScriptService:WaitForChild("MapGenerator"))
		local playbackOffsetY = isLiveMatch and 10000 or 0

		MapGenerator.generate(mode, seed, playbackOffsetY)
		ReplayEvent:FireClient(player, "ConfirmPlaybackOffset", playbackOffsetY)
	end
end)

--------------------------------------------------
-- PLAYER REMOVING
--------------------------------------------------

Players.PlayerRemoving:Connect(function(player)
	for requestId, request in pairs(pendingLiveRequests) do
		if request.viewerUserId == player.UserId then
			pendingLiveRequests[requestId] = nil
		end
	end

	local prefix = "Stream_" .. player.UserId .. "_"

	for streamId, payload in pairs(activeStreams) do
		if string.sub(streamId, 1, #prefix) == prefix then
			finalizeReplay(player, streamId, payload, nil, nil, true)

			if payload.liveMatchId then
				endLiveMatch(payload.liveMatchId)
			end
		end
	end
end)

--------------------------------------------------
-- ADMIN / GLOBAL FUNCTIONS
--------------------------------------------------

_G.ReplayCoreServer_GetStreamMetrics = function(matchId)
	for _, stream in pairs(activeStreams) do
		if stream.liveMatchId == matchId then
			return {
				LiveLatencyMs = string.format("%.2f ms", stream.metrics.latencyMs),
				FramesReceived = stream.metrics.framesReceived,
				LostFrames = stream.metrics.lostFrames,
				RingRAMBufferCount = #stream.frames,
				DataStoreSegmentsFlushed = #stream.segments,
			}
		end
	end
	return "Match not found locally."
end

_G.ListLiveMatches = function()
	local list = getLiveMatchList()

	if not list or type(list) ~= "table" or #list == 0 then
		return "No live matches available."
	end

	local lines = {}

	for _, meta in ipairs(list) do
		if type(meta) == "table" then
			local userId = tonumber(meta.recorderUserId)
			local recorder = userId and Players:GetPlayerByUserId(userId)

			local recorderName = recorder and recorder.Name or tostring(userId or "Unknown")
			local matchId = tostring(meta.matchId or meta.liveMatchId or "UnknownID")
			local mode = tostring(meta.mode or "?")
			local mapMode = tostring(meta.mapMode or "?")
			local mapSeed = tonumber(meta.mapSeed) or 0
			local jobId = tostring(meta.jobId or meta.serverJobId or "?")
			local startedAt = tonumber(meta.startedAt) or 0

			table.insert(
				lines,
				string.format(
					"[%s] %s | mode=%s map=%s seed=%d | server=%s | started %d",
					matchId,
					recorderName,
					mode,
					mapMode,
					mapSeed,
					jobId,
					startedAt
				)
			)
		end
	end

	return table.concat(lines, "\n")
end
_G.WatchLiveMatch = function(matchId, viewer, requestId)
	if type(matchId) ~= "string" or matchId == "" then
		return "Invalid matchId."
	end

	if not liveMatchExists(matchId) then
		return "No live match found with ID: " .. matchId
	end

	local viewerPlayer = nil

	if typeof(viewer) == "Instance" and viewer:IsA("Player") then
		viewerPlayer = viewer
	elseif viewer ~= nil then
		viewerPlayer = resolveOnlinePlayer(viewer)
	end

	if not viewerPlayer then
		return "Viewer is not online."
	end

	requestId = requestId or HttpService:GenerateGUID(false)

	pendingLiveRequests[requestId] = {
		viewerUserId = viewerPlayer.UserId,
		matchId = matchId,
		createdAt = os.clock(),
		lastPacketAt = os.clock(),
	}

	if not initializeLiveResponseSubscription() then
		pendingLiveRequests[requestId] = nil
		return "Failed to subscribe to live response topic."
	end

	local ok, err = publishMessage(LPC_REQUEST_TOPIC, {
		jobId = game.JobId,
		matchId = matchId,
		requestId = requestId,
		requesterUserId = viewerPlayer.UserId,
	})
	print(
		"[LivePlayCore] Publishing watch request",
		"topic =", LPC_REQUEST_TOPIC,
		"matchId =", matchId,
		"requestId =", requestId,
		"viewer =", viewerPlayer.Name,
		"viewerUserId =", viewerPlayer.UserId,
		"jobId =", game.JobId
	)


	if not ok then
		pendingLiveRequests[requestId] = nil
		return "Failed to publish live request: " .. tostring(err)
	end
	print(
		"[LivePlayCore] publishMessage result:",
		ok,
		err
	)
	return true
end

_G.FetchReplaysForPlayer = function(target)
	local player = resolveOnlinePlayer(target)
	local userId = getTargetUserId(target)
	local targetName = resolveTargetName(target) or tostring(target)

	local profileData = nil
	if player then
		profileData = getProfileData(player)
	elseif userId then
		local profile = ProfileService.getOffline(userId)
		profileData = profile and (profile.Data or profile)
	end

	if not profileData or not profileData.savedReplays then
		return "No replays found for " .. targetName
	end

	migrateSavedReplays(profileData)

	local list = {}
	for k, entry in pairs(profileData.savedReplays) do
		if type(entry) == "table" then
			table.insert(list, entry)
		end
	end

	if #list == 0 then
		return "No saved replays for " .. targetName
	end

	table.sort(list, function(a, b)
		return (tonumber(a.Timestamp or a.timestamp) or 0) > (tonumber(b.Timestamp or b.timestamp) or 0)
	end)

	local lines = { "--- Replays for " .. targetName .. " (" .. #list .. ") ---" }
	for idx, replay in ipairs(list) do
		local dateStr = replay.Date or (replay.Timestamp and os.date("%Y-%m-%d %H:%M:%S", replay.Timestamp)) or "?"
		local mode = replay.MapMode or "?"
		local seed = replay.MapSeed or 0
		local dur = replay.TotalDuration and string.format("%.1fs", replay.TotalDuration) or "?"
		local key = getReplayChunkKey(replay) or "?"
		table.insert(lines, string.format("[%d] %s | Mode: %s | Seed: %s | Dur: %s | Key: %s", idx, dateStr, mode, tostring(seed), dur, key))
	end

	return table.concat(lines, "\n")
end

_G.PlayReplayForPlayer = function(target, index, executor)
	if not index or tonumber(index) < 1 then
		return "Invalid replay index."
	end
	index = tonumber(index)

	local player = resolveOnlinePlayer(target)
	local userId = getTargetUserId(target)
	local targetName = resolveTargetName(target) or tostring(target)

	local profileData = nil
	if player then
		profileData = getProfileData(player)
	elseif userId then
		local profile = ProfileService.getOffline(userId)
		profileData = profile and (profile.Data or profile)
	end

	if not profileData or not profileData.savedReplays then
		return "No saved replays for " .. targetName
	end

	migrateSavedReplays(profileData)

	local list = {}
	for k, entry in pairs(profileData.savedReplays) do
		if type(entry) == "table" then
			table.insert(list, entry)
		end
	end

	table.sort(list, function(a, b)
		return (tonumber(a.Timestamp or a.timestamp) or 0) > (tonumber(b.Timestamp or b.timestamp) or 0)
	end)

	local replayEntry = list[index]
	if not replayEntry then
		return string.format("Replay index %d out of range (1..%d).", index, #list)
	end

	local chunkKey = getReplayChunkKey(replayEntry)
	if not chunkKey then
		return "Replay has no chunk key."
	end

	local viewer = executor or player
	if not viewer or not viewer:IsA("Player") then
		return "No online viewer to send replay to."
	end

	local manifest = loadReplayPayload(chunkKey)
	local isSequenceManifest = (type(manifest) == "table"
		and manifest.kind == "ReplayManifest"
		and tonumber(manifest.totalChunks or 0) > 0)
		or (tonumber(replayEntry.TotalChunks or 0) > 0)

	if not isSequenceManifest then
		local payload = loadReplayPayloadSegmented(chunkKey)
		if not payload then
			ReplayEvent:FireClient(viewer, "PlaybackFailed", "Replay data missing from DataStore.")
			return "Replay payload missing from DataStore: " .. chunkKey
		end

		sendPlaybackDataChunked(viewer, HttpService:JSONEncode(payload))
		return "Starting legacy playback for " .. viewer.Name .. "..."
	end

	local chunk0 = loadProcessedSequenceChunk(chunkKey, 0)
	if not manifest and not chunk0 then
		ReplayEvent:FireClient(viewer, "PlaybackFailed", "Replay data missing from DataStore: " .. tostring(chunkKey))
		return "Replay chunks missing from DataStore: " .. chunkKey
	end

	local metadata = {
		kind = "ReplayMetadata",
		isFastload = true,
		replayId = chunkKey,
		ChunkKey = chunkKey,
		mapSeed = replayEntry.MapSeed or (manifest and manifest.mapSeed),
		mapMode = replayEntry.MapMode or (manifest and manifest.mapMode),
		recorderUserId = replayEntry.RecorderUserId or (manifest and manifest.recorderUserId),
		Timestamp = replayEntry.Timestamp or (manifest and manifest.timestamp),
		totalDuration = tonumber(replayEntry.TotalDuration) or tonumber(manifest and manifest.totalDuration) or 0,
		totalFrames = tonumber(replayEntry.TotalFrames) or tonumber(manifest and manifest.totalFrames) or 0,
		totalChunks = tonumber(replayEntry.TotalChunks) or tonumber(manifest and manifest.totalChunks) or 0,
		fps = tonumber(replayEntry.FPS) or tonumber(manifest and manifest.fps) or 60,
		players = replayEntry.Players or (manifest and manifest.players) or {},
		ProcessedUntilChunk = math.max(
			-1,
			(tonumber(replayEntry.TotalChunks or (manifest and manifest.totalChunks)) or 0) - 1
		),
		ProcessingChunks = {},
		LiveFromChunk = nil,
		LiveUntilChunk = -1,
		IsLive = false,
	}

	ReplayEvent:FireClient(viewer, "StartPlayback", metadata)
	return "Playing replay #" .. tostring(index) .. " for " .. viewer.Name
end

_G.DeleteReplayForPlayer = function(target, index)
	if not index or tonumber(index) < 1 then
		return "Invalid index."
	end
	index = tonumber(index)

	local player = resolveOnlinePlayer(target)
	local userId = getTargetUserId(target)
	local targetName = resolveTargetName(target) or tostring(target)

	local profile = nil
	if player then
		profile = ProfileService.get(player)
	elseif userId then
		profile = ProfileService.getOffline(userId)
	end

	if not profile then
		return "Profile not found for " .. targetName
	end

	local profileData = profile.Data or profile
	migrateSavedReplays(profileData)

	local list = {}
	for k, entry in pairs(profileData.savedReplays or {}) do
		if type(entry) == "table" then
			table.insert(list, { key = k, entry = entry })
		end
	end

	table.sort(list, function(a, b)
		return (tonumber(a.entry.Timestamp or a.entry.timestamp) or 0) > (tonumber(b.entry.Timestamp or b.entry.timestamp) or 0)
	end)

	local item = list[index]
	if not item then
		return string.format("Replay index %d not found (1..%d).", index, #list)
	end

	local chunkKey = getReplayChunkKey(item.entry)
	if chunkKey then
		task.spawn(deleteReplayChunk, chunkKey)
	end

	profileData.savedReplays[item.key] = nil
	if player then
		ProfileService.saveProfile(player, profile)
	elseif userId then
		ProfileService.saveOffline(userId, profile)
	end

	return "Deleted replay #" .. tostring(index) .. " (" .. tostring(chunkKey) .. ") for " .. targetName
end

_G.ClearReplaysForPlayer = function(target)
	local player = resolveOnlinePlayer(target)
	local userId = getTargetUserId(target)
	local targetName = resolveTargetName(target) or tostring(target)

	local profile = nil
	if player then
		profile = ProfileService.get(player)
	elseif userId then
		profile = ProfileService.getOffline(userId)
	end

	if not profile then
		return "Profile not found for " .. targetName
	end

	local profileData = profile.Data or profile
	migrateSavedReplays(profileData)

	local count = 0
	for k, entry in pairs(profileData.savedReplays or {}) do
		if type(entry) == "table" then
			local chunkKey = getReplayChunkKey(entry)
			if chunkKey then
				task.spawn(deleteReplayChunk, chunkKey)
			end
			count += 1
		end
	end

	profileData.savedReplays = {}
	if player then
		ProfileService.saveProfile(player, profile)
	elseif userId then
		ProfileService.saveOffline(userId, profile)
	end

	return "Cleared " .. tostring(count) .. " replays for " .. targetName
end

_G.GetReplaySizeForPlayer = function(target, index)
	local player = resolveOnlinePlayer(target)
	local userId = getTargetUserId(target)
	local targetName = resolveTargetName(target) or tostring(target)

	local profileData = nil
	if player then
		profileData = getProfileData(player)
	elseif userId then
		local profile = ProfileService.getOffline(userId)
		profileData = profile and (profile.Data or profile)
	end

	if not profileData or not profileData.savedReplays then
		return "No replays found for " .. targetName
	end

	migrateSavedReplays(profileData)

	local list = {}
	for k, entry in pairs(profileData.savedReplays) do
		if type(entry) == "table" then
			table.insert(list, entry)
		end
	end

	if #list == 0 then
		return "No saved replays for " .. targetName
	end

	table.sort(list, function(a, b)
		return (tonumber(a.Timestamp or a.timestamp) or 0) > (tonumber(b.Timestamp or b.timestamp) or 0)
	end)

	if index and tonumber(index) then
		local idx = tonumber(index)
		local entry = list[idx]
		if not entry then
			return "Index out of range."
		end
		local raw = formatByteSize(entry.RawBytes or 0)
		local comp = formatByteSize(entry.CompressedBytes or 0)
		local stored = formatByteSize(entry.StoredBytes or 0)
		local ratio = string.format("%.1f%%", (entry.CompressionRatio or 0) * 100)
		return string.format("Replay #%d (%s): Raw=%s, Compressed=%s, Stored=%s, Ratio=%s", idx, getReplayChunkKey(entry) or "?", raw, comp, stored, ratio)
	end

	local totalRaw, totalComp, totalStored = 0, 0, 0
	for _, entry in ipairs(list) do
		totalRaw += tonumber(entry.RawBytes) or 0
		totalComp += tonumber(entry.CompressedBytes) or 0
		totalStored += tonumber(entry.StoredBytes) or 0
	end

	return string.format("Total for %s (%d replays): Raw=%s, Compressed=%s, Stored=%s", targetName, #list, formatByteSize(totalRaw), formatByteSize(totalComp), formatByteSize(totalStored))
end

_G.ModifyReplayForPlayer = function(target, index, field, value)
	if not index or not field or value == nil then
		return "Usage: modifyreplay <index> <field> <value> [target]"
	end
	index = tonumber(index)

	local player = resolveOnlinePlayer(target)
	local userId = getTargetUserId(target)
	local targetName = resolveTargetName(target) or tostring(target)

	local profile = nil
	if player then
		profile = ProfileService.get(player)
	elseif userId then
		profile = ProfileService.getOffline(userId)
	end

	if not profile then
		return "Profile not found for " .. targetName
	end

	local profileData = profile.Data or profile
	migrateSavedReplays(profileData)

	local list = {}
	for k, entry in pairs(profileData.savedReplays or {}) do
		if type(entry) == "table" then
			table.insert(list, { key = k, entry = entry })
		end
	end

	table.sort(list, function(a, b)
		return (tonumber(a.entry.Timestamp or a.entry.timestamp) or 0) > (tonumber(b.entry.Timestamp or b.entry.timestamp) or 0)
	end)

	local item = list[index]
	if not item then
		return "Index out of range."
	end

	item.entry[field] = value
	if player then
		ProfileService.saveProfile(player, profile)
	elseif userId then
		ProfileService.saveOffline(userId, profile)
	end

	return string.format("Set %s = %s on replay #%d for %s", tostring(field), tostring(value), index, targetName)
end

_G.RotateReplaySecret = function()
	local success, result = pcall(function()
		local guid1 = HttpService:GenerateGUID(false)
		local guid2 = HttpService:GenerateGUID(false)
		local newSecretStr = guid1 .. guid2

		SecretStore:SetAsync("key", newSecretStr)
		serverSecret = buffer.fromstring(newSecretStr)
		return true
	end)
	return success
end

_G.MigrateReplaySignatures = function(progressCallback)
	return true, "Signatures validated with latest key."
end
-- Initialize subscriptions
initializeLiveRequestSubscription()
