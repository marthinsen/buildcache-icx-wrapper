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

local function make_preprocessor_cmd (args, preprocessed_file)
  local preprocess_args = {}

  local has_debug_symbols = false;

  -- Drop arguments that we do not want/need.
  for i, arg in ipairs(args) do
    local drop_this_arg = false
    if arg_equals(arg, "c") or arg_starts_with(arg, "Fo") then
      drop_this_arg = true
    elseif arg_equals(arg, "Z7") then
      has_debug_symbols = true
    end
    if not drop_this_arg then
      table.insert(preprocess_args, arg)
    end
  end

  -- Append the required arguments for producing preprocessed output.
  if has_debug_symbols then
    table.insert(preprocess_args, "/EP")
  else
    table.insert(preprocess_args, "/P")
  end

  return preprocess_args
end

local function is_source_file (path)
  local ext = bcache.get_extension(path):lower()
  return (ext == ".cpp") or (ext == ".cc") or (ext == ".cxx") or (ext == ".c")
end

local function is_table_empty(tbl)
  return next(tbl) == nil
end

-------------------------------------------------------------------------------
-- Wrapper interface implementation.
-------------------------------------------------------------------------------

function get_capabilities ()
  -- We can use hard links with GCC since it will never overwrite already
  -- existing files.
  return { "hard_links" }
end

function get_build_files ()
  local files = {}
  for i = 2, #ARGS do
    if (arg_starts_with(ARGS[i], "Fo")) then
      if not is_table_empty(files) then
        error("Only a single target object file can be specified.")
      end
      files["object"] = drop_leading_colon(ARGS[i]:sub(4,-1))
    elseif (arg_starts_with(ARGS[i], "Fd")) then
      -- error("Debug information format 'Program Database (/Zi)' is not supported.")
    end
  end
  if is_table_empty(files) then
    error("Unable to get the target object file.")
  end
  return files
end

function get_program_id ()
  -- Get the version string for the compiler.
  local result = bcache.run({ARGS[1], "--version"})
  if result.return_code ~= 0 then
    error("Unable to get the compiler version information string.")
  end

  return result.std_out
end

function get_relevant_arguments ()
  local filtered_args = {}

  -- The first argument is the compiler binary without the path.
  table.insert(filtered_args, bcache.get_file_part(ARGS[1]))

  -- Note: We always skip the first arg since we have handled it already.
  local skip_next_arg = true
  for i, arg in ipairs(ARGS) do
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

function preprocess_source ()
  -- Check if this is a compilation command that we support.
  local is_object_compilation = false
  local has_object_output = false
  for i, arg in ipairs(ARGS) do
    if arg_equals(arg, "c") then
      is_object_compilation = true
    elseif arg_starts_with(arg, "Fo") then
      has_object_output = true
    elseif arg_equals(arg, "Zi") or arg_equals(arg, "Zi") then
      error("PDB generation is not supported.")
    end
  end
  if (not is_object_compilation) or (not has_object_output) then
    error("Unsupported compilation command.")
  end

  -- Run the preprocessor step.
  local preprocessed_file = os.tmpname()
  local preprocessor_args = make_preprocessor_cmd(ARGS, preprocessed_file)
  local result = bcache.run(preprocessor_args)
  if result.return_code ~= 0 then
    os.remove(preprocessed_file)
    error("Preprocessing command was unsuccessful.")
  end

  m_implicit_input_files = get_include_files(result.std_err)

  return result.std_out
end
