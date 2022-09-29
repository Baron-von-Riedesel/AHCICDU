
 1. About
 
 AHCICDU is a DOS CD/DVD optical disk driver based on Rudolph R. Loew's
 AHCICD driver.


 2. Installation

 AHCICDU.SYS has to be added to CONFIG.SYS:
 
   DEVICE=AHCICDU.SYS /D:name [/Q] [/C:controller]

 The /D option is - as in all optical disk drivers - required to set the
 "device" name.
 With option /Q no banner is displayed.
 Option /C might be used to select the AHCI controller to scan for ATAPI
 devices. The default is the first, which would be /C:0.


 3. Features
 
 - Sector buffer in extended memory, so a pretty low DOS-memory footprint (1 kB).
 - AHCI tables ( command list, FIS receive buffers, command table ) are
   relocated to extended memory, so it should be possible to move the XBDA.
 - doesn't rely on the (optional) Serial ATA Capability register set ( IDP
   mechanism ) and hence should work with any AHCI device.


 4. Requirements/Restrictions
 
 - AHCICDU uses unreal-mode to access the memory-mapped device registers,
   hence it can't work in v86-mode.
 - an installed XMS host is needed to allocate extended memory for the
   driver's sector buffer and AHCI tables.
 - only "cooked" reads are supported - no support for Audio CDs.
 - max. 6 CD/DVD devices are supported.
