--
-- small documentation
--
-- console commands:
--  worky: (superadmin only) - updates the list of files (makes it actual) on the server and sends it to all players
--
-- convars:
--   worky_autostart (0/1) - Will the client send a file list request immediately after logging into the server? (timer.Simple(0))
--    worky_maxsize (0-10) - Maximum file size you can send (in Mb)
--
-- net messages:
--  wrky:
--    client -> server: the client requested a list of files
--    server -> client: the server responded to the client with a list of files
--  wrkyr:
--    client -> server: the client sent a list of missing files (actually, a string) to the server
--    server -> client: the server sent one of the requested files to the client
--
-- hooks:
--  workyDownloaded(string path, boolean downloaded) - when file is done
--    either the file has been downloaded or the file checksum matches
--  workyDownloading(string pathing, number segment (0-15), numbers segmentCount (0-15), numbers #bin (bytes written)) - file downloading process

---@diagnostic disable-next-line: lowercase-global
wrky = {}

file.CreateDir("worky")

CreateConVar("worky_autostart", "1", FCVAR_REPLICATED + FCVAR_NOTIFY + FCVAR_ARCHIVE, "Should request files immediately after player spawned?", 0, 1)

if SERVER then
  util.AddNetworkString("wrky") -- worky
  util.AddNetworkString("wrkyr") -- worky read
  util.AddNetworkString("wrkyu") -- worky update

  local maxSize = CreateConVar("worky_maxsize", "5", FCVAR_LUA_SERVER + FCVAR_ARCHIVE + FCVAR_REPLICATED, "Max size per file", 0, 15):GetInt() * 1000 * 1000 -- mb to bytes

  cvars.AddChangeCallback("worky_maxsize", function(_, _, new)
    maxSize = tonumber(new) or 5
  end)

  ---@param baseDir string
  ---@return table<string, number>
  local function getFileList(baseDir)
    local result = {}
    local files, dirs = file.Find(baseDir .. "/*", "DATA")

    for _, filename in ipairs(files) do
      local path = baseDir .. "/" .. filename
      local size = file.Size(path, "DATA")

      if size > maxSize then
        print("[wrky] file \"" .. path .. "\" bigger than " .. (maxSize/1000/1000) .. "Mb (" .. math.Round(size / 1000 / 1000, 1) .. "Mb), skipping it.")
      else
        local content = file.Read(path, "DATA")
        result[path] = util.CRC(content)
      end
    end

    for _, dir in ipairs(dirs) do
      local path = baseDir .. "/" .. dir
      result[path] = 0 -- dir

      for k, v in pairs(getFileList(path)) do
        result[k] = v
      end
    end

    return result
  end

  local function updateFileList()
    local storage = getFileList("worky")
    local storageSmall = {}

    for k, v in pairs(storage) do
      storageSmall[k:sub(7)] = v -- 7 = #"worky/" + 1
    end

    wrky.storage = storageSmall
    wrky.storageSize = table.Count(storageSmall)
    wrky.storageCompressed = {}

    for k, v in pairs(storageSmall) do
      wrky.storageCompressed[util.Compress(k)] = v
    end

    net.Start("wrkyu")
    net.Broadcast()
  end

  updateFileList()

  concommand.Add("worky", function(client)
    if IsValid(client) and not client:IsSuperAdmin() then return end
    updateFileList()
  end)

  -- file list
  net.Receive("wrky", function(_, client)
    net.Start("wrky")
    net.WriteUInt(wrky.storageSize, 10)

    for file, checksum in pairs(wrky.storageCompressed) do
      net.WriteUInt(#file, 8)
      net.WriteData(file)
      net.WriteUInt(checksum, 32)
    end

    net.Send(client)
  end)

  -- send file
  net.Receive("wrkyr", function(_, client)
    local data = net.ReadData(net.ReadUInt(16))
    local files = util.Decompress(data):Split(",")

    for _, relPath in ipairs(files) do
      local path = "worky/" .. relPath
      local size = file.Size(path, "DATA")

      -- [path <1Kb][part 4Bytes][partCount 4Bytes][fileSize in Kb 14Bytes][62Kb/per request: content]
      if (size > 0) then
        local content = file.Read(path, "DATA")
        local segments = math.ceil(size / 62000)

        for i = 1, segments do
          local startByte = (i - 1) * 62000 + 1
          local endByte = math.min(i * 62000, size)
          local segmentData = content:sub(startByte, endByte)

          net.Start("wrkyr")
          net.WriteUInt(i, 4) -- current segment
          net.WriteUInt(segments, 4) -- segment count
          net.WriteFloat(size/1000)
          net.WriteString(relPath)
          net.WriteData(util.Compress(segmentData)) -- payload
          net.Send(client)
        end
      end
    end
  end)

  return -- end of the serverside
end

wrky.isDownloaded = false -- were the files downloaded initially?
---@type string[]
wrky.downloaded = {} -- list of a downloaded files
---@type string[]
wrky.fileList = {}

-- CLIENT --

---@param filelist table<string, number>
---@return string? Binary
local function validate(filelist)
  local requiredFiles = {}

  for k, v in pairs(filelist) do
    local path = "worky/" .. k

    if v == 0 then
      file.CreateDir(path)
    elseif util.CRC(file.Read(path .. ".txt", "DATA") or "") ~= tostring(v) then
      requiredFiles[#requiredFiles+1] = k
    else
      hook.Run("workyDownloaded", k, false)
    end
  end

  if #requiredFiles == 0 then
    wrky.isDownloaded = true

    hook.Run("workyDone")

    return
  end

  return util.Compress(table.concat(requiredFiles, ","))
end

-- file saving
net.Receive("wrkyr", function(len)
  local segment = net.ReadUInt(4) -- current segment
  local segmentCount = net.ReadUInt(4) -- count of segments
  local fileSize = net.ReadFloat() -- size of file in kilobytes | (10mb = 10000kb => we need to send number 10000 at maxmium)
  local virtualPath = net.ReadString() -- path to the file
  local bin = net.ReadData((len - #virtualPath - 4 - 4 - 32) / 8) -- #virtualPath - segment - segmentCount - ReadFloat (4 bytes = 32 bit)

  local path = "worky/" .. virtualPath .. ".txt"
  local content = util.Decompress(bin)

  -- clearing file before write data into it
  if (segment == 1) then
    file.CreateDir(path:GetPathFromFilename())
    file.Delete(path, "DATA")
  end

  -- writing data
  file.Append(path, content)

  --- virtualPath: path to file relative to data/worky
  --- segment current segment
  --- segmentCount summary count of segments
  --- #bin/1000 size of saved segment in Kb
  --- fileSize summary file size in Kb
  hook.Run("workyDownloading", virtualPath, segment, segmentCount, #bin / 1000, math.Round(fileSize, 2))

  if (segment == segmentCount) then
    -- downloaded
    hook.Run("workyDownloaded", virtualPath, true)

    wrky.downloaded[#wrky.downloaded+1] = virtualPath

    if (#wrky.downloaded == #wrky.fileList) then
      wrky.isDownloaded = true

      hook.Run("workyDone")
    end
  end
end)

net.Receive("wrky", function()
  -- wrky.downloaded = {}

  local list = {}
  local size = net.ReadUInt(10)
  if size == 0 then return end

  for _ = 1, size do
    local key = util.Decompress(net.ReadData(net.ReadUInt(8)))
    list[key] = net.ReadUInt(32)
  end

  wrky.fileList = list

  local bin = validate(list)
  if not bin then return end

  net.Start("wrkyr")
  net.WriteUInt(#bin, 16)
  net.WriteData(bin)
  net.SendToServer()
end)

local function getFileList()
  net.Start("wrky")
  net.SendToServer()
end

net.Receive("wrkyu", getFileList)

timer.Simple(0, function()
  local shouldAutoStart = GetConVar("worky_autostart")

  if (shouldAutoStart:GetBool()) then
    getFileList()
  end
end)