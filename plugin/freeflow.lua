-- maki-freeflow entry point (default load path).
--
-- Managed installs via maki.pack.add use the custom loader in the user
-- config instead of this file; the loader calls require("freeflow")
-- .setup({ vendor_dir = package.path .. "/vendor" }). This entry covers
-- hand-installed copies (site/pack/<group>/start/maki-freeflow), which fall
-- back to the in-config vendor location (see daemon.vendor_dir).
require("freeflow").setup()
