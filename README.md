# workyround
``workyround`` is a small script that allows you to send files of any format to your client!

Gmod does not allow sending html/yml/css files and many other files that can be useful for convenient development of addons and scripts. However, it allows to send .txt files, so that files on the server part can leave their extension, but on the client they will get the extension .oldExtension.txt.

> [!IMPORTANT]
> This is something to consider if one of your files depends on another. (example: html file uses css file)

# Table of contents
* [Usage](#usage)
  * [Benefits](#benefits)
* [Installation](#installation)
* [Lua Tips](#tips)

# Usage
> [!TIP]
> Briefly:\ Throw all files into the ``garrysmod/data/worky`` folder, and players on PC will have them

This library creates the ``garrysmod/data/worky`` folder. It is the files in this folder that are distributed to players. When a player logs on to the server, he throws a ``net'' request to the server, which returns a list of files from the ``worky'' folder, the client compares the Checksum of each file, and sends a table of missing files to the server, then the server sends individually to the client all the files that are missing.

If you have changed any of the files on the server, and want the changes sent to the client players, write the command ``worky`` in the server console.

## Benefits:
* Small
* Fast
* Secure``?``
* Easy to use
* Easy to install

# Installation
Via [libloader](https://github.com/autumngmod/libloader)
```bash
lib install autumngmod/workyround@0.1.0
lib enable autumngmod/workyround@0.1.0
```

# Tips
* If you need to know that file is up to date, then use hook ``workyFile``
```lua
local configLoaded = false

hook.Add("workyDownloaded", "", function(fileName, _isDownloaded)
  if (fileName == "mining/config.yml") then
    configLoaded = true
  end
end)
```