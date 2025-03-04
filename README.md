# workyround
``workyround`` is a small script that allows you to send files of any format to your client!

Gmod does not allow sending html/yml/css files and many other files that can be useful for convenient development of addons and scripts. However, it allows to send .txt files, so that files on the server part can leave their extension, but on the client they will get the extension .oldExtension.txt.

> [!IMPORTANT]
> This is something to consider if one of your files depends on another. (example: html file uses css file)

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

## Removing
```bash
lib remove autumngmod/workyround@0.1.0
```

# Tips
* If you need to know that file is up to date, then use hook ``workyFile``
```lua
local configLoaded = false

hook.Add("workyFile", "", function(fileName, _isDownloaded)
  if (fileName == "mining/config.yml") then
    configLoaded = true
  end
end)
```