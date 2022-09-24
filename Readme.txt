
This driver is based upon Rudolph R. Loew's AHCICD driver.
It generally uses unreal-mode to access the memory-mapped device registers, hence it won't run in v86-mode.

Features:
- Sector buffer in extended memory, so a pretty low DOS-memory footprint.
- AHCI tables ( command list, FIS receive buffers, command table ) are
  relocated to extended memory, so it should be possible to move the XBDA.


