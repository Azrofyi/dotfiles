return {
  "folke/which-key.nvim",
  event = "VeryLazy",
  opts = {},
  keys = {
    {
      "<leader>q",
      function()
        require("which-key").show()
      end,
      desc = "Show leader key menu",
    },
  },
}
