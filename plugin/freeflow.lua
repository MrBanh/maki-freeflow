-- maki-freeflow entry point (default load path).
--
-- The daemon resolves its vendor tree from the package module source or
-- managed checkout metadata. No user-specific custom loader is required.
require("freeflow").setup()
