-- match(icx.*)

require_std("io")
require_std("os")
require_std("string")
require_std("table")
require_std("bcache")


-------------------------------------------------------------------------------
-- Internal helper functions.
-------------------------------------------------------------------------------

local function drop_leading_colon (str)
  if str:sub(1, 1) == ":" then
    return str:sub(2)
  end
  return str
end

local function change_extension (path, new_ext)
  local ext = bcache.get_extension(path)
  if ext ~= "" then
    return path:sub(1, -(ext:len() + 1)) .. new_ext
  end
  return path .. new_ext
end

local function arg_starts_with (arg, prefix)
  local first_char = arg:sub(1, 1)
  if first_char == "-" or first_char == "/" then
    if arg:sub(2, prefix:len() + 1) == prefix then
      return true
    end
  end
  return false
end

local function arg_equals(arg, command)
  if arg:sub(1,1) == "-" or arg:sub(1,1) == "/" then
    return arg:sub(2, -1) == command
  end
  return false
end

local function is_source_file (path)
  local ext = bcache.get_extension(path):lower()
  return (ext == ".cpp") or (ext == ".cc") or (ext == ".cxx") or (ext == ".c")
end


local function get_pch_file (args)
  -- /Fp takes highest priority.
  for i, arg in ipairs(args) do
    if arg_starts_with(arg, "Fp") then
      return drop_leading_colon(arg:sub(4, -1))
    end
  end

  -- Next, derive the name from the /Yc argument if one was given.
  for i, arg in ipairs(args) do
    if arg_starts_with(arg, "Yc") then
      local yc_arg = drop_leading_colon(arg:sub(4, -1))
      if yc_arg ~= "" then
        return change_extension(yc_arg, ".pch")
      end
    end
  end

  -- Fall back to the source file's base name + ".pch".
  for i, arg in ipairs(args) do
    if is_source_file(arg) then
      return change_extension(bcache.resolve_path(arg), ".pch")
    end
  end

  error("Unable to determine precompiled header output file.")
end

local function make_preprocessor_cmd (args)
  local preprocess_args = {}
  local source_file = nil

  -- Drop arguments that we do not want/need.
  for i, arg in ipairs(args) do
    local drop_this_arg = false
    if is_source_file(arg) then
      if source_file then
        error("Multiple source files specified, only one is allowed.")
      end
      source_file = bcache.resolve_path(arg)
    elseif arg_starts_with(arg, "Fo") or
        arg_starts_with(arg, "Yc") or
        arg_starts_with(arg, "Yu") or
        arg_starts_with(arg, "Fp") then
      drop_this_arg = true
    end
    if not drop_this_arg then
      table.insert(preprocess_args, arg)
    end
  end

  -- Append the required arguments for producing preprocessed output.
  table.insert(preprocess_args, "/EP")

  if source_file == nil then
    error("No source file specified for preprocessing.")
  end

  table.insert(preprocess_args, "/showIncludes") -- For direct mode

  return preprocess_args
end


local function get_include_files(std_err)
  -- Keep the files in the order the compiler reports them, without duplicates,
  -- so that a generated dependency file is deterministic.
  local include_files = {}
  local seen = {}

  local incpath_line = "Note: including file:"

  for line in std_err:gmatch("[^\r\n]+") do
    -- Match lines that look like:
    -- "Note: including file: <path>"
    if line:sub(1, #incpath_line) == incpath_line  then
      local path_string = line:sub(#incpath_line + 1)
      local path_string_trimmed = path_string:match("^%s*(.-)%s*$") -- Trim leading/trailing whitespace
      if not seen[path_string_trimmed] then
        seen[path_string_trimmed] = true
        table.insert(include_files, path_string_trimmed)
      end
    end
  end

  return include_files
end

-- Write a path the way icx writes it in a dependency file: with backslashes
-- (/showIncludes keeps the slashes of the #include) and spaces escaped as "\ ".
local function escape_dep_path (path)
  return (path:gsub("/", "\\"):gsub(" ", "\\ "))
end

-- If the command asks for a dependency file (-QMD/-QMMD with -QMF), return
-- the dependency file, its target and the source file. Otherwise return nil.
local function get_dep_file_request ()
  local create_dep_file = false
  local dep_file, target, object, source
  local i = 2
  while i <= #m_args do
    local arg = m_args[i]
    if arg_equals(arg, "QMD") or arg_equals(arg, "QMMD") then
      create_dep_file = true
    elseif arg_equals(arg, "QMF") and m_args[i + 1] then
      dep_file = m_args[i + 1]
      i = i + 1
    elseif arg_equals(arg, "QMT") and m_args[i + 1] then
      target = m_args[i + 1]
      i = i + 1
    elseif arg_starts_with(arg, "Fo") then
      object = drop_leading_colon(arg:sub(4, -1))
    elseif is_source_file(arg) then
      source = arg
    end
    i = i + 1
  end
  if not create_dep_file or not dep_file or not source then
    return nil
  end
  return dep_file, target or object, source
end

-------------------------------------------------------------------------------
-- Wrapper interface implementation.
-------------------------------------------------------------------------------

function get_capabilities ()
  -- We can use hard links with GCC since it will never overwrite already
  -- existing files.
  return {"direct_mode", "hard_links"}
end

function get_build_files ()
  local files = {}
  for i = 2, #m_args do
    if (arg_starts_with(m_args[i], "Fo")) then
      if files["object"] then
        error("Only a single target object file can be specified.")
      end
      files["object"] = drop_leading_colon(m_args[i]:sub(4,-1))
    elseif (arg_starts_with(m_args[i], "Yc")) then
      files["pch"] = get_pch_file(m_args)
    end
    -- Note: The -QMF dependency file is not cached. It holds absolute paths
    -- that may belong to another checkout, so finalize_after_hit() writes it.
  end
  if not files["object"] then
    error("Unable to get the target object file.")
  end
  return files
end

function get_program_id ()
  -- Get the version string for the compiler.
  local result = bcache.run({m_args[1], "--version"})
  if result.return_code ~= 0 then
    error("Unable to get the compiler version information string.")
  end

  return result.std_out
end

function get_relevant_arguments ()
  local filtered_args = {}

  -- The first argument is the compiler binary without the path.
  table.insert(filtered_args, bcache.get_file_part(m_args[1]))

  -- Note: We always skip the first arg since we have handled it already.
  local skip_next_arg = true
  for i, arg in ipairs(m_args) do
    if not skip_next_arg then
      -- Does this argument specify a file (we don't want to hash those).
      local is_arg_plus_file_name = (arg == "-QMF") or (arg == "-QMT")

      local is_unwanted_arg = arg_starts_with(arg, "Fo") or
                              arg_starts_with(arg, "Fd") or
                              arg_starts_with(arg, "I") or
                              arg_starts_with(arg, "external:I") or
                              is_source_file(arg)

      if is_arg_plus_file_name then
        skip_next_arg = true
      elseif not is_unwanted_arg then
        table.insert(filtered_args, arg)
      end
    else
      skip_next_arg = false
    end
  end

  bcache.log_debug("Filtered arguments: " .. table.concat(filtered_args, " "))

  return filtered_args
end

function get_input_files ()
  local input_files = {}

  -- Iterate through the arguments and collect source files.
  for i, arg in ipairs(m_args) do
    if is_source_file(arg) then
      local resolved_path = bcache.resolve_path(arg)
      table.insert(input_files, resolved_path)
    end
  end

  bcache.log_debug("Input files: " .. table.concat(input_files, ", "))

  return input_files
end


function preprocess_source ()
  -- Check if this is a compilation command that we support.
  local is_object_compilation = false
  local has_object_output = false
  for i, arg in ipairs(m_args) do
    if arg_equals(arg, "c") then
      is_object_compilation = true
    elseif arg_starts_with(arg, "Fo") then
      has_object_output = true
    elseif arg_equals(arg, "ZI") or arg_equals(arg, "Zi") then
      error("PDB generation is not supported.")
    end
  end
  if (not is_object_compilation) or (not has_object_output) then
    error("Unsupported compilation command.")
  end

  -- Run the preprocessor step.
  local preprocessor_args = make_preprocessor_cmd(m_args)
  local result = bcache.run(preprocessor_args)
  if result.return_code ~= 0 then
    error("Preprocessing command was unsuccessful.")
  end

  m_implicit_input_files = get_include_files(result.std_err)

  return result.std_out
end

function get_implicit_input_files ()
  return m_implicit_input_files
end

function finalize_after_hit ()
  -- On a cache miss, icx writes the -QMF dependency file itself. On a hit, write
  -- it here from the include files of this compilation, so that it lists the
  -- headers of this checkout. buildcache sets m_implicit_input_files from the
  -- direct mode entry (whose key includes the full paths) or from preprocessing.
  local dep_file, target, source = get_dep_file_request()
  if not dep_file then
    return
  end

  local lines = {escape_dep_path(target) .. ":", "  " .. escape_dep_path(source)}
  for _, include_file in ipairs(m_implicit_input_files or {}) do
    table.insert(lines, "  " .. escape_dep_path(include_file))
  end

  local file = io.open(dep_file, "w")
  if not file then
    error("Unable to write the dependency file " .. dep_file)
  end
  file:write(table.concat(lines, " \\\n") .. "\n")
  file:close()
end