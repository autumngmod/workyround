--
-- small documentation
--
-- console commands:
--  worky: (superadmin only) - updates the list of files (makes it actual) on the server and sends it to all players
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
--  workyFile(string path, boolean downloaded) - when file is done
--    either the file has been downloaded or the file checksum matches
--

file.CreateDir("worky")

if SERVER then
  util.AddNetworkString("wrky") -- worky
  util.AddNetworkString("wrkyr") -- worky read
  util.AddNetworkString("wrkyu") -- worky update

  ---@param baseDir string
  ---@return table<string, number>
  local function getFileList(baseDir)
    local result = {}
    local files, dirs = file.Find(baseDir .. "/*", "DATA")

    for _, filename in ipairs(files) do
      local path = baseDir .. "/" .. filename
      local content = file.Read(path, "DATA")

      if #content > 64000 then
        print("file \"" .. path .. "\" bigger than 64Kb, ignore it.")
      else
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
    wrky = wrky or {}

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

  net.Receive("wrkyr", function(_, client)
    local data = net.ReadData(net.ReadUInt(16))
    local files = util.Decompress(data):Split(",")

    for _, relPath in ipairs(files) do
      local path = "worky/" .. relPath
      local content = file.Read(path, "DATA")

      if content then
        net.Start("wrkyr")
        net.WriteString(relPath)
        net.WriteData(util.Compress(content))
        net.Send(client)
      end
    end
  end)

  return -- end of the serverside
end

-- CLIENT --

---@param filelist table<string, number>
---@return string? Binary
local function validate(filelist)
  local requiredFiles = {}

  for k, v in pairs(filelist) do
    local path = "worky/" .. k

    if v == 0 then
      file.CreateDir(path)
    elseif file.Read(path .. ".txt", "DATA") ~= v then
      requiredFiles[#requiredFiles+1] = k
    else
      hook.Run("workyFile", path, false)
    end
  end

  if #requiredFiles == 0 then return end

  return util.Compress(table.concat(requiredFiles, ","))
end

net.Receive("wrkyr", function(len)
  local path = net.ReadString()
  local bin = net.ReadData((len - #path) / 8)

  local content = util.Decompress(bin)

  file.Write("worky/" .. path .. ".txt", content)

  hook.Run("workyFile", path, true)
end)

net.Receive("wrky", function()
  local list = {}
  local size = net.ReadUInt(10)
  if size == 0 then return end

  for _ = 1, size do
    local key = util.Decompress(net.ReadData(net.ReadUInt(8)))
    list[key] = net.ReadUInt(32)
  end

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

getFileList()