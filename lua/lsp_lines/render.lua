local M = {}

local HIGHLIGHTS = {
  native = {
    [vim.diagnostic.severity.ERROR] = "DiagnosticVirtualTextError",
    [vim.diagnostic.severity.WARN] = "DiagnosticVirtualTextWarn",
    [vim.diagnostic.severity.INFO] = "DiagnosticVirtualTextInfo",
    [vim.diagnostic.severity.HINT] = "DiagnosticVirtualTextHint",
  },
  coc = {
    [vim.diagnostic.severity.ERROR] = "CocErrorVirtualText",
    [vim.diagnostic.severity.WARN] = "CocWarningVirtualText",
    [vim.diagnostic.severity.INFO] = "CocInfoVirtualText",
    [vim.diagnostic.severity.HINT] = "CocHintVirtualText",
  },
}

-- These don't get copied, do they? We only pass around and compare pointers, right?
local SPACE = "space"
local DIAGNOSTIC = "diagnostic"
local OVERLAP = "overlap"
local BLANK = "blank"

---Returns the distance between two columns in cells.
---
---Some characters (like tabs) take up more than one cell.
---Additionally, inline virtual text can make the distance between two columns larger.
---A diagnostic aligned
---under such characters needs to account for that and add that many spaces to
---its left.
---
---@return integer
local function distance_between_cols(bufnr, lnum, start_col, end_col)
  return vim.api.nvim_buf_call(bufnr, function()
    local s = vim.fn.virtcol({ lnum + 1, start_col })
    local e = vim.fn.virtcol({ lnum + 1, end_col + 1 })
    return e - 1 - s
  end)
end

-- TODO: rename to M._get_virt_lines_chunks
local function render_as_virt_lines(namespace, bufnr, diagnostics, opts, source)
  -- This loop reads line by line, and puts them into stacks with some
  -- extra data, since rendering each line will require understanding what
  -- is beneath it.
  local line_stacks = {}
  local prev_lnum = -1
  local prev_col = 0
  local highlight_groups = HIGHLIGHTS[source or "native"]
  local prefix = opts.virtual_lines.prefix or "■"
  local prefix_resolver = function(diagnostic)
    return { prefix, highlight_groups[diagnostic.severity] }
  end
  if type(prefix) == "function" then
    prefix_resolver = prefix
  end
  for _, diagnostic in ipairs(diagnostics) do
    if line_stacks[diagnostic.lnum] == nil then
      line_stacks[diagnostic.lnum] = {}
    end

    local stack = line_stacks[diagnostic.lnum]

    if diagnostic.lnum ~= prev_lnum then
      table.insert(stack, { SPACE, string.rep(" ", distance_between_cols(bufnr, diagnostic.lnum, 0, diagnostic.col)) })
    elseif diagnostic.col ~= prev_col then
      -- Clarification on the magic numbers below:
      -- +1: indexing starting at 0 in one API but at 1 on the other.
      -- -1: for non-first lines, the previous col is already drawn.
      table.insert(
        stack,
        { SPACE, string.rep(" ", distance_between_cols(bufnr, diagnostic.lnum, prev_col + 1, diagnostic.col) - 1) }
      )
    else
      table.insert(stack, { OVERLAP, diagnostic.severity })
    end

    if diagnostic.message:find("^%s*$") then
      table.insert(stack, { BLANK, diagnostic })
    else
      table.insert(stack, { DIAGNOSTIC, diagnostic })
    end

    prev_lnum = diagnostic.lnum
    prev_col = diagnostic.col
  end

  for lnum, lelements in pairs(line_stacks) do
    local virt_lines = {}

    -- We read in the order opposite to insertion because the last
    -- diagnostic for a real line, is rendered upstairs from the
    -- second-to-last, and so forth from the rest.
    for i = #lelements, 1, -1 do -- last element goes on top
      if lelements[i][1] == DIAGNOSTIC then
        local diagnostic = lelements[i][2]
        local empty_space_hi
        if opts.virtual_lines and opts.virtual_lines.highlight_whole_line == false then
          empty_space_hi = ""
        else
          empty_space_hi = highlight_groups[diagnostic.severity]
        end

        local left = {}
        local overlap = false
        local multi = 0

        -- Iterate the stack for this line to find elements on the left.
        for j = 1, i - 1 do
          local type = lelements[j][1]
          local data = lelements[j][2]
          if type == SPACE then
            if multi == 0 then
              table.insert(left, { data, empty_space_hi })
            else
              table.insert(left, { string.rep("─", data:len()), highlight_groups[diagnostic.severity] })
            end
          elseif type == DIAGNOSTIC then
            -- If an overlap follows this, don't add an extra column.
            if lelements[j + 1][1] ~= OVERLAP then
              table.insert(left, { "│", highlight_groups[data.severity] })
            end
            overlap = false
          elseif type == BLANK then
            if multi == 0 then
              table.insert(left, { "╰", highlight_groups[data.severity] })
            else
              table.insert(left, { "┴", highlight_groups[data.severity] })
            end
            multi = multi + 1
          elseif type == OVERLAP then
            overlap = true
          end
        end

        local center_symbol
        if overlap and multi > 0 then
          center_symbol = "┼"
        elseif overlap then
          center_symbol = "├"
        elseif multi > 0 then
          center_symbol = "┴"
        else
          center_symbol = "╰"
        end
        -- local center_text =
        local center = {
          { string.format("%s%s", center_symbol, "───"), highlight_groups[diagnostic.severity] },
        }
        local resolved_prefix = prefix_resolver(diagnostic)
        local prefix_len = 0
        for _, part in pairs(resolved_prefix) do
          prefix_len = prefix_len + vim.fn.strdisplaywidth(part[1])
        end
        vim.list_extend(center, resolved_prefix)

        -- TODO: We can draw on the left side if and only if:
        -- a. Is the last one stacked this line.
        -- b. Has enough space on the left.
        -- c. Is just one line.
        -- d. Is not an overlap.

        local msg
        if diagnostic.code then
          -- msg = string.format("%s: %s", diagnostic.code, diagnostic.message)
          msg = diagnostic.message
        else
          msg = diagnostic.message
        end
        for msg_line in msg:gmatch("([^\n]+)") do
          local vline = {}
          vim.list_extend(vline, left)
          vim.list_extend(vline, center)
          vim.list_extend(vline, { { msg_line, highlight_groups[diagnostic.severity] } })
          vim.list_extend(
            vline,
            { { string.rep(" ", vim.api.nvim_win_get_width(0)), highlight_groups[diagnostic.severity] } }
          )

          table.insert(virt_lines, vline)

          -- Special-case for continuation lines:
          if overlap then
            center = {
              { "│", highlight_groups[diagnostic.severity] },
              { "     " .. string.rep(" ", prefix_len), empty_space_hi },
            }
          else
            center = { { "      " .. string.rep(" ", prefix_len), empty_space_hi } }
          end
        end
      end
    end

    vim.api.nvim_buf_set_extmark(bufnr, namespace, lnum, 0, { virt_lines = virt_lines })
  end
end

local severities = {
  vim.diagnostic.severity.ERROR,
  vim.diagnostic.severity.WARN,
  vim.diagnostic.severity.INFO,
  vim.diagnostic.severity.HINT,
}

-- TODO: rename to M._get_virt_text_chunks ???
local function render_as_virt_text(namespace, bufnr, diagnostics, opts, source)
  local highlight_groups = HIGHLIGHTS[source or "native"]
  -- FIX: diagnostic spanning across multiple lines can cause problem with virtual texts
  -- FIX: New line in virtual text
  -- FIX: The diagnostics already existing in the file not behaving properly
  -- FIX: Possible issues with inlay hints
  -- FIX: Make configurable highlights for virtual text. Try for virtual lines.
  -- FIX: Work in insert mode
  -- SUGGEST: Group by severity and show independant count in virt text
  -- if opts and opts.virtual_lines and opts.virtual_lines.virtual_text then
  --   opts = opts.virtual_lines.virtual_text
  -- else
  --   opts = {}
  -- end
  opts = opts or {}
  local line_diagnostics = {}
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- group diagnostics by line number and severity
  for _, d in ipairs(diagnostics) do
    if line_diagnostics[d.lnum] == nil then
      line_diagnostics[d.lnum] = {}
    end
    if line_diagnostics[d.lnum][d.severity] == nil then
      line_diagnostics[d.lnum][d.severity] = {}
    end
    local diags = line_diagnostics[d.lnum][d.severity]
    table.insert(diags, d)
  end

  local prefix = opts.prefix or "■"
  local spacing = opts.spacing or 4
  local only_count = opts.only_count or false
  local prefix_resolver = nil
  if type(prefix) == "function" then
    prefix_resolver = prefix
  elseif type(prefix) == "string" then
    prefix_resolver = function(diagnostic, _, _)
      return { prefix, highlight_groups[diagnostic.severity] }
    end
  else
    prefix_resolver = function()
      return prefix
    end
  end

  -- separate out best diagnostic and add just the prefix for remaining diagnostics for a line
  for _, diags in pairs(line_diagnostics) do
    local index = 1
    local best = nil
    local virt_texts = { { string.rep(" ", spacing) } }
    -- local severity_counts = {}
    for _, severity in ipairs(severities) do
      if diags[severity] ~= nil then
        -- severity_counts[severity] = #diags[severity]
        for _, diagnostic in ipairs(diags[severity]) do
          local resolved_prefix = prefix_resolver(diagnostic, index, #diags)
          if best == nil then
            if diagnostic.message:gsub("%s+$", "") ~= "" then
              best = { prefix = resolved_prefix, diagnostic = diagnostic }
            end
          else
            if not only_count then
              table.insert(virt_texts, resolved_prefix)
            end
          end
          index = index + 1
        end
      end
    end

    if best == nil then
      -- For some reason best is nil. This should not happen unless there is an undefined diagnostic severity
      return
    end
    table.insert(virt_texts, best.prefix)
    table.insert(virt_texts, {
      string.format(" %s ", best.diagnostic.message:gsub("\r", ""):gsub("\n", " ")),
      highlight_groups[best.diagnostic.severity],
    })
    if only_count then
      for i = #severities, 1, -1 do
        local severity = severities[i]
        local ds = diags[severity]
        if ds then
          local count = #ds
          if count ~= nil then
            if severity ~= best.diagnostic.severity then
              table.insert(virt_texts, { string.format("[+%d] ", count), highlight_groups[severity] })
            elseif severity == best.diagnostic.severity then
              if count > 1 then
                table.insert(virt_texts, { string.format("[+%d] ", count - 1), highlight_groups[severity] })
              end
            else
            end
          end
        end
      end
    end
    if best.diagnostic.lnum <= line_count then
      vim.api.nvim_buf_set_extmark(
        best.diagnostic.bufnr,
        namespace,
        best.diagnostic.lnum,
        0,
        { virt_text = virt_texts }
      )
    end
  end
end

---@param namespace number
---@param bufnr number
---@param diagnostics table
---@param opts boolean|Opts
---@param source 'native'|'coc'|nil If nil, defaults to 'native'.
---@param render_area 'virt_lines'|'virt_text'|nil If nil, defaults to 'virt_lines'.
---@param clear boolean|nil
function M.show(namespace, bufnr, diagnostics, opts, source, render_area, clear)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  vim.validate({
    namespace = { namespace, "n" },
    bufnr = { bufnr, "n" },
    diagnostics = {
      diagnostics,
      vim.islist or vim.tbl_islist,
      "a list of diagnostics",
    },
    opts = { opts, "t", true },
  })

  table.sort(diagnostics, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    else
      return a.col < b.col
    end
  end)

  if clear == nil then
    clear = true
  end
  if clear then
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
  if #diagnostics == 0 then
    return
  end
  if render_area ~= "virt_text" then
    render_as_virt_lines(namespace, bufnr, diagnostics, opts, source)
  else
    render_as_virt_text(namespace, bufnr, diagnostics, opts, source)
  end
end

---@param namespace number
---@param bufnr number
function M.hide(namespace, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

return M
