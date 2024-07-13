local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

local plugins = {
  --Themes
  { "folke/tokyonight.nvim",               name = "tokyonight", },
  -- Interface
  { "nvim-lualine/lualine.nvim",           name = "lualine" },
  { "rcarriga/nvim-notify",                name = "notify" },
  { "gelguy/wilder.nvim",                  name = "wilder" },
  {
    'nvimdev/dashboard-nvim',
    event = 'VimEnter',
    config = function()
      require('dashboard').setup {
        -- config
      }
    end,
    dependencies = { {'nvim-tree/nvim-web-devicons'}}
  },
}

local opts = {}

require("lazy").setup(plugins, opts)
