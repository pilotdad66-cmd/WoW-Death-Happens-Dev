-- DH-Tools: BuildStamp.lua
-- Build time (Unix seconds) of THIS copy of the addon. 0 in the source tree.
-- claude\build-test-zip.ps1 and claude\build-release-zip.ps1 overwrite the
-- number in the STAGED copy only (via claude\stamp-build.ps1), so every zip
-- carries the moment it was built and the source file never changes.
--
-- Why it exists (2026-11-02, Loopi): the guild-chat lookup bids newest-build-
-- wins (Core.lua, "NEWEST BUILD WINS"). The .toc Version deliberately does
-- not change between test builds, so the version alone can't order two test
-- builds or a test build against its release; this stamp breaks that tie
-- without anyone maintaining a number by hand. Read at bid time, so the
-- load order against Core.lua doesn't matter.
DHTools = DHTools or {}
DHTools.BUILD_STAMP = 0
