---@diagnostic disable-next-line: lowercase-global
worky = worky or {}
worky.dir = "worky/"
worky.logger = worky.logger or logmo:new("workyround")

---@alias FileList {string: string}

local kb = 1000
local mb = kb^2
-- Here is number 3, because of net bandwidth the speed of sending/receiving messages
-- is limited to ``120Kb/s``, so ``6Mb`` will be downloaded in about a minute.
--
-- That's a long time.
--
-- So ``3Mb`` is optimal, one file, for example with size ``2.7Mb`` will be downloaded in about 27s.
--
-- In modern realities this is very long, but our library is not designed to send large files.
local maxFileSize = 3 * mb -- 3mb
local chunkSize = 100 * kb

file.CreateDir(worky.dir)

if (SERVER) then
  ---@type FileList
  worky.fileList = worky.fileList or {}
  ---@type {string: string[]}
  worky.fileListCache = worky.fileListCache or {}
  worky.fileListSize = worky.fileListSize or 0

  CreateConVar("worky_autostart", "1", FCVAR_REPLICATED + FCVAR_NOTIFY + FCVAR_ARCHIVE, "Should request files immediately after player spawned?", 0, 1)
  local caching = CreateConVar("worky_caching", "1", FCVAR_LUA_CLIENT + FCVAR_ARCHIVE, "Should the files from /data/worky/ be saved to the server RAM? (increases RAM consumption, but reduces CPU load)", 0, 1)
  -- client <=> server
  -- Client => Server: Requests for a files in server's data/worky directory ({string: string} -> {path: crc})
  -- Client <= Server: List of files in server's data/worky directory ({string: string} -> {path: crc})
  -- used in ``worky.fetch`` function
  util.AddNetworkString("worky.")

  --- client <=> server
  --- Client <= Server: Sends the file to the client by chunks
  util.AddNetworkString("worky.file")

  --- client <= server
  --- Client <= Server: Notifies the player that a file on the server has been modified
  util.AddNetworkString("worky.update")

  concommand.Add("worky", function(player)
    if (IsValid(player) and not player:IsSuperAdmin()) then
      return
    end

    worky.logger:info("Updating the file list")

    worky.updateFileList()
  end)

  --- Recursively collects a file list from the specified folder
  ---
  ---@private
  ---@param baseDir? string
  ---@return FileList
  function worky.getChecksumsOfFiles(baseDir)
    local result = {}

    local currentDir = worky.dir .. (baseDir or "")

    local files, dirs = file.Find(currentDir .. "*", "DATA")

    for _, v in ipairs(files) do
      local path = currentDir .. v
      local savePath = baseDir .. v

      if (file.Size(path, "DATA") / mb > maxFileSize) then
        worky.logger:warn(("The %s file is larger than 3mb, it will not be sent to players"):format(savePath))

        continue
      end

      local content = file.Read(path, "DATA")

      result[savePath] = util.CRC(content)

      if (caching:GetBool()) then
        worky.fileListCache[savePath] = worky.computeCompressedChunks(content)
      end
    end

    for _, dir in ipairs(dirs) do
      local checksums = worky.getChecksumsOfFiles((baseDir or "") .. dir .. "/")

      for k, v in pairs(checksums) do
        result[k] = v
      end
    end

    return result
  end

  --- Updates the file list, and sends a notification of this to all clients
  function worky.updateFileList()
    worky.fileList = worky.getChecksumsOfFiles()
    worky.fileListSize = table.Count(worky.fileList)

    -- Notify all players on the server that the list has been updated
    net.Start("worky.update")
    net.Broadcast()

    worky.logger:info("File list updated")
  end

  --- Sends a file list to the player
  ---
  ---@param player Player
  function worky.sendFileList(player)
    net.Start("worky.")
    net.WriteUInt(worky.fileListSize, 9)

    for k, v in pairs(worky.fileList) do
      net.WriteString(k)
      net.WriteString(v)
    end

    net.Send(player)
  end

  --- Splits the file into compressed chunks
  ---
  ---@param content string
  ---@return string[]
  function worky.computeCompressedChunks(content)
    local result = {}
    local chunks = math.ceil(#content / chunkSize)

    for chunkIndex = 1, chunks do
      local startByte = (chunkIndex - 1) * chunkSize + 1
      local endByte = math.min(chunkIndex * chunkSize, #content)
      local chunk = content:sub(startByte, endByte)

      -- same as result[#result+1]
      result[chunkIndex] = util.Compress(chunk)
    end

    return result
  end

  --- Returns file's compressed chunks
  ---
  ---@param path string
  ---@return string[] | nil
  function worky.getFileChunks(path)
    local cached = worky.fileListCache[path]

    if (cached) then
      return cached
    end

    path = worky.dir .. path

    if (not file.Exists(path, "DATA")) then
      return
    end

    return worky.computeCompressedChunks(file.Read(path, "DATA"))
  end

  ---@param
  ---@param path string
  ---@param chunkId number Id of a chunk
  ---@param chunks number Summary count of a file's chunks
  ---@param chunk string Compressed content
  ---@param fileSize number
  ---@param player Player
  function worky.sendFileChunk(path, chunkId, chunks, chunk, fileSize, player)
    net.Start("worky.file", true) -- uh uh
    net.WriteString(path)

    -- Chunk number
    net.WriteUInt(chunkId, 8)
    -- Number of chunks into which the file was partitioned
    net.WriteUInt(chunks, 8)
    -- File size in Kb
    net.WriteFloat(fileSize)
    -- Chunk size in Bytes
    net.WriteUInt(#chunk, 16)
    -- Compressed content
    net.WriteData(chunk)

    net.Send(player)
  end

  ---@param path string
  ---@param fileContent string[]
  ---@param fileSize number
  ---@param player Player
  ---@param chunkId? number = 1
  -- ``100Kb/s``
  function worky.sendFile(path, fileContent, fileSize, player, chunkId)
    chunkId = chunkId or 1

    local chunk = fileContent[chunkId]

    if (not chunk) then
      return
    end

    timer.Simple(chunkId == 1 and 0 or 1, function()
      if (not IsValid(player)) then
        return
      end

      worky.sendFileChunk(path, chunkId, #fileContent, chunk, fileSize, player)

      worky.sendFile(path, fileContent, fileSize, player, chunkId + 1)
    end)
  end

  -- Network zone

  net.Receive("worky.", function(_, player)
    worky.sendFileList(player)
  end)

  net.Receive("worky.file", function(_, player)
    local path = net.ReadString()
    local fileContent = worky.getFileChunks(path)

    if (not fileContent) then
      return
    end

    local fileSize = file.Size(worky.dir .. path, "DATA") / kb -- convertation from bytes to kilobytes

    worky.sendFile(path, fileContent, fileSize, player)
  end)

  return
end

worky.downloading = {}
worky.isDownloaded = false

--- Reads FileList from ``net`` message
---
---@private
---@return FileList
function worky.readFileList()
  local result = {}
  local size = net.ReadUInt(9)

  for i=1, size do
    local path = net.ReadString()
    local checksum = net.ReadString()

    result[path] = checksum
  end

  return result
end

--- Requests for a files in server's data/worky directory (string[])
---
--- ``Supports coroutines``
---
--- ## Example
--- ```lua
--- local co = coroutine.create(function()
---   local list = worky.fetch()
---
---   PrintTable(list)
--- end)
---
--- coroutine.resume(co)
--- ```
---
---@param callback? fun(list: FileList)
---@return FileList | nil (if in coroutine)
function worky.fetch(callback)
  net.Start("worky.")
  net.SendToServer()

  local co = coroutine.running()

  if (co or callback) then
    net.Receive("worky.", function()
      local fileList = worky.readFileList()

      if (isfunction(callback)) then
        ---@diagnostic disable-next-line: need-check-nil
        callback(fileList)
      end

      if (co) then
        coroutine.resume(co, fileList)
      end
    end)

    if (co) then
      return coroutine.yield()
    end
  end
end

--- Compares file list from server, and current files in ``/data/worky`` and return mismatches
---
---@private
---@param list FileList
---@return FileList
function worky.compare(list)
  local mismatches = {}

  for path, checksum in pairs(list) do
    local content = file.Read(worky.dir .. path .. ".txt", "DATA")
    local currentChecksum = util.CRC(content or "")

    if (currentChecksum ~= checksum) then
      mismatches[#mismatches+1] = path
    else
      hook.Run("WorkyFileReady", path, false)
    end
  end

  return mismatches
end

--- Converts FileList to an array of strings
---
---@private
---@param list FileList
---@return string[]
function worky.listToArray(list)
  local result = {}

  for _, path in pairs(list) do
    result[#result+1] = path
  end

  return result
end

--- Set actual download list
---
---@private
---@param list string[]
function worky.setDownloadList(list)
  worky.downloading = list or {}
end

--- Removes a file from download list
---
---@param path string
function worky.removeFromDownloadList(path)
  local index

  for ind, _path in ipairs(worky.downloading) do
    if (path == _path) then
      index = ind
    end
  end

  if (index) then
    table.remove(worky.downloading, index)
  end

  if (#worky.downloading == 0) then
    hook.Run("WorkyReady")

    worky.isDownloaded = true
  end
end

--- Requests the specified file from the server
---@param id? number
function worky.download(id)
  net.Start("worky.file")
  net.WriteString(worky.downloading[id or 1])
  net.SendToServer()
end

--- Requests a list of files from the server, checks for inconsistencies and downloads normal files.
function worky.validate()
  if (worky.validator) then
    return
  end

  local co = coroutine.create(function()
    worky.logger:info("Requesting a list of files")

    local list = worky.fetch()

    ---@diagnostic disable-next-line: param-type-mismatch
    local mismatches = worky.compare(list)

    worky.validator = nil

    if (#mismatches == 0) then
      worky.logger:info("All files are up-to-date")
      return
    end

    worky.logger:info(("Downloading %s mismatches files"):format(#mismatches))

    worky.setDownloadList(worky.listToArray(mismatches))

    worky.download()
  end)

  worky.validator = co

  coroutine.resume(co)
end

-- Auto start

timer.Simple(0, function()
  if (GetConVar("worky_autostart"):GetBool()) then
    return worky.validate()
  end

  worky.logger:warn("Validate on start is disabled")
end)

-- Network zone

net.Receive("worky.update", worky.validate)

net.Receive("worky.file", function(len)
  -- Path to current downloadable file
  local path = net.ReadString()
  -- Chunk number
  local chunk = net.ReadUInt(8)
  -- Number of chunks into which the file was partitioned
  local chunks = net.ReadUInt(8)
  -- File size in Kb
  local fileSize = net.ReadFloat()
  -- Chunk size in Bytes
  local chunkSize = net.ReadUInt(16)
  -- Compressed content
  local content = net.ReadData(chunkSize)

  local fullPath = "worky/" .. path .. ".txt"

  if (chunk == 1) then
    file.CreateDir(fullPath:GetPathFromFilename())
    file.Delete(fullPath)
  end

  file.Append(fullPath, util.Decompress(content))

  hook.Run("WorkyDownloading", path, chunkSize/1000, fileSize)

  if (chunk == chunks) then
    worky.removeFromDownloadList(path)

    if (#worky.downloading ~= 0) then
      worky.download()
    end

    hook.Run("WorkyFileReady", path, true)
  end
end)