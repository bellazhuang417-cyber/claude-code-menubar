-- claude-menubar:require  (do not remove this marker — install/uninstall use it)
package.path = package.path .. ";" .. os.getenv("HOME") .. "/.hammerspoon/claude-menubar/?.lua"
-- Global (not local) so `hs -c "claudeMenubar.xxx()"` works for debugging.
claudeMenubar = dofile(os.getenv("HOME") .. "/.hammerspoon/claude-menubar/init.lua")
claudeMenubar.start()
-- claude-menubar:end
