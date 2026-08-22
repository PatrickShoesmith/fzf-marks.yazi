-- fzf-marks.lua
--
-- A Yazi plugin that lets you jump to one of your fzf-marks bookmarks.
--
-- fzf-marks (https://github.com/urbainvaes/fzf-marks) keeps a plain-text file
-- of bookmarks, one per line, formatted as:
--
--     label : /absolute/path/to/somewhere
--
-- This plugin reads that same file, hands valid marks to `fzf` for fuzzy
-- filtering, and then asks yazi to `cd` to whatever you picked.
--
-- The plugin also supports:
--   * Ctrl-D inside fzf to delete the highlighted mark.
--   * Colorizing the label and the target differently
--   * A separate "add" entry point (bind it to its own key) that prompts for a
--     label and appends "label : <cwd>" to the marks file.
--
-- Author: T V Raziman
-- Supported by: Claude Sonnet 5, Gemini 3 Pro
-- Date: 2026-08-22

local M = {}

-- ANSI SGR codes used to color the label vs. the target when displayed in fzf
-- (requires --ansi, set in run_fzf below).
-- Match fzf-marks colours
local LABEL_COLOR = "39"  -- default
local TARGET_COLOR = "36" -- cyan

--- Notifications are a bit verbose, so wrap them in a helper
local function notify(msg, level)
  ya.notify({
    title = "fzf-marks", content = msg, timeout = 5, level = level or "info"
  })
end

--- Work out the user's home directory.
--
-- Used both to build the default marks-file path (marks_file, when
-- $FZF_MARKS_FILE isn't set) and to expand a leading "~" in mark targets
-- (expand_home).
local function get_home()
  return os.getenv("HOME") or os.getenv("USERPROFILE") or ""
end

--- Work out where the marks file lives.
--
-- fzf-marks itself respects the $FZF_MARKS_FILE environment variable, and
-- falls back to ~/.fzf-marks when it isn't set. We mirror that exact
-- resolution order so this plugin reads the same file the fzf-marks CLI writes
-- to -- no separate config needed.
---@return string?
local function marks_file()
  local env = os.getenv("FZF_MARKS_FILE")
  if env and env ~= "" then
    return env
  end

  local home = get_home()
  if home == "" then
    notify("Could not determine home directory", "error")
    return nil
  end

  return string.format("%s/.fzf-marks", home)
end

--- Expand a leading "~" to $HOME.
--
-- Users often write bookmarks like "docs : ~/Documents" by hand, or other
-- tools that write the marks file may do the same. Yazi's Url/fs helpers don't
-- do shell-style tilde expansion for us, so we do it ourselves before treating
-- the string as a real path.
---@param path string
---@return string
local function expand_home(path)
  local home = get_home()
  if home ~= "" and (
    path == "~" or path:sub(1, 2) == "~/" or path:sub(1, 2) == "~\\"
  ) then
    return home .. path:sub(2)
  end
  return path
end

--- Return the last path component of `path`, used as the suggested label when
--- adding a mark.
---@param path string
---@return string
local function basename(path)
  return path:match("([^/\\]+)[/\\]*$") or path
end

--- Open `path` in `mode`, notifying with both the path and the OS-provided
--- reason on failure (permissions, missing file, read-only filesystem, etc.)
--- instead of just one or the other. Returns the file handle, or nil (after
--- already notifying) on failure.
---@param path string
---@param mode string
---@return file*?
local function try_open(path, mode)
  local file, err = io.open(path, mode)
  if not file then
    notify(string.format(
      "Could not open marks file %s: %s", path, tostring(err)
    ), "error")
  end
  return file
end

-- cx (Yazi's shared state) is only readable from a sync context, which is why
-- the original fzf.lua reads cx.active.selected through a ya.sync() block
-- rather than directly inside its (async) entry function. We do the same here
-- to get the current directory for the "add mark" flow.
local cwd_state = ya.sync(function()
  return tostring(cx.active.current.cwd)
end)

--- Parse the contents of a marks file into:
--   1. `lines`    -- the raw "label : target" lines, verbatim, used when
--                    rewriting the file after a delete.
--   2. `display`  -- the same lines wrapped in ANSI color codes and prefixed
--                    with a 1-based index + tab, fed to fzf for display.
--   3. `targets`  -- the target paths only, in the same order as `lines`,
--                    used to resolve the selected line back to a path in
--                    O(1) via the index fzf reports (see run_fzf).
--
-- Lines without a colon (blank lines, stray junk, etc.) are silently skipped
-- rather than erroring.
---@param content string
---@return string[], string[], string[]
local function parse_marks(content)
  local lines, display, targets = {}, {}, {}
  for line in content:gmatch("[^\r\n]+") do
    local label, target = line:match("^(.-)%s*:%s*(.+)$")
    if label and target and label ~= "" then
      target = target:gsub("%s+$", "")
      table.insert(lines, line)
      table.insert(targets, target)
      -- Prepend line index for O(1) resolution via fzf delimiter
      table.insert(display, string.format(
        "%d\t\27[%sm%s\27[0m : \27[%sm%s\27[0m",
        #lines, LABEL_COLOR, label, TARGET_COLOR, target
      ))
    end
  end
  return lines, display, targets
end

--- Persist the source lines to the marks file using a temp intermediate
---@param path string
---@param lines string[]
---@return boolean success
local function save_marks(path, lines)
  local tmp_path = path .. ".tmp"
  local out_file = try_open(tmp_path, "w")
  if not out_file then
    return false
  end

  local function handle_error(msg, err)
    os.remove(tmp_path)
    notify(string.format(msg, path, tostring(err)), "error")
    return false
  end

  local ok, err = out_file:write(
    table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
  )
  if not ok then
    out_file:close()
    return handle_error("Could not write marks file %s: %s", err)
  end

  local close_ok, close_err = out_file:close()
  if not close_ok then
    return handle_error("Could not close marks file %s: %s", close_err)
  end

  local rename_ok, rename_err = os.rename(tmp_path, path)
  if not rename_ok then
    return handle_error("Could not replace marks file %s: %s", rename_err)
  end

  return true
end

--- Prompt for a label and append "label : <cwd>" to the marks file.
--
-- Invoked via `M:entry(job)` when `job.args[1] == "add"`
-- bind that to its own key in keymap.toml
local function add_mark()
  local cwd = cwd_state()
  local default_label = basename(cwd)

  local value, event = ya.input({
    title = string.format("Mark as (default: %s):", default_label),
    pos = { "top-center", y = 3, w = 40 },
  })

  -- event: 1 = confirmed, 2 = cancelled, 0 = unknown error.
  if event ~= 1 then return end
  value = (value == nil or value == "") and default_label or value

  local path = marks_file()
  if not path then return end

  local file = try_open(path, "a")
  if not file then return end

  file:write(string.format("%s : %s\n", value, cwd))
  file:close()
  notify(string.format('Added mark "%s"', value))
end

--- Spawn `fzf`, feed it `lines` on stdin, and return whatever `fzf` printed
--- on stdout (the --expect key, then the selected line).
---@param lines string[]
---@return string?, Error?
local function run_fzf(lines)
  local child, spawn_err = Command("fzf")
      :arg("--ansi")
      :arg("--expect=ctrl-d")
      :arg("--delimiter=\t")
      :arg("--with-nth=2..")
      :stdin(Command.PIPED)
      :stdout(Command.PIPED)
      :spawn()

  if not child then
    return nil, Err("Failed to start `fzf`, error: %s", spawn_err)
  end

  for _, line in ipairs(lines) do
    child:write_all(line .. "\n")
  end
  child:flush()

  local output, wait_err = child:wait_with_output()
  if not output then
    return nil, Err("Cannot read `fzf` output, error: %s", wait_err)
  elseif not output.status.success and output.status.code ~= 130 then
    -- Exit code 130 is fzf's normal "user cancelled with Esc/Ctrl-C" code, so
    -- we don't treat that as an error.
    return nil, Err("`fzf` exited with error code %s", output.status.code)
  end
  return output.stdout
end

--- Load and parse the marks file at `path`.
--
-- Returns lines, display, targets on success. On failure (can't open the
-- file, or it has no valid marks), notifies the user itself and returns
-- nothing -- callers just check for a nil first return.
---@param path string
---@return string[]?, string[]?, string[]?
local function load_marks(path)
  local file = try_open(path, "r")
  if not file then
    return nil
  end

  local content = file:read("*a")
  file:close()

  local lines, display, targets = parse_marks(content)
  if #lines == 0 then
    notify("No marks found in " .. path, "warn")
    return nil
  end

  return lines, display, targets
end

--- Run the interactive fzf + Ctrl-D loop.
--
-- Holds a single ui.hide() permit for the whole loop (rather than one per
-- fzf invocation) so Yazi's UI doesn't flash back into view in between
-- redraws -- e.g. deleting several marks in a row stays inside one
-- uninterrupted fzf session.
--
-- `lines`/`display`/`targets` are mutated in place as marks are deleted, and
-- the on-disk file at `path` is rewritten to match after each one. Returns
-- the 1-based index (into `targets`) of the mark the user picked, or nil if
-- they cancelled (Esc/Ctrl-C) or something went wrong along the way.
---@param path string
---@param lines string[]
---@param display string[]
---@param targets string[]
---@return integer?
local function pick_mark(path, lines, display, targets)
  local permit = ui.hide()

  while true do
    local output, run_err = run_fzf(display)
    if not output then
      permit:drop()
      notify(tostring(run_err), "error")
      return nil
    end

    -- With --expect=ctrl-d, fzf's stdout is "<key>\n<line>\n": the key that
    -- ended the session (empty string for a normal Enter, or for Esc/Ctrl-C
    -- with nothing to report), followed by whatever entry was highlighted at
    -- the time (itself "<index>\t<colorized label : target>", or empty if
    -- nothing was highlighted).
    local split_at = output:find("\n") or (#output + 1)
    local key = output:sub(1, split_at - 1)
    local raw_selection = output:sub(split_at + 1):gsub("[\r\n]+$", "")
    local idx = tonumber(raw_selection:match("^(%d+)%s*\t"))

    if key ~= "ctrl-d" then
      -- Normal completion: Enter with something highlighted (idx set), or
      -- Esc/Ctrl-C with nothing selected (idx is nil either way here).
      permit:drop()
      return idx
    end

    -- Ctrl-D with nothing highlighted (e.g. the filter matched nothing) --
    -- idx is nil; just redraw and let the user adjust their query or quit.
    if idx then
      -- Remove index `idx` in O(1) by swapping the last element into its
      -- slot and popping the tail, rather than shifting every later element
      -- down by one. Trade-off worth knowing: this does NOT preserve the
      -- original ordering of the remaining marks in the file -- whatever
      -- was last takes over the deleted slot.
      local last = #lines
      if idx < last then
        lines[idx] = lines[last]
        targets[idx] = targets[last]
        -- Re-stamp only the swapped item's display string with its new index
        display[idx] = display[last]:gsub("^%d+\t", idx .. "\t")
      end

      -- Pop the tail (O(1) removal)
      table.remove(lines)
      table.remove(display)
      table.remove(targets)

      if not save_marks(path, lines) then
        -- The in-memory list is now ahead of what's on disk. Stop here
        -- rather than looping into another fzf session on top of state
        -- that never made it to disk -- otherwise further deletes would
        -- compound on data that silently never got persisted.
        permit:drop()
        return nil
      end

      if #lines == 0 then
        permit:drop()
        notify("No marks left")
        return nil
      end
    end
  end
end

--- Resolve `target` to a Url, confirm it still exists, and ask Yazi to jump
--- there (cd for directories, reveal for files).
---@param target string
local function jump_to(target)
  local url = Url(expand_home(target))

  local cha = fs.cha(url)
  if not cha then
    return notify(string.format("%s no longer exists", tostring(url)), "error")
  end

  ya.emit(cha.is_dir and "cd" or "reveal", { url, raw = true })
end

--- Entry point. Called by Yazi when the plugin is invoked.
--
-- With no args, jumps to a mark. With `job.args[1] == "add"` (bind this to a
-- separate key, see the keymap.toml snippet in the README/chat), prompts for a
-- label and adds the current directory as a new mark instead.
---@param job table?
function M:entry(job)
  if job and job.args and job.args[1] == "add" then
    return add_mark()
  end

  local path = marks_file()
  if not path then return end

  local lines, display, targets = load_marks(path)
  if not lines then
    return
  end

  local idx = pick_mark(path, lines, display, targets)
  if not idx then
    return
  end

  jump_to(targets[idx])
end

return M
