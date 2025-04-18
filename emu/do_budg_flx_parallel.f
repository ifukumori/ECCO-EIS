c ============================================================
c     Program to compute budget.
c
c Parellel version of do_budg_flx.f       
c 
c This version (do_budg.f) computes the budget (the right-hand-side) by
c summing converging fluxes along the target volume's boundary. In
c addition to the individual global sum of these terms, this version
c also outputs these boundary fluxes themselves. The computation
c corresponds to the surface integral in Gauss's theorem. This version
c of the budget is preferred over that below (do_budg_vol.f) as this
c allows analyses of where fluxes dictating the budget enter the target
c volume, disregarding redistribution within the volume.
c 
c An alternate version (do_budg_vol.f) computes the budget by evaluating
c convergence of fluxes at each model grid point and then adding them up
c througout the target volume. This computation corresponds to the
c volume integral in Gauss's theorem.
c
c -----------------------------------------------------
c This file consists of the following programs: 
c 
c Main Routine: 
c   do_budg: Reads where model files are located and variables
c            common to all budgets (model grid, time, ETAN).
c
c Function: 
c   julian: Computes Julian day from day/month/year.
c 
c Subroutines:
c   grid_info: Reads model grid information. 
c   budg_objf: Reads data.ecco created by budg.f that identifies the
c              target variable and volume for the budget, and then calls
c              the corresponding routine for computing the budget.
c   budg_vol: Computes volume budget. 
c   budg_heat: Computes heat budget.
c   budg_salt: Computes salt budget.
c   budg_salinity: Computes salinity budget.
c   file_search: Search and create list of named file. 
c   native_uv_conv_smpl: Compute horizontal convergence of native array.
c   convert2gcmfaces: Convert native array to gcmfaces array (2d). 
c   convert4gcmfaces: Convert gcmfaces array to native array (2d). 
c   calc_uv_conv_smpl: Compute horizontal convergence of gcmfaces array.
c   exch_uv_llc: Fill halos of gcmfaces 2d vector array. 
c   exch_t_n_llc: Fill halos of gcmfaces scalar array. 
c   native_uv_conv_smpl_flx_msk: Create native 2d mask for computing
c              horizontal convergence of a region defined by another
c              native mask.
c   adj_exch_uv_llc: Reflect halos of gcmfaces 2d vector array back to
c              range. Adjoint of exch_uv_llc.
c   adj_exch_t_n_llc: Reflect halos of gcmfaces scalar array back to
c              range. Adjoint of exch_t_n_llc.
c   native_w_conv_smpl_flx_msk: Create native 3d mask for computing
c             vertical convergence of a region defined by another native
c             mask.
c   budg_smpl: Read native 3d fluxes and compute and output converging
c              boundary fluxes defined by mask in sparse storage mode.
c   wrt_tint: Time integrate tendency time-series (1d) and output to file.
c   
c Module: mysparse
c   sparse3d: Convert native 3d mask into compact storage mode retaining
c             only non-zero elements.
c   msk_basic: From native 3d mask defining the target volume, create
c             basic masks for budget in compact storage mode (volume and 
c             converging boundary fluxes in x, y, z).
c
c ============================================================
c
      program do_budg
      use mysparse 
c -----------------------------------------------------
c ALTERNATE VERSION OF do_budg: Computes and save fluxes 
c through target region faces. 
c 
c Program for Budget Tool (V4r4)
c Collect model output based on data.ecco set up by budg.f. 
c Modeled after f17_e_2.pro 
c     
c 02 August 2023, Ichiro Fukumori (fukumori@jpl.nasa.gov)
c -----------------------------------------------------
      external StripSpaces

c     files
      character*256 f_inputdir   ! directory where tool files are 
      common /tool/f_inputdir
      character*256 file_in, file_out, file_dum, fvar  ! file names 

      character*256 f_srcdir  ! directory where state output is 
      integer istart, iend  ! start and end month of budget
      integer ipar        ! parallel run ID
      character*256 fpar  ! string(ipar)
      common /source_dir/f_srcdir, istart, iend, ipar, fpar

c     
      character*256 f_command

c model arrays
      integer nx, ny, nr
      parameter (nx=90, ny=1170, nr=50)

c model arrays
      real*4 xc(nx,ny), yc(nx,ny), rc(nr), bathy(nx,ny), ibathy(nx,ny)
      common /grid/xc, yc, rc, bathy, ibathy

      real*4 rf(nr), drf(nr)
      real*4 hfacc(nx,ny,nr), hfacw(nx,ny,nr), hfacs(nx,ny,nr)
      real*4 dxg(nx,ny), dyg(nx,ny), dvol3d(nx,ny,nr), rac(nx,ny)
      integer kmt(nx,ny)
      common /grid2/rf, drf, hfacc, hfacw, hfacs,
     $     kmt, dxg, dyg, dvol3d, rac

c Strings for naming output directory
      character*256 dir_out   ! output directory

c Common variables for all budgets
      parameter(nmonths=312, nyrs=26, yr1=1992, d2s=86400.)
     $                          ! max number of months of V4r4

      real*4 dum2d(nx,ny)
      real*4 etan(nx,ny,nmonths+1)
      real*4 dt(nmonths)
      common /budg_1/dt, etan

c --------------
c Set directory where external tool files exist
      call getarg(1,f_inputdir)

c Read directory where state output exist
      call getarg(2,f_srcdir)

c Get ID of which parallel jobs to run 
      call getarg(3,fvar)
      read(fvar,*) ncpus

      call getarg(4,fvar)
      read(fvar,*) ipar
      write(fpar,'(i3.3)') ipar

c Set start and end month for this parallel job
      if (ipar.gt.ncpus) then
         goto 9999
      else
         nlen = ceiling( float(nmonths) / float(ncpus) )
         istart = (ipar-1)*nlen + 1
         iend = ipar*nlen
         if (iend.gt.nmonths) iend=nmonths
      endif

      write(6,"(a,4(1x,i3))") 'CPUs, months:',ncpus,ipar,istart,iend

c --------------
c Get model grid info
      call grid_info

c --------------
c Set time (length of each month in seconds.)
      idum = 0
      do iyr=1,nyrs 
         iy = yr1 + iyr - 1
         do im=1,12
            if (im .ne. 12) then 
               nday = julian(1,im+1,iy)-julian(1,im,iy)
            else
               nday = julian(1,1,iy+1)-julian(1,im,iy)
            endif
            idum = idum + 1
            dt(idum) = nday*d2s
         enddo
      enddo

c --------------
c Read ETAN (snapshot sea level ETAN) 
      fvar = 'ETAN_mon_inst'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_out = './do_budg.files' // '_' // trim(fpar)

      call file_search(file_in, file_out, nfiles)
      if (nfiles+1 .ne. nmonths) then
         write(6,*) 'nfiles+1 ne nmonths: ',nfiles,nmonths
         stop
      endif
      
      open (52, file=file_out, action='read')

      imin = istart-1
      imax = iend+1

      do i=2,nfiles+1
         read(52,"(a)") file_dum
         if (i.ge.imin .and. i.le.imax) then
            open (53, file=file_dum, action='read', access='stream')
            read (53) dum2d
            etan(:,:,i) = dum2d
            close(53)
         endif
      enddo

      close(52)

      etan(:,:,1) = etan(:,:,2)
      etan(:,:,nfiles+2) = etan(:,:,nfiles+1)
         
c --------------
c Collect model fluxes 
      call budg_objf

 9999 continue
      stop
      end program do_budg
c 
c ============================================================
c 
      function julian(nj, nm, na)
c Count julian day starting from 1/1/1950
      integer(8) m(12)
      integer(8) iy, ia
      integer nj, nm, na

      m(:) = [-1,31,28,31,30,31,30,31,31,30,31,30] 

      iy = na - 1948
      ia = (iy-1)/4
      julian = ia + 365*iy-730
      do n=1,nm
         julian = julian + m(n)
      enddo

      if (nm.le.2) then
         julian = julian + nj
         return
      endif

      jy = na/4
      ix = na-jy*4
      if (ix.ne.0) then
         julian = julian + nj
         return
      endif
      julian = julian + 1
      julian = julian + nj

      return
      end function julian 

c 
c ============================================================
c 
      subroutine budg_objf
      use mysparse 
c Compute OBJF budget per data.ecco by budg.f

      character*256 f_srcdir  ! directory where state output is 
      integer istart, iend  ! start and end month of budget
      integer ipar        ! parallel run ID
      character*256 fpar  ! string(ipar)
      common /source_dir/f_srcdir, istart, iend, ipar, fpar

c     model arrays
      integer nx, ny, nr
      parameter (nx=90, ny=1170, nr=50)

c     Number of Generic Cost terms:
c     =============================
      INTEGER NGENCOST
      PARAMETER ( NGENCOST=40 )


      INTEGER MAX_LEN_FNAM
      PARAMETER ( MAX_LEN_FNAM = 512 )

      character*(MAX_LEN_FNAM) gencost_name(NGENCOST)
      character*(MAX_LEN_FNAM) gencost_barfile(NGENCOST)
      character*(5)            gencost_avgperiod(NGENCOST)
      character*(MAX_LEN_FNAM) gencost_mask(NGENCOST)
      real*4                   mult_gencost(NGENCOST)
      LOGICAL gencost_msk_is3d(NGENCOST)

      namelist /ecco_gencost_nml/
     &         gencost_barfile,
     &         gencost_name,
     &         gencost_mask,      
     &         gencost_avgperiod,
     &         gencost_msk_is3d,
     &         mult_gencost

c Target volume 
      integer nobjf, iobjf
      character*256 fmask

c Mask  
      real*4 msk3d(nx,ny,nr)

c model arrays
      real*4 xc(nx,ny), yc(nx,ny), rc(nr), bathy(nx,ny), ibathy(nx,ny)
      common /grid/xc, yc, rc, bathy, ibathy

      real*4 rf(nr), drf(nr)
      real*4 hfacc(nx,ny,nr), hfacw(nx,ny,nr), hfacs(nx,ny,nr)
      real*4 dxg(nx,ny), dyg(nx,ny), dvol3d(nx,ny,nr), rac(nx,ny)
      integer kmt(nx,ny)
      common /grid2/rf, drf, hfacc, hfacw, hfacs,
     $     kmt, dxg, dyg, dvol3d, rac

c 
      real*4 dum2d(nx,ny)

c ------------------
c Read in OBJF definition from data.ecco

c Set ecco_gencost_nml default
      do i=1,NGENCOST
         gencost_name(i) = 'gencost'
         gencost_barfile(i) = ' '
         gencost_avgperiod(i) = ' '
         gencost_mask(i) = ' '
         gencost_msk_is3d(i) = .FALSE. 
         mult_gencost(i) = 0.
      enddo
         
      open(70,file='data.ecco')
      read(70,nml=ecco_gencost_nml)
      close(70)

      nobjf = 0
      do i=1,NGENCOST
         if (gencost_name(i) .eq. 'boxmean') nobjf = nobjf + 1
      enddo

      if (nobjf .ne. 1 .and. istart.eq.1) then
         write(6,*) 'data.ecco does not conform to budget tool.'
         write(6,*) 'Aborting do_budg.f ... '
         stop
      endif

c ------------------
c Default to single target volume 
      iobjf = 1

c ------------------
c Read mask for target volume 

      fmask = trim(gencost_mask(iobjf)) // 'C'
      call chk_mask3d(fmask,nx,ny,nr,msk3d,ipar)

c ------------------
c Read in model output 

c Monthly state 
      if (trim(gencost_avgperiod(1)).eq.'month') then 

      if (istart.eq.1) write(6,"(a,/)") 'Budget MONTHLY means ... '

c do particular budget       
      if (gencost_barfile(iobjf).eq.'m_boxmean_volume') then 
         call budg_vol(msk3d)

      else if (gencost_barfile(iobjf).eq.'m_boxmean_heat') then 
         call budg_heat(msk3d)

      else if (gencost_barfile(iobjf).eq.'m_boxmean_salt') then 
         call budg_salt(msk3d)

      else if (gencost_barfile(iobjf).eq.'m_boxmean_salinity') then 
         call budg_salinity(msk3d)
         
      else if (gencost_barfile(iobjf).eq.'m_boxmean_momentum') then 
         write(6,*) 'Momentum budget not yet implemented ... '
         
      else
         write(6,*) 'This should not happen ... '
         stop
      endif
            
c Incorrect average specified
      else
         write(6,*) 'This should not happen ... Aborting'
         write(6,*) 'avgperiod = ',trim(gencost_avgperiod(1))
         stop
      endif

      return 
      end subroutine budg_objf
c 
c ============================================================
c 
      subroutine budg_vol(msk3d)

      use mysparse 
      integer nx, ny, nr
      parameter(nx=90, ny=1170, nr=50)
      parameter(nmonths=312, nyrs=26, yr1=1992, d2s=86400.)
     $                          ! max number of months of V4r4

c Mask  
      real*4 msk3d(nx,ny,nr), wmag, totv_inv 

c Mask in sparse mode
c target volume
      integer n3d_v
      real, allocatable :: f3d_v(:)
      integer, allocatable :: i3d_v(:)
      integer, allocatable :: j3d_v(:)
      integer, allocatable :: k3d_v(:)
      real, allocatable :: b3d_v(:)
c x-converence
      integer n3d_x
      real, allocatable :: f3d_x(:)
      integer, allocatable :: i3d_x(:)
      integer, allocatable :: j3d_x(:)
      integer, allocatable :: k3d_x(:)
      real, allocatable :: b3d_x(:)
c y-converence
      integer n3d_y
      real, allocatable :: f3d_y(:)
      integer, allocatable :: i3d_y(:)
      integer, allocatable :: j3d_y(:)
      integer, allocatable :: k3d_y(:)
      real, allocatable :: b3d_y(:)
c z-converence
      integer n3d_z
      real, allocatable :: f3d_z(:)
      integer, allocatable :: i3d_z(:)
      integer, allocatable :: j3d_z(:)
      integer, allocatable :: k3d_z(:)
      real, allocatable :: b3d_z(:)

c surface forcing 
      integer n3d_s
      real, allocatable :: f3d_s(:)
      integer, allocatable :: i3d_s(:)
      integer, allocatable :: j3d_s(:)
      integer, allocatable :: k3d_s(:)
      real, allocatable :: b3d_s(:)

c model arrays
      real*4 xc(nx,ny), yc(nx,ny), rc(nr), bathy(nx,ny), ibathy(nx,ny)
      common /grid/xc, yc, rc, bathy, ibathy

      real*4 rf(nr), drf(nr)
      real*4 hfacc(nx,ny,nr), hfacw(nx,ny,nr), hfacs(nx,ny,nr)
      real*4 dxg(nx,ny), dyg(nx,ny), dvol3d(nx,ny,nr), rac(nx,ny)
      integer kmt(nx,ny)
      common /grid2/rf, drf, hfacc, hfacw, hfacs,
     $     kmt, dxg, dyg, dvol3d, rac

c Common variables for all budgets
      real*4 etan(nx,ny,nmonths+1)
      real*4 dt(nmonths)
      common /budg_1/dt, etan

c Temporarly variables 
      real*4 dum2d(nx,ny), dum3d(nx,ny,nr)
      real*4 conv2d(nx,ny), dum3dy(nx,ny,nr)
      integer iold, inew 

      character*256 f_file 
      character*256 f_command 

c Budget arrays 
      real*4 lhs(nmonths)
      real*4 advh(nmonths), advv(nmonths)
      real*4 mixh(nmonths), mixv(nmonths)
      real*4 mixv_i(nmonths), mixv_e(nmonths)
      real*4 vfrc(nmonths), geo(nmonths)

c files
      character*256 f_inputdir   ! directory where tool files are 
      common /tool/f_inputdir
      character*256 file_in, file_out, file_dum, fvar, file_temp
      character*12  fname 

      character*256 f_srcdir  ! directory where state output is 
      integer istart, iend  ! start and end month of budget
      integer ipar        ! parallel run ID
      character*256 fpar  ! string(ipar)
      common /source_dir/f_srcdir, istart, iend, ipar, fpar

c     ------------------------------------
c Establish basic masks (volume, boundary convergence) in sparse mode
      wmag = 0.9

      call msk_basic(msk3d, totv_inv, wmag, ipar, 
     $        n3d_v, f3d_v, i3d_v, j3d_v, k3d_v, b3d_v,
     $        n3d_x, f3d_x, i3d_x, j3d_x, k3d_x, b3d_x,
     $        n3d_y, f3d_y, i3d_y, j3d_y, k3d_y, b3d_y,
     $        n3d_z, f3d_z, i3d_z, j3d_z, k3d_z, b3d_z)

c ------------------------------------
c Tendency output 
      ibud = 1   ! indicates volume budget 

      file_out = './emu_budg.sum_tend' // '_' // trim(fpar)
      open (31, file=trim(file_out), action='write', access='stream')
      write(31) ibud
      write(31) nmonths
      fname = 'dt'
      write(31) fname
      write(31) dt

c ------------------------------------
c Constants
      rho0 = 1029.   ! reference density 

c ------------------------------------
c Compute different terms 

c ------------------------------------
c Compute LHS (volume tendency)

cc Output individual makeup of LHS 
c      file_out = './emu_budg.mkup_lhs' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
      i31 = 2
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Loop over months 
      lhs(:) = 0.
      do im=istart,iend

c Sum over target volume
         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            b3d_v(ic) = (etan(i,j,im+1)-etan(i,j,im))/dt(im)*ibathy(i,j)
     $           *dvol3d(i,j,k)*f3d_v(ic)
     $           * totv_inv  ! convert to value per volume

            lhs(im) = lhs(im) + b3d_v(ic)
         enddo

cc Output makeup 
c         write(41) b3d_v

      enddo  ! End time loop till nmonths-1

c      close(41)

c Output tendency 
      fname = 'lhs'
      write(31) fname 
      write(31) lhs 

c ------------------------------------
c Compute RHS tendencies 

c ------------------------------------
c Horizontal Advection 

      if (n3d_x+n3d_y .ne. 0) then 

      advh(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Convergence in x 
      if (n3d_x .ne. 0) then 

c Output individual makeup of the term 
      file_out = './emu_budg.mkup_adv_x' // '_' // trim(fpar)
      open (41, file=trim(file_out), action='write', access='stream')
      write(41) 'x'  ! mask
      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Monthly UVELMASS
      fvar = 'UVELMASS_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar)
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')

c Loop over months 
      do im=1,nmonths
         read(51,"(a)") file_dum
         if (im.ge.istart .and. im.le.iend) then
         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum3d
         close(53)

         b3d_x(:) = 0.
         do ic=1,n3d_x
            i=i3d_x(ic)
            j=j3d_x(ic)
            k=k3d_x(ic)

            b3d_x(ic) = dum3d(i,j,k)*dyg(i,j)* f3d_x(ic)*drf(k)
     $           * totv_inv  ! convert to value per volume 

            advh(im) = advh(im) + b3d_x(ic)
         enddo

c Output makeup 
         write(41) b3d_x
         endif
      enddo  ! End time loop till nmonths

      close(41)
      close(51)

      endif ! End Convergence in x 

c Convergence in y 
      if (n3d_y .ne. 0) then 

c Output individual makeup of the term 
      file_out = './emu_budg.mkup_adv_y' // '_' // trim(fpar)
      open (41, file=trim(file_out), action='write', access='stream')
      write(41) 'y'  ! mask
      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Monthly VVELMASS
      fvar = 'VVELMASS_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')

c Loop over months 
      do im=1,nmonths
         read(51,"(a)") file_dum
         if (im.ge.istart .and. im.le.iend) then
         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum3d
         close(53)

         b3d_y(:) = 0.
         do ic=1,n3d_y
            i=i3d_y(ic)
            j=j3d_y(ic)
            k=k3d_y(ic)

            b3d_y(ic) = dum3d(i,j,k)*dxg(i,j)* f3d_y(ic)*drf(k)
     $           * totv_inv  ! convert to value per volume

            advh(im) = advh(im) + b3d_y(ic)
         enddo

c Output makeup 
         write(41) b3d_y
      endif
      enddo  ! End time loop till nmonths
      close(41)
      close(51)

      endif ! End Convergence in y

c Output tendency 
      fname = 'advh'
      write(31) fname 
      write(31) advh 

c
      endif  ! end horizontal advection 

c ------------------------------------
c Vertical Advection 

      if (n3d_z .ne. 0) then 

      advv(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Output individual makeup of the term 
      file_out = './emu_budg.mkup_adv_z' // '_' // trim(fpar)
      open (41, file=trim(file_out), action='write', access='stream')
      write(41) 'z'  ! mask
      write(41) i31    ! corresponding array in emu_budg.sum_trend

c ID vertical advection files
      fvar = 'WVELMASS_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif

      open (51, file=trim(file_temp), action='read')

c Loop over months 
      do im=1,nmonths
         read(51,"(a)") file_dum
         if (im.ge.istart .and. im.le.iend) then
         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum3d
         close(53)

         b3d_z(:) = 0.
         do ic=1,n3d_z
            i=i3d_z(ic)
            j=j3d_z(ic)
            k=k3d_z(ic)
            if (k .ne. 1) then 
               b3d_z(ic) = dum3d(i,j,k) *f3d_z(ic) *rac(i,j)
     $           * totv_inv  ! convert to value per volume
            endif

            advv(im) = advv(im) + b3d_z(ic)
         enddo

c Output makeup 
         write(41) b3d_z
         endif
      enddo  ! End time loop till nmonths
      close(51)
      close(41)

c Output tendency 
      fname = 'advv'
      write(31) fname 
      write(31) advv

c
      endif  ! end vertical advection 

c ------------------------------------
c Forcing 

c ------------------------------------
c oceFWflx files 

c Surface forcing mask
      dum3d(:,:,:) = 0.
      do i=1,nx
         do j=1,ny
            dum3d(i,j,1) = msk3d(i,j,1)
         enddo
      enddo
      
      call sparse3d(dum3d,  wmag, 
     $     n3d_s,  f3d_s,  i3d_s,  j3d_s,  k3d_s, b3d_s)

c Check if volume includes surface 
      if (n3d_s.ne.0) then ! there is surface 

c Save mask 
      if (istart.eq.1) then 
         file_dum = './emu_budg.msk3d_s'
         open(41,file=trim(file_dum),access='stream')
         write(41) n3d_s
         write(41) f3d_s
         write(41) i3d_s, j3d_s, k3d_s
         close(41)
      endif
c Compute volume's surface forcing 
      vfrc(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Output individual makeup of the term 
      file_out = './emu_budg.mkup_srf' // '_' // trim(fpar)
      open (41, file=trim(file_out), action='write', access='stream')
      write(41) 's'
      write(41) i31

c Surface Freshwater flux 
      fvar = 'oceFWflx_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')
      
c Loop over time 
      do im=1,nmonths
         read(51,"(a)") file_dum
         if (im.ge.istart .and. im.le.iend) then
         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum2d   ! oceFWflx read into dum2d
         close(53)

c Distribute
         do ic=1,n3d_s
            i = i3d_s(ic)
            j = j3d_s(ic)
            k = k3d_s(ic)
            
            b3d_s(ic) = dum2d(i,j)*rac(i,j) / rho0
     $           * totv_inv  ! convert to value per volume

            vfrc(im) = vfrc(im) + b3d_s(ic)
         enddo

         write(41) b3d_s
         endif
      enddo  ! end loop over nmonths
      close(51)
      close(41)

c Output tendency 
      fname = 'vfrc'
      write(31) fname 
      write(31) vfrc

      endif   ! n3d_s.ne.0 

c ------------------------------------
c Close output 
      close(31)

      return
      end subroutine budg_vol
c 
c ============================================================
c 
      subroutine budg_heat(msk3d)

      use mysparse 
      integer nx, ny, nr
      parameter(nx=90, ny=1170, nr=50)
      parameter(nmonths=312, nyrs=26, yr1=1992, d2s=86400.)
     $                          ! max number of months of V4r4

c Mask  
      real*4 msk3d(nx,ny,nr), wmag, totv_inv 

c Mask in sparse mode
c target volume
      integer n3d_v
      real, allocatable :: f3d_v(:)
      integer, allocatable :: i3d_v(:)
      integer, allocatable :: j3d_v(:)
      integer, allocatable :: k3d_v(:)
      real, allocatable :: b3d_v(:)
c x-converence
      integer n3d_x
      real, allocatable :: f3d_x(:)
      integer, allocatable :: i3d_x(:)
      integer, allocatable :: j3d_x(:)
      integer, allocatable :: k3d_x(:)
      real, allocatable :: b3d_x(:)
c y-converence
      integer n3d_y
      real, allocatable :: f3d_y(:)
      integer, allocatable :: i3d_y(:)
      integer, allocatable :: j3d_y(:)
      integer, allocatable :: k3d_y(:)
      real, allocatable :: b3d_y(:)
c z-converence
      integer n3d_z
      real, allocatable :: f3d_z(:)
      integer, allocatable :: i3d_z(:)
      integer, allocatable :: j3d_z(:)
      integer, allocatable :: k3d_z(:)
      real, allocatable :: b3d_z(:)

c geothermal convergence 
      integer n3d_g
      real, allocatable :: f3d_g(:)
      integer, allocatable :: i3d_g(:)
      integer, allocatable :: j3d_g(:)
      integer, allocatable :: k3d_g(:)
      real, allocatable :: b3d_g(:)
c atmospheric convergence 
      integer n3d_a
      real, allocatable :: f3d_a(:)
      integer, allocatable :: i3d_a(:)
      integer, allocatable :: j3d_a(:)
      integer, allocatable :: k3d_a(:)
      real, allocatable :: b3d_a(:)

c model arrays
      real*4 xc(nx,ny), yc(nx,ny), rc(nr), bathy(nx,ny), ibathy(nx,ny)
      common /grid/xc, yc, rc, bathy, ibathy

      real*4 rf(nr), drf(nr)
      real*4 hfacc(nx,ny,nr), hfacw(nx,ny,nr), hfacs(nx,ny,nr)
      real*4 dxg(nx,ny), dyg(nx,ny), dvol3d(nx,ny,nr), rac(nx,ny)
      integer kmt(nx,ny)
      common /grid2/rf, drf, hfacc, hfacw, hfacs,
     $     kmt, dxg, dyg, dvol3d, rac

c Common variables for all budgets
      real*4 etan(nx,ny,nmonths+1)
      real*4 dt(nmonths)
      common /budg_1/dt, etan

c Temporarly variables 
      real*4 dum2d(nx,ny), dum3d(nx,ny,nr)
      real*4 conv2d(nx,ny), dum3dy(nx,ny,nr)
      real*4 theta(nx,ny,nr,2)
      integer iold, inew 

      real*4 s0(nx,ny), s1(nx,ny)
      real*4 qfac(2,nr)
      character*256 f_file 
      character*256 f_command 

c Budget arrays 
      real*4 lhs(nmonths)
      real*4 advh(nmonths), advv(nmonths)
      real*4 mixh(nmonths), mixv(nmonths)
      real*4 tfrc(nmonths), geo(nmonths)

c files
      character*256 f_inputdir   ! directory where tool files are 
      common /tool/f_inputdir
      character*256 file_in, file_out, file_dum, fvar, file_temp
      character*12  fname
      character*256 file_rec(nmonths+1)

      character*256 f_srcdir  ! directory where state output is 
      integer istart, iend  ! start and end month of budget
      integer ipar        ! parallel run ID
      character*256 fpar  ! string(ipar)
      common /source_dir/f_srcdir, istart, iend, ipar, fpar
      
c ------------------------------------
c Establish basic masks (volume, boundary convergence) in sparse mode
      wmag = 0.9

      call msk_basic(msk3d, totv_inv, wmag, ipar, 
     $        n3d_v, f3d_v, i3d_v, j3d_v, k3d_v, b3d_v,
     $        n3d_x, f3d_x, i3d_x, j3d_x, k3d_x, b3d_x,
     $        n3d_y, f3d_y, i3d_y, j3d_y, k3d_y, b3d_y,
     $        n3d_z, f3d_z, i3d_z, j3d_z, k3d_z, b3d_z)

c ------------------------------------
c Tendency output 
      ibud = 2   ! indicates heat (temperature) budget 

      file_out = './emu_budg.sum_tend' // '_' // trim(fpar)
      open (31, file=trim(file_out), action='write', access='stream')
      write(31) ibud
      write(31) nmonths
      fname = 'dt'
      write(31) fname
      write(31) dt

c ------------------------------------
c Constants
      rho0 = 1029.   ! reference density 
      cp = 3994.     ! heat capacity 
      t2q = rho0 * cp ! degC to J conversion 

c ------------------------------------
c Compute different terms 

c ------------------------------------
c Compute LHS (heat tendency)
      fvar = 'THETA_mon_inst'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in, file_temp, nfiles)
      if (nfiles+1 .ne. nmonths) then
         write(6,*) 'nfiles+1 ne nmonths: ',nfiles,nmonths
         stop
      endif

c Read and store THETA file names
c (Set 1st file as being the 1st and 2nd month)
c (Repeat last files as month nmonths & nmonths+1.)
      open (52, file=file_temp, action='read')
      do i=2,nmonths
         read(52,"(a)") file_rec(i)
      enddo
      close(52)
      file_rec(1)=file_rec(2)
      file_rec(nmonths+1)=file_rec(nmonths)

cc Output individual makeup of LHS 
c      file_out = './emu_budg.mkup_lhs' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
      i31 = 2
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Loop over months
      lhs(:) = 0.

c Read THETA at istart
      file_dum=file_rec(istart)
      open (53, file=trim(file_dum), action='read', access='stream')
      read (53) dum3d
      close(53)
      inew = 1
      iold = 3-inew 
      theta(:,:,:,inew) = dum3d    

      do im=istart,iend

c Read next THETA
         file_dum=file_rec(im+1)
         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum3d
         close(53)
         iold = inew
         inew = 3-iold
         theta(:,:,:,inew) = dum3d         

c Sum over target volume
         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            s0b = 1. + etan(i,j,im)*ibathy(i,j)
            s1b = 1. + etan(i,j,im+1)*ibathy(i,j)

            b3d_v(ic) = f3d_v(ic)*(theta(i,j,k,inew)*s1b -
     $           theta(i,j,k,iold)*s0b)/dt(im) * dvol3d(i,j,k)
     $           * totv_inv  ! convert to value per volume (degC/s)

            lhs(im) = lhs(im) + b3d_v(ic)
         enddo

cc Output makeup 
c         write(41) b3d_v

      enddo  ! End time loop from istart to iend
c     close(41)
      
c Output tendency 
      fname = 'lhs'
      write(31) fname 
      write(31) lhs 

c ------------------------------------
c Compute RHS tendencies 

c ------------------------------------
c Horizontal Advection 

      if (n3d_x+n3d_y .ne. 0) then 

      advh(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Advection in x
      if (n3d_x .ne. 0) then 

      fvar = 'ADVx_TH_mon_mean'
      file_out = './emu_budg.mkup_adv_x' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_x, f3d_x, i3d_x, j3d_x, k3d_x, b3d_x, 'x', i31, 
     $     advh, file_out)

      endif ! end advection in x

c Advection in y
      if (n3d_y .ne. 0) then 

      fvar = 'ADVy_TH_mon_mean'
      file_out = './emu_budg.mkup_adv_y' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_y, f3d_y, i3d_y, j3d_y, k3d_y, b3d_y, 'y', i31, 
     $     advh, file_out)

      endif ! end advection in y

c Output tendency 
      fname = 'advh'
      write(31) fname 
      write(31) advh

      endif ! end horizontal advection 

c ------------------------------------
c Horizontal Mixing 

      if (n3d_x+n3d_y .ne. 0) then 

      mixh(:) = 0.

      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Mixing in x
      if (n3d_x .ne. 0) then 

      fvar = 'DFxE_TH_mon_mean'
      file_out = './emu_budg.mkup_mix_x' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_x, f3d_x, i3d_x, j3d_x, k3d_x, b3d_x, 'x', i31, 
     $     mixh, file_out)

      endif ! end mixing in x

c Mixing in y
      if (n3d_y .ne. 0) then 

      fvar = 'DFyE_TH_mon_mean'
      file_out = './emu_budg.mkup_mix_y' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_y, f3d_y, i3d_y, j3d_y, k3d_y, b3d_y, 'y', i31, 
     $     mixh, file_out)

      endif ! end mixing in y

c Output tendency 
      fname = 'mixh'
      write(31) fname 
      write(31) mixh

      endif ! end horizontal mixing 

c ------------------------------------
c Vertical Advection 

      if (n3d_z .ne. 0) then 

      advv(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Advection in z 
      fvar = 'ADVr_TH_mon_mean'
      file_out = './emu_budg.mkup_adv_z' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_z, f3d_z, i3d_z, j3d_z, k3d_z, b3d_z, 'z', i31, 
     $     advv, file_out)

c Output tendency 
      fname = 'advv'
      write(31) fname 
      write(31) advv

      endif ! end vertical advetion (n3d_z)

c ------------------------------------
c Vertical Mixing 

      if (n3d_z .ne. 0) then 

      mixv(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Vertical IMPLICIT mixing
      fvar = 'DFrI_TH_mon_mean'
      file_out = './emu_budg.mkup_mix_z_i' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_z, f3d_z, i3d_z, j3d_z, k3d_z, b3d_z, 'z', i31, 
     $     mixv, file_out)

c Vertical EXPLICIT mixing 
      fvar = 'DFrE_TH_mon_mean'
      file_out = './emu_budg.mkup_mix_z_e' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_z, f3d_z, i3d_z, j3d_z, k3d_z, b3d_z, 'z', i31, 
     $     mixv, file_out)

c Output tendency 
      fname = 'mixv'
      write(31) fname 
      write(31) mixv

      endif ! end vertical mixing (n3d_z)

c ------------------------------------
c Atmospheric forcing (TFLUX & oceQsw)

c Shortwave penetration factors
      kmax = 1
      do k=1,nr
c         if (rc(k) .lt. 200.) kmax = k
         if (rc(k) .gt. -200.) kmax = k
      enddo

      rfac = 0.62
      zeta1 = 0.6
      zeta2 = 20

      do k=1,kmax
         qfac(1,k) = rfac*exp(rf(k)/zeta1)
     $        + (1.-rfac)*exp(rf(k)/zeta2) 
         qfac(2,k) = rfac*exp(rf(k+1)/zeta1)
     $        + (1.-rfac)*exp(rf(k+1)/zeta2) 
      enddo

c Heat forcing mask
      dum3d(:,:,:) = 0.
      do i=1,nx
         do j=1,ny
            do k=1,kmax
               dum3d(i,j,k) = msk3d(i,j,k)
            enddo
         enddo
      enddo
      
      call sparse3d(dum3d,  wmag, 
     $     n3d_a,  f3d_a,  i3d_a,  j3d_a,  k3d_a, b3d_a)

c Check if volume has atmospheric forcing 
      if (n3d_a.ne.0) then ! there is atmostpheric flux convergence

c Save mask 
      if (ipar.eq.1) then 
         file_dum = './emu_budg.msk3d_a'
         open(41,file=trim(file_dum),access='stream')
         write(41) n3d_a
         write(41) f3d_a
         write(41) i3d_a, j3d_a, k3d_a
         close(41)
      endif

c Compute volume's atmospheric forcing 
      tfrc(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Output individual makeup of the term 
      file_out = './emu_budg.mkup_atm' // '_' // trim(fpar)
      open (41, file=trim(file_out), action='write', access='stream')
      write(41) 'a'
      write(41) i31

c TFLUX & oceQsw files 
      fvar = 'TFLUX_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')
      
      fvar = 'oceQsw_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files_2' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (52, file=trim(file_temp), action='read')

c Loop over time 
      do im=1,nmonths
c Read TFLUX & oceQsw
         read(51,"(a)") file_dum
         read(52,"(a)") file_temp
         if (im.ge.istart .and. im.le.iend) then

         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum2d   ! TFLUX read into dum2d
         close(53)

         open (53, file=trim(file_temp), action='read', access='stream')
         read (53) conv2d  ! oceQsw read into conv2d
         close(53)

c Distribute sw included in TFLUX vertically 
         do ic=1,n3d_a 
            i = i3d_a(ic)
            j = j3d_a(ic)
            k = k3d_a(ic)
            
            if (k.eq.1) then
               b3d_a(ic) = dum2d(i,j) - conv2d(i,j)
     $        + (qfac(1,k)-qfac(2,k))*conv2d(i,j)
            else
               b3d_a(ic) = (qfac(1,k)-qfac(2,k))*conv2d(i,j)
            endif
            b3d_a(ic) = b3d_a(ic)*f3d_a(ic)*rac(i,j) / t2q
     $              * totv_inv 

            tfrc(im) = tfrc(im) + b3d_a(ic)
         enddo

         write(41) b3d_a
         endif
      enddo

      close(51)
      close(52)

      close(41)

c Output tendency 
      fname = 'tfrc'
      write(31) fname 
      write(31) tfrc

      endif   ! end Atmospheric Forcing (n3d_a)

c ------------------------------------
c Geothermal flux 

c geothermal mask (ID geothermal points in domain) 
      dum3d(:,:,:) = 0.
      do i=1,nx
         do j=1,ny
            if (kmt(i,j).ne.0) then
               dum3d(i,j,kmt(i,j)) = msk3d(i,j,kmt(i,j))
            endif
         enddo
      enddo

      call sparse3d(dum3d,  wmag, 
     $     n3d_g,  f3d_g,  i3d_g,  j3d_g,  k3d_g, b3d_g)

c Check if volume has geothermal forcing 
      if (n3d_g.ne.0) then  ! there is geothermal flux convergence

c Save mask 
      if (ipar.eq.1) then 
         file_dum = './emu_budg.msk3d_g'
         open(41,file=trim(file_dum),access='stream')
         write(41) n3d_g
         write(41) f3d_g
         write(41) i3d_g, j3d_g, k3d_g
         close(41)
      endif

c Compute volume's geothermal convergence 
      geo(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Read in time-invariant geothermal flux 
      file_in = trim(f_inputdir) //
     $     '/forcing/input_init/geothermalFlux.bin' 
      open (51, file=trim(file_in), action='read', access='stream')
      read (51) conv2d  ! geothermal read into conv2d
      close (51)

c Sum over domain 
      geo_s = 0.   ! scalar sum 
      do i=1,n3d_g
         b3d_g(i) = f3d_g(i) *
     $        conv2d(i3d_g(i),j3d_g(i)) *
     $        rac(i3d_g(i),j3d_g(i)) / t2q
     $              * totv_inv 

         geo_s = geo_s + b3d_g(i)
      enddo

c Output individual makeup of the term 
      file_out = './emu_budg.mkup_geo' // '_' // trim(fpar)
      open (41, file=trim(file_out), action='write', access='stream')
      write(41) 'g'
      write(41) i31
      do i=istart,iend
         write(41) b3d_g
      enddo
      close(41)

      geo(istart:iend) = geo_s   ! time-invariant

c Output tendency 
      fname = 'geo'
      write(31) fname 
      write(31) geo

      endif   ! end Geothermal Forcing (n3d_g)

c ------------------------------------
c Close output 
      close(31)

      return
      end subroutine budg_heat 
c 
c ============================================================
c 
      subroutine budg_salt(msk3d)

      use mysparse 
      integer nx, ny, nr
      parameter(nx=90, ny=1170, nr=50)
      parameter(nmonths=312, nyrs=26, yr1=1992, d2s=86400.)
     $                          ! max number of months of V4r4

c Mask  
      real*4 msk3d(nx,ny,nr), wmag, totv_inv 

c Mask in sparse mode
c target volume
      integer n3d_v
      real, allocatable :: f3d_v(:)
      integer, allocatable :: i3d_v(:)
      integer, allocatable :: j3d_v(:)
      integer, allocatable :: k3d_v(:)
      real, allocatable :: b3d_v(:)
c x-converence
      integer n3d_x
      real, allocatable :: f3d_x(:)
      integer, allocatable :: i3d_x(:)
      integer, allocatable :: j3d_x(:)
      integer, allocatable :: k3d_x(:)
      real, allocatable :: b3d_x(:)
c y-converence
      integer n3d_y
      real, allocatable :: f3d_y(:)
      integer, allocatable :: i3d_y(:)
      integer, allocatable :: j3d_y(:)
      integer, allocatable :: k3d_y(:)
      real, allocatable :: b3d_y(:)
c z-converence
      integer n3d_z
      real, allocatable :: f3d_z(:)
      integer, allocatable :: i3d_z(:)
      integer, allocatable :: j3d_z(:)
      integer, allocatable :: k3d_z(:)
      real, allocatable :: b3d_z(:)

c surface forcing 
      integer n3d_s
      real, allocatable :: f3d_s(:)
      integer, allocatable :: i3d_s(:)
      integer, allocatable :: j3d_s(:)
      integer, allocatable :: k3d_s(:)
      real, allocatable :: b3d_s(:)

c model arrays
      real*4 xc(nx,ny), yc(nx,ny), rc(nr), bathy(nx,ny), ibathy(nx,ny)
      common /grid/xc, yc, rc, bathy, ibathy

      real*4 rf(nr), drf(nr)
      real*4 hfacc(nx,ny,nr), hfacw(nx,ny,nr), hfacs(nx,ny,nr)
      real*4 dxg(nx,ny), dyg(nx,ny), dvol3d(nx,ny,nr), rac(nx,ny)
      integer kmt(nx,ny)
      common /grid2/rf, drf, hfacc, hfacw, hfacs,
     $     kmt, dxg, dyg, dvol3d, rac

c Common variables for all budgets
      real*4 etan(nx,ny,nmonths+1)
      real*4 dt(nmonths)
      common /budg_1/dt, etan

c Temporarly variables 
      real*4 dum2d(nx,ny), dum3d(nx,ny,nr)
      real*4 conv2d(nx,ny), dum3dy(nx,ny,nr)
      real*4 salt(nx,ny,nr,2)
      integer iold, inew 

      character*256 f_file 
      character*256 f_command 

c Budget arrays 
      real*4 lhs(nmonths)
      real*4 advh(nmonths), advv(nmonths)
      real*4 mixh(nmonths), mixv(nmonths)
      real*4 mixv_i(nmonths), mixv_e(nmonths)
      real*4 sfrc(nmonths)

c files
      character*256 f_inputdir   ! directory where tool files are 
      common /tool/f_inputdir
      character*256 file_in, file_out, file_dum, fvar, file_temp
      character*12  fname 
      character*256 file_rec(nmonths+1)

      character*256 f_srcdir  ! directory where state output is 
      integer istart, iend  ! start and end month of budget
      integer ipar        ! parallel run ID
      character*256 fpar  ! string(ipar)
      common /source_dir/f_srcdir, istart, iend, ipar, fpar
      
c ------------------------------------
c Establish basic masks (volume, boundary convergence) in sparse mode
      wmag = 0.9

      call msk_basic(msk3d, totv_inv, wmag, ipar, 
     $        n3d_v, f3d_v, i3d_v, j3d_v, k3d_v, b3d_v,
     $        n3d_x, f3d_x, i3d_x, j3d_x, k3d_x, b3d_x,
     $        n3d_y, f3d_y, i3d_y, j3d_y, k3d_y, b3d_y,
     $        n3d_z, f3d_z, i3d_z, j3d_z, k3d_z, b3d_z)

c ------------------------------------
c Tendency output 
      ibud = 3   ! indicates salt budget 

      file_out = './emu_budg.sum_tend' // '_' // trim(fpar)
      open (31, file=trim(file_out), action='write', access='stream')
      write(31) ibud
      write(31) nmonths
      fname = 'dt'
      write(31) fname
      write(31) dt

c ------------------------------------
c Constants
      rho0 = 1029.   ! reference density 

c ------------------------------------
c Compute different terms 

c ------------------------------------
c Compute LHS (salt tendency)
      fvar = 'SALT_mon_inst'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in, file_temp, nfiles)
      if (nfiles+1 .ne. nmonths) then  ! check # of files 
         write(6,*) 'nfiles+1 ne nmonths: ',nfiles,nmonths
         stop
      endif

c Read and store SALT file names
c (Set 1st file as being the 1st and 2nd month)
c (Repeat last files as month nmonths & nmonths+1.)
      open (52, file=file_temp, action='read')
      do i=2,nmonths
         read(52,"(a)") file_rec(i)
      enddo
      close(52)
      file_rec(1)=file_rec(2)
      file_rec(nmonths+1)=file_rec(nmonths)

cc Output individual makeup of LHS 
c      file_out = './emu_budg.mkup_lhs' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
      i31 = 2
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Loop over months
      lhs(:) = 0.

c Read SALT at istart
      file_dum=file_rec(istart)
      open (53, file=trim(file_dum), action='read', access='stream')
      read (53) dum3d
      close(53)
      inew = 1
      iold = 3-inew 
      salt(:,:,:,inew) = dum3d    
      
      do im=istart,iend

c Read next SALT
         file_dum=file_rec(im+1)
         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum3d
         close(53)
         iold = inew
         inew = 3-iold
         salt(:,:,:,inew) = dum3d         

c Sum over target volume
         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            s0b = 1. + etan(i,j,im)*ibathy(i,j)
            s1b = 1. + etan(i,j,im+1)*ibathy(i,j)

            b3d_v(ic) = f3d_v(ic)*(salt(i,j,k,inew)*s1b -
     $           salt(i,j,k,iold)*s0b)/dt(im) * dvol3d(i,j,k)
     $           * totv_inv  ! convert to value per volume 

            lhs(im) = lhs(im) + b3d_v(ic)
         enddo

cc Output makeup 
c         write(41) b3d_v

      enddo  ! End time loop from istart to iend
c     close(41)
      
c Output tendency 
      fname = 'lhs'
      write(31) fname 
      write(31) lhs 

c ------------------------------------
c Compute RHS tendencies 

c ------------------------------------
c Horizontal Advection 

      if (n3d_x+n3d_y .ne. 0) then 

      advh(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Advection in x
      if (n3d_x .ne. 0) then 

      fvar = 'ADVx_SLT_mon_mean'
      file_out = './emu_budg.mkup_adv_x' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_x, f3d_x, i3d_x, j3d_x, k3d_x, b3d_x, 'x', i31, 
     $     advh, file_out)

      endif ! end advection in x

c Advection in y
      if (n3d_y .ne. 0) then 

      fvar = 'ADVy_SLT_mon_mean'
      file_out = './emu_budg.mkup_adv_y' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_y, f3d_y, i3d_y, j3d_y, k3d_y, b3d_y, 'y', i31, 
     $     advh, file_out)

      endif ! end advection in y

c Output tendency 
      fname = 'advh'
      write(31) fname 
      write(31) advh

      endif ! end horizontal advection 

c ------------------------------------
c Horizontal Mixing 

      if (n3d_x+n3d_y .ne. 0) then 

      mixh(:) = 0.

      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Mixing in x
      if (n3d_x .ne. 0) then 

      fvar = 'DFxE_SLT_mon_mean'
      file_out = './emu_budg.mkup_mix_x' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_x, f3d_x, i3d_x, j3d_x, k3d_x, b3d_x, 'x', i31, 
     $     mixh, file_out)

      endif ! end mixing in x

c Mixing in y
      if (n3d_y .ne. 0) then 

      fvar = 'DFyE_SLT_mon_mean'
      file_out = './emu_budg.mkup_mix_y' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_y, f3d_y, i3d_y, j3d_y, k3d_y, b3d_y, 'y', i31, 
     $     mixh, file_out)

      endif ! end mixing in y

c Output tendency 
      fname = 'mixh'
      write(31) fname 
      write(31) mixh

      endif ! end horizontal mixing 
            
c ------------------------------------
c Vertical Advection 

      if (n3d_z .ne. 0) then 

      advv(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Advection in z 
      fvar = 'ADVr_SLT_mon_mean'
      file_out = './emu_budg.mkup_adv_z' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_z, f3d_z, i3d_z, j3d_z, k3d_z, b3d_z, 'z', i31, 
     $     advv, file_out)

c Output tendency 
      fname = 'advv'
      write(31) fname 
      write(31) advv

      endif  ! end vertical advection
            
c ------------------------------------
c Vertical Implicit Mixing 

      if (n3d_z .ne. 0) then 

      mixv(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c Vertical IMPLICIT mixing
      fvar = 'DFrI_SLT_mon_mean'
      file_out = './emu_budg.mkup_mix_z_i' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_z, f3d_z, i3d_z, j3d_z, k3d_z, b3d_z, 'z', i31, 
     $     mixv, file_out)

c Vertical EXPLICIT mixing 
      fvar = 'DFrE_SLT_mon_mean'
      file_out = './emu_budg.mkup_mix_z_e' // '_' // trim(fpar)
      call budg_smpl(fvar, totv_inv, 
     $     n3d_z, f3d_z, i3d_z, j3d_z, k3d_z, b3d_z, 'z', i31, 
     $     mixv, file_out)

c Output tendency 
      fname = 'mixv'
      write(31) fname 
      write(31) mixv

      endif ! end vertical mixing 

c ------------------------------------
c Forcing 

c ------------------------------------
c SFLUX & oceSPtnd files 

c Compute volume's atmospheric forcing 
      sfrc(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

c .........................
c Surface forcing (SFLUX) 
c Surface forcing mask
      dum3d(:,:,:) = 0.
      do i=1,nx
         do j=1,ny
            dum3d(i,j,1) = msk3d(i,j,1)
         enddo
      enddo
      
      call sparse3d(dum3d,  wmag, 
     $     n3d_s,  f3d_s,  i3d_s,  j3d_s,  k3d_s, b3d_s)

c Check if volume includes surface 
      if (n3d_s.ne.0) then ! there is surface 

c Save mask 
      if (ipar.eq.1) then 
         file_dum = './emu_budg.msk3d_s'
         open(41,file=trim(file_dum),access='stream')
         write(41) n3d_s
         write(41) f3d_s
         write(41) i3d_s, j3d_s, k3d_s
         close(41)
      endif

c Output individual makeup of the term 
      file_out = './emu_budg.mkup_frc_sflux' // '_' // trim(fpar)
      open (41, file=trim(file_out), action='write', access='stream')
      write(41) 's'
      write(41) i31
c 
      fvar = 'SFLUX_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')

c Loop over nmonths
      do im=1,nmonths
         read(51,"(a)") file_dum
         if (im.ge.istart .and. im.le.iend) then

         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum2d   ! SFLUX read into dum2d 
         close(53)

c Distribute 
         b3d_s(:) = 0.
         do ic=1,n3d_s
            i=i3d_s(ic)
            j=j3d_s(ic)
            k=k3d_s(ic)

            b3d_s(ic) = f3d_s(ic)*dum2d(i,j)*rac(i,j)/rho0
     $           * totv_inv

            sfrc(im) = sfrc(im) + b3d_s(ic)
         enddo

         write(41) b3d_s
         endif
      enddo  ! end loop over nmonths
      close(51)
      close(41)

      endif ! end of surface forcing

c .........................
c Penetrating salt flux 

c Output individual makeup of the term 
      file_out = './emu_budg.mkup_frc_oceSP' // '_' // trim(fpar)
      open (41, file=trim(file_out), action='write', access='stream')
      write(41) 'v'
      write(41) i31
c
      fvar = 'oceSPtnd_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')

c Loop over nmonths
      do im=1,nmonths
         read(51,"(a)") file_dum
         if (im.ge.istart .and. im.le.iend) then

         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum3d   ! oceSPtnd read into dum3d
         close(53)

c Distribute 
         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            b3d_v(ic) = f3d_v(ic)*dum3d(i,j,k)*rac(i,j)/rho0
     $           * totv_inv

            sfrc(im) = sfrc(im) + b3d_v(ic)
         enddo

         write(41) b3d_v
         endif
      enddo  ! end loop over nmonths
      close(51)
      close(41)  ! end of penetrating salt flux forcing 

c .........................
c Output tendency 
      fname = 'sfrc'
      write(31) fname 
      write(31) sfrc

c ------------------------------------
c Close output 
      close(31)

      return
      end subroutine budg_salt 
c 
c ============================================================
c 
      subroutine budg_salinity(msk3d)

      use mysparse 
      integer nx, ny, nr
      parameter(nx=90, ny=1170, nr=50)
      parameter(nmonths=312, nyrs=26, yr1=1992, d2s=86400.)
     $                          ! max number of months of V4r4

c Mask  
      real*4 msk3d(nx,ny,nr), wmag, totv_inv, totv

c Mask in sparse mode
c target volume
      integer n3d_v
      real, allocatable :: f3d_v(:)
      integer, allocatable :: i3d_v(:)
      integer, allocatable :: j3d_v(:)
      integer, allocatable :: k3d_v(:)
      real, allocatable :: b3d_v(:)

c model arrays
      real*4 xc(nx,ny), yc(nx,ny), rc(nr), bathy(nx,ny), ibathy(nx,ny)
      common /grid/xc, yc, rc, bathy, ibathy

      real*4 rf(nr), drf(nr)
      real*4 hfacc(nx,ny,nr), hfacw(nx,ny,nr), hfacs(nx,ny,nr)
      real*4 dxg(nx,ny), dyg(nx,ny), dvol3d(nx,ny,nr), rac(nx,ny)
      integer kmt(nx,ny)
      common /grid2/rf, drf, hfacc, hfacw, hfacs,
     $     kmt, dxg, dyg, dvol3d, rac

c Common variables for all budgets
      real*4 etan(nx,ny,nmonths+1)  ! ETAN snapshot 
      real*4 dt(nmonths)
      common /budg_1/dt, etan

c Temporarly variables 
      real*4 dum2d(nx,ny), dum3d(nx,ny,nr)
      real*4 conv2d(nx,ny), dum3dy(nx,ny,nr)
      real*4 dum3dx(nx,ny,nr)
      real*4 salt(nx,ny,nr,2)
      integer iold, inew 

      real*4 s0(nx,ny), s1(nx,ny)
      character*256 f_file 
      character*256 f_command 

c Budget arrays 
      real*4 metan(nx,ny,nmonths) ! monthly mean ETAN
      real*4 msalt(nx,ny,nr)  ! monthly mean salinity

      real*4 lhs(nmonths)
      real*4 advh(nmonths), advv(nmonths)
      real*4 mixh(nmonths), mixv(nmonths)
      real*4 sfrc(nmonths)

c files
      character*256 f_inputdir   ! directory where tool files are 
      common /tool/f_inputdir
      character*256 file_in, file_out, file_dum, fvar, file_temp
      character*12  fname 
      character*256 file_rec(nmonths+1), file_temp2

      character*256 f_srcdir  ! directory where state output is 
      integer istart, iend  ! start and end month of budget
      integer ipar        ! parallel run ID
      character*256 fpar  ! string(ipar)
      common /source_dir/f_srcdir, istart, iend, ipar, fpar
      
c ------------------------------------
c Establish basic masks (volume only) in sparse mode
      wmag = 0.9

c Convert volume mask to sparse mode
      call sparse3d(msk3d,  wmag, 
     $     n3d_v, f3d_v, i3d_v, j3d_v, k3d_v, b3d_v)

      if (ipar.eq.1) then 
         file_dum = './emu_budg.msk3d_v' ! "v" for volume 
         open(41,file=trim(file_dum),access='stream')
         write(41) n3d_v
         write(41) f3d_v
         write(41) i3d_v, j3d_v, k3d_v
         close(41)
      endif

c total volume of target 
      totv = 0.
      dum2d(:,:) = 0.
      do k=1,nr
         dum2d(:,:) = dum2d(:,:) + msk3d(:,:,k)*dvol3d(:,:,k)
      enddo
      do i=1,nx
         do j=1,ny
            totv = totv + dum2d(i,j)
         enddo
      enddo

      totv_inv = 1./totv

c ------------------------------------
c Tendency output 

      ibud = 4                  ! indicates salinity budget 

      file_out = './emu_budg.sum_tend' // '_' // trim(fpar)
      open (31, file=trim(file_out), action='write', access='stream')
      write(31) ibud
      write(31) nmonths
      fname = 'dt'
      write(31) fname
      write(31) dt

c ------------------------------------
c Constants
      rho0 = 1029.   ! reference density 

c ------------------------------------
c Compute different terms 

c ------------------------------------
c Compute LHS (salinity tendency)
      fvar = 'SALT_mon_inst'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles+1 .ne. nmonths) then
         write(6,*) 'nfiles+1 ne nmonths: ',nfiles,nmonths
         stop
      endif

c Read and store SALT file names
c (Set 1st file as being the 1st and 2nd month)
c (Repeat last files as month nmonths & nmonths+1.)
      open (52, file=file_temp, action='read')
      do i=2,nmonths
         read(52,"(a)") file_rec(i)
      enddo
      close(52)
      file_rec(1)=file_rec(2)
      file_rec(nmonths+1)=file_rec(nmonths)

cc Output individual makeup of LHS 
c      file_out = './emu_budg.mkup_lhs' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
      i31 = 2
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Loop over months
      lhs(:) = 0.
      
c Read SALT at istart
      file_dum=file_rec(istart)
      open (53, file=trim(file_dum), action='read', access='stream')
      read (53) dum3d
      close(53)
      inew = 1
      iold = 3-inew 
      salt(:,:,:,inew) = dum3d    

      do im=istart,iend

c Read next SALT
         file_dum=file_rec(im+1)
         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum3d
         close(53)
         iold = inew
         inew = 3-iold
         salt(:,:,:,inew) = dum3d         

c Sum over target volume
         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            b3d_v(ic) = f3d_v(ic)*(salt(i,j,k,inew) -
     $           salt(i,j,k,iold))/dt(im) * dvol3d(i,j,k)
     $           * totv_inv  ! convert to value per volume 

            lhs(im) = lhs(im) + b3d_v(ic)
         enddo

cc Output makeup 
c         write(41) b3d_v

      enddo  ! End time loop till nmonths-1
c     close(41)

c Output tendency 
      fname = 'lhs'
      write(31) fname 
      write(31) lhs

c ------------------------------------
c Compute RHS tendencies 

c monthly mean ETAN that's needed 
      fvar = 'ETAN_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar)
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif

      open (59, file=trim(file_temp), action='read')

      imin = istart-1
      if (imin.lt.1) then imin=1
      imax = iend+1
      if (imax.gt.nfiles) then imax=nfiles

      do i=1,nfiles
         read(59,"(a)") file_dum
         if (i.ge.imin .and. i.le.imax) then
            open (53, file=file_dum, action='read', access='stream')
            read (53) dum2d
            metan(:,:,i) = dum2d
            close(53)
         endif
      enddo
      close(59)
      
c monthly mean SALINITY that's needed 
      fvar = 'state_3d_set1_mon'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '.*.data'
      file_temp = './do_budg.files_state' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar)
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (58, file=trim(file_temp), action='read')

c ------------------------------------
c Horizontal Advection 

c .........................
c ID horizontal advection files (SALT)
      fvar = 'ADVx_SLT_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar)
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')

      fvar = 'ADVy_SLT_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files_y' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (52, file=trim(file_temp), action='read')
c
      advh(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

cc Output individual makeup of advh (salt)
c      file_out = './emu_budg.mkup_advh_salt' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Loop over months
      do im=1,nmonths

c Read horizontal advection 
         read(51,"(a)") file_dum
         read(52,"(a)") file_temp
         if (im.ge.istart .and. im.le.iend) then

         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum3d
         close(53)

         open (53, file=trim(file_temp), action='read', access='stream')
         read (53) dum3dy
         close(53)

c Compute convergence of horizontal advection 
         dum3dx(:,:,:) = 0.
         do k=1,nr
            call native_uv_conv_smpl(dum3d(:,:,k),dum3dy(:,:,k), 
     $           dum3dx(:,:,k))
         enddo

         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            s0b = 1. + metan(i,j,im)*ibathy(i,j)
            b3d_v(ic) = f3d_v(ic)*dum3dx(i,j,k)/s0b
     $           * totv_inv
            
            advh(im) = advh(im) + b3d_v(ic)
         enddo

c         write(41) b3d_v
         endif
      enddo  ! end loop over nmonths
      close(51)
      close(52)
c      close(41)
         
c .........................
c Output tendency 
      fname = 'advh_slt'
      write(31) fname 
      write(31) advh

c .........................
c ID horizontal advection files (Volume)
      fvar = 'UVELMASS_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar)
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')

      fvar = 'VVELMASS_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files_y' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (52, file=trim(file_temp), action='read')

c
      advh(:) = 0.   ! reset advh for seperate sum 
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

cc Output individual makeup of advh (volume)
c      file_out = './emu_budg.mkup_advh_vol' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Loop over months
      rewind(58) 
      do im=1,nmonths
         read(58,"(a)") file_dum  ! monthly mean S
         read(51,"(a)") file_temp  ! horizontal advection 
         read(52,"(a)") file_temp2 ! horizontal advection 
         if (im.ge.istart .and. im.le.iend) then

c Read monthly mean S
         open (53, file=trim(file_dum), access='direct',
     $        form='unformatted', recl=nx*ny*nr*4)
         read(53,rec=2) msalt
         close(53)

c Read horizontal advection 
         open (53, file=trim(file_temp),
     $        action='read', access='stream')
         read (53) dum3d
         close(53)
         do k=1,nr
            dum3d(:,:,k) = dum3d(:,:,k)*dyg(:,:)
         enddo

         open (53, file=trim(file_temp2),
     $        action='read', access='stream')
         read (53) dum3dy
         close(53)
         do k=1,nr
            dum3dy(:,:,k) = dum3dy(:,:,k)*dxg(:,:)
         enddo

c Compute convergence of horizontal advection 
         dum3dx(:,:,:) = 0.
         do k=1,nr
            call native_uv_conv_smpl(dum3d(:,:,k),dum3dy(:,:,k), 
     $           dum3dx(:,:,k))
            dum3dx(:,:,k) = -dum3dx(:,:,k)*drf(k)*   ! flip sign
     $           msalt(:,:,k)
         enddo

         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            s0b = 1. + metan(i,j,im)*ibathy(i,j)
            b3d_v(ic) = f3d_v(ic)*dum3dx(i,j,k)/s0b
     $           * totv_inv
            
            advh(im) = advh(im) + b3d_v(ic)
         enddo

c         write(41) b3d_v
         endif 
      enddo  ! end loop over nmonths
      close(51)
      close(52)
c      close(41)

c Output tendency 
      fname = 'advh_vol'
      write(31) fname 
      write(31) advh

c ------------------------------------
c Horizontal Mixing 

c .........................
c ID horizontal mixing files (SALT)
      fvar = 'DFxE_SLT_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')

      fvar = 'DFyE_SLT_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files_y' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (52, file=trim(file_temp), action='read')
c
      mixh(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

cc Output individual makeup of mixh
c      file_out = './emu_budg.mkup_mixh' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Loop over months
      do im=1,nmonths

c Read horizontal mixing 
         read(51,"(a)") file_dum
         read(52,"(a)") file_temp
         if (im.ge.istart .and. im.le.iend) then

         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum3d
         close(53)

         open (53, file=trim(file_temp), action='read', access='stream')
         read (53) dum3dy
         close(53)

c Compute convergence of horizontal mixing 
         dum3dx(:,:,:) = 0.
         do k=1,nr
            call native_uv_conv_smpl(dum3d(:,:,k),dum3dy(:,:,k),
     $           dum3d(:,:,k))
         enddo

         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            s0b = 1. + metan(i,j,im)*ibathy(i,j)
            b3d_v(ic) = f3d_v(ic)*dum3d(i,j,k)/s0b
     $           * totv_inv
            
            mixh(im) = mixh(im) + b3d_v(ic)
         enddo

c         write(41) b3d_v
         endif
      enddo  ! end loop over nmonths
      close(51)
      close(52)
c      close(41)
            
c Output tendency 
      fname = 'mixh'
      write(31) fname 
      write(31) mixh

c ------------------------------------
c Vertical Advection 

c .........................
c ID vertical advection files (SALT)
      fvar = 'ADVr_SLT_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')
c
      advv(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

cc Output individual makeup of advv
c      file_out = './emu_budg.mkup_advv_salt' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Loop over months
      do im=1,nmonths

c Read vertical advection 
         read(51,"(a)") file_dum
         if (im.ge.istart .and. im.le.iend) then
         
         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum3d
         close(53)

c Compute convergence of vertical advection 
         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            s0b = 1. + metan(i,j,im)*ibathy(i,j)
            if (k.ne.nr) then 
               b3d_v(ic) = f3d_v(ic)*(dum3d(i,j,k+1)-dum3d(i,j,k))
            else
               b3d_v(ic) = f3d_v(ic)*(-dum3d(i,j,k))
            endif
            b3d_v(ic) = b3d_v(ic)
     $              /s0b * totv_inv
            
            advv(im) = advv(im) + b3d_v(ic)
         enddo

c         write(41) b3d_v
         endif
      enddo  ! end loop over nmonths
      close(51)
c      close(41)

c Output tendency 
      fname = 'advv_slt'
      write(31) fname 
      write(31) advv

c .........................
c ID vertical advection files (Volume)
      fvar = 'WVELMASS_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif

      open (51, file=trim(file_temp), action='read')

c 
      advv(:) = 0.   ! reset advv for seperate sum 
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

cc Output individual makeup of advv
c      file_out = './emu_budg.mkup_advv_vol' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c
      rewind(58) 
      do im=1,nmonths
         read(58,"(a)") file_dum
         read(51,"(a)") file_temp
         if (im.ge.istart .and. im.le.iend) then

c Read monthly mean S
         open (53, file=trim(file_dum), access='direct',
     $        form='unformatted', recl=nx*ny*nr*4)
         read(53,rec=2) msalt
         close(53)

c Read vertical advection 
         open (53, file=trim(file_temp),
     $        action='read', access='stream')
         read (53) dum3d
         close(53)

c Compute convergence of vertical advection 
         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            s0b = 1. + metan(i,j,im)*ibathy(i,j)

            if (k.eq.1) then 
               b3d_v(ic) = f3d_v(ic)*dum3d(i,j,k+1)
            elseif (k.eq.nr) then 
               b3d_v(ic) = f3d_v(ic)*(-dum3d(i,j,k))
            else
               b3d_v(ic) = f3d_v(ic)*(dum3d(i,j,k+1)-dum3d(i,j,k))
            endif
            b3d_v(ic) = -b3d_v(ic)   ! flip sign 
     $              *msalt(i,j,k)*rac(i,j)/s0b * totv_inv
            
            advv(im) = advv(im) + b3d_v(ic)
         enddo

c         write(41) b3d_v
         endif
      enddo  ! end loop over nmonths
      close(51)
c      close(41)

c Output tendency 
      fname = 'advv_vol'
      write(31) fname 
      write(31) advv 

c ------------------------------------
c Vertical Mixing 

c ID vertical implicit mixing files (SALT)
      fvar = 'DFrI_SLT_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')
c
      mixv(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

cc Output individual makeup of advv
c      file_out = './emu_budg.mkup_mix_z_i' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Loop over months
      do im=1,nmonths

c Read vertical implicit mixing 
         read(51,"(a)") file_dum
         if (im.ge.istart .and. im.le.iend) then
         
         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum3d
         close(53)

c Compute convergence of vertical mixing 
         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            s0b = 1. + metan(i,j,im)*ibathy(i,j)

            if (k.eq.nr) then 
               b3d_v(ic) = f3d_v(ic)*(-dum3d(i,j,k))
            else
               b3d_v(ic) = f3d_v(ic)*(dum3d(i,j,k+1)-dum3d(i,j,k))
            endif
            b3d_v(ic) = b3d_v(ic) 
     $              /s0b * totv_inv
            
            mixv(im) = mixv(im) + b3d_v(ic)
         enddo

c         write(41) b3d_v
         endif
      enddo  ! end loop over nmonths
      close(51)
c      close(41)

c .........................
c Vertical Explicit Mixing 

c ID vertical explicit mixing files (SALT)
      fvar = 'DFrE_SLT_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif

      open (51, file=trim(file_temp), action='read')

cc Output individual makeup of advv
c      file_out = './emu_budg.mkup_mix_z_e' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Loop over months
      do im=1,nmonths

c Read vertical advection 
         read(51,"(a)") file_dum
         if (im.ge.istart .and. im.le.iend) then
            
         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum3d
         close(53)

c Compute convergence of vertical mixing 
         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            s0b = 1. + metan(i,j,im)*ibathy(i,j)

            if (k.eq.nr) then 
               b3d_v(ic) = f3d_v(ic)*(-dum3d(i,j,k))
            else
               b3d_v(ic) = f3d_v(ic)*(dum3d(i,j,k+1)-dum3d(i,j,k))
            endif
            b3d_v(ic) = b3d_v(ic) 
     $              /s0b * totv_inv
            
            mixv(im) = mixv(im) + b3d_v(ic)
         enddo

c         write(41) b3d_v
          endif
      enddo  ! end loop over nmonths
      close(51)
c      close(41)

c Output tendency 
      fname = 'mixv'
      write(31) fname 
      write(31) mixv 

c ------------------------------------
c Forcing 

c ------------------------------------
c SFLUX & oceSPtnd files (SALT)

      fvar = 'SFLUX_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')
      
      fvar = 'oceSPtnd_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files_y' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (52, file=trim(file_temp), action='read')
c
      sfrc(:) = 0.
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

cc Output individual makeup of advv
c      file_out = './emu_budg.mkup_frc_salt' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Loop over months
      do im=1,nmonths
         read(51,"(a)") file_dum
         read(52,"(a)") file_temp
         if (im.ge.istart .and. im.le.iend) then

c Read SFLUX & oceSPtnd
         open (53, file=trim(file_dum), action='read', access='stream')
         read (53) dum2d   ! SFLUX read into dum2d 
         close(53)

         open (53, file=trim(file_temp), action='read', access='stream')
         read (53) dum3d   ! oceSPtnd read into dum3d
         close(53)

c Compute forcing 
         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            s0b = 1. + metan(i,j,im)*ibathy(i,j)

            if (k.eq.1) then 
               b3d_v(ic) = f3d_v(ic)*(dum2d(i,j) + dum3d(i,j,k))
            else
               b3d_v(ic) = f3d_v(ic)*dum3d(i,j,k)
            endif
            b3d_v(ic) = b3d_v(ic) 
     $              *rac(i,j) /rho0 /s0b * totv_inv
            
            sfrc(im) = sfrc(im) + b3d_v(ic)
         enddo

c         write(41) b3d_v
         endif
      enddo  ! end loop over nmonths
      close(51)
      close(52)
c      close(41)

c Output tendency 
      fname = 'sfrc_slt'
      write(31) fname 
      write(31) sfrc 

c .........................
c oceFWflx files 

      fvar = 'oceFWflx_mon_mean'
      file_in = trim(f_srcdir) // '/' //
     $     trim(fvar) // '/' // trim(fvar) // '.*.data'
      file_temp = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_temp,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(fvar) 
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (51, file=trim(file_temp), action='read')
c      
      sfrc(:) = 0.   ! reset sfrc for seperate sum 
      i31 = i31 + 1  ! corresponding array in emu_budg.sum_trend 

cc Output individual makeup of advv
c      file_out = './emu_budg.mkup_frc_vol' // '_' // trim(fpar)
c      open (41, file=trim(file_out), action='write', access='stream')
c      write(41) 'v'  ! mask
c      write(41) i31    ! corresponding array in emu_budg.sum_trend

c Loop over months
      rewind(58) 
      do im=1,nmonths
         read(58,"(a)") file_dum
         read(51,"(a)") file_temp
         if (im.ge.istart .and. im.le.iend) then

c Read monthly mean S
         open (53, file=trim(file_dum), access='direct',
     $        form='unformatted', recl=nx*ny*nr*4)
         read(53,rec=2) msalt
         close(53)

c
         open (53, file=trim(file_temp), action='read', access='stream')
         read (53) dum2d   ! oceFWflx read into dum2d
         close(53)

c Compute forcing 
         b3d_v(:) = 0.
         do ic=1,n3d_v
            i=i3d_v(ic)
            j=j3d_v(ic)
            k=k3d_v(ic)

            s0b = 1. + metan(i,j,im)*ibathy(i,j)

            if (k.eq.1) then 
               b3d_v(ic) = f3d_v(ic)*dum2d(i,j)*msalt(i,j,k)
            else
               b3d_v(ic) = 0.
            endif
            b3d_v(ic) = -b3d_v(ic)  ! flip sign
     $              *rac(i,j) /rho0 /s0b * totv_inv
            
            sfrc(im) = sfrc(im) + b3d_v(ic)
         enddo

c         write(41) b3d_v
         endif
      enddo  ! end loop over nmonths
      close(51)
c      close(41)

c Output tendency 
      fname = 'sfrc_vol'
      write(31) fname 
      write(31) sfrc 

c ------------------------------------
c Close files
      close(31)
      close(58)

      return
      end subroutine budg_salinity 
c 
c ============================================================
c 
      subroutine native_uv_conv_smpl(fx, fy, conv)
c Compute simple 2d horizontal convolution (no metric weights applied) 
      
c model arrays
      integer nx, ny, nr
      parameter (nx=90, ny=1170, nr=50)

      real*4 fx(nx,ny), fy(nx,ny)

      real*4 conv(nx,ny)

c gcmfaces versions
      real*4 u1(nx,3*nx), u2(nx,3*nx), u3(nx,nx)
      real*4 u4(3*nx,nx), u5(3*nx,nx)

      real*4 v1(nx,3*nx), v2(nx,3*nx), v3(nx,nx)
      real*4 v4(3*nx,nx), v5(3*nx,nx)

      real*4 c1(nx,3*nx), c2(nx,3*nx), c3(nx,nx)
      real*4 c4(3*nx,nx), c5(3*nx,nx)

c ------------------------------------
c Convert fx & fy to gcmfaces 
      call convert2gcmfaces(fx, u1,u2,u3,u4,u5)
      call convert2gcmfaces(fy, v1,v2,v3,v4,v5)

c Compute convergence
      call calc_uv_conv_smpl(u1,u2,u3,u4,u5, v1,v2,v3,v4,v5,
     $     c1,c2,c3,c4,c5)

c Convert to native
      call convert4gcmfaces(conv, c1,c2,c3,c4,c5)

      return
      end subroutine native_uv_conv_smpl
c 
c ============================================================
c 
      subroutine calc_uv_conv_smpl(u1,u2,u3,u4,u5, v1,v2,v3,v4,v5,
     $     c1,c2,c3,c4,c5)
c Compute SIMPLE horizontal convergence
c No metric terms applied

      integer nx, ny, nr
      parameter (nx=90, ny=1170, nr=50)

c gcmfaces version
      real*4 u1(nx,3*nx), u2(nx,3*nx), u3(nx,nx)
      real*4 u4(3*nx,nx), u5(3*nx,nx)

      real*4 v1(nx,3*nx), v2(nx,3*nx), v3(nx,nx)
      real*4 v4(3*nx,nx), v5(3*nx,nx)

      real*4 c1(nx,3*nx), c2(nx,3*nx), c3(nx,nx)
      real*4 c4(3*nx,nx), c5(3*nx,nx)

c gcmfaces with halos 
      real*4 u1h(nx+2,3*nx+2), u2h(nx+2,3*nx+2)
      real*4 u3h(nx+2,nx+2)
      real*4 u4h(3*nx+2,nx+2), u5h(3*nx+2,nx+2)

      real*4 v1h(nx+2,3*nx+2), v2h(nx+2,3*nx+2)
      real*4 v3h(nx+2,nx+2)
      real*4 v4h(3*nx+2,nx+2), v5h(3*nx+2,nx+2)

c ------------------------------------

c Convert uv gcmfaces with halos 
      call exch_uv_llc(u1,u2,u3,u4,u5, v1,v2,v3,v4,v5,
     $     u1h,u2h,u3h,u4h,u5h, v1h,v2h,v3h,v4h,v5h)

c Convergence
      c1(:,:) = u1h(2:nx+1,2:3*nx+1) - u1h(3:nx+2,2:3*nx+1)
     $        + v1h(2:nx+1,2:3*nx+1) - v1h(2:nx+1,3:3*nx+2)

      c2(:,:) = u2h(2:nx+1,2:3*nx+1) - u2h(3:nx+2,2:3*nx+1)
     $        + v2h(2:nx+1,2:3*nx+1) - v2h(2:nx+1,3:3*nx+2)


      c3(:,:) = u3h(2:nx+1,2:nx+1) - u3h(3:nx+2,2:nx+1)
     $        + v3h(2:nx+1,2:nx+1) - v3h(2:nx+1,3:nx+2)


      c4(:,:) = u4h(2:3*nx+1,2:nx+1) - u4h(3:3*nx+2,2:nx+1)
     $        + v4h(2:3*nx+1,2:nx+1) - v4h(2:3*nx+1,3:nx+2)

      c5(:,:) = u5h(2:3*nx+1,2:nx+1) - u5h(3:3*nx+2,2:nx+1)
     $        + v5h(2:3*nx+1,2:nx+1) - v5h(2:3*nx+1,3:nx+2)

      return
      end subroutine calc_uv_conv_smpl
c 
c ============================================================
c Subroutines for boundary fluxes 
c ============================================================
c 
      subroutine native_uv_conv_smpl_flx_msk(msk2d, msk2dx, msk2dy)

c Create masks (msk2dx, msk2dy) to extract horizontal convergent fluxes
c along boundary of region defined by mask msk2d. Global sum of
c resulting masked fluxes would equal convergence into masked region.
      
c model arrays
      integer nx, ny, nr
      parameter (nx=90, ny=1170, nr=50)

      real*4 msk2d(nx,ny)

      real*4 msk2dx(nx,ny), msk2dy(nx,ny)

c gcmfaces versions
      real*4 u1(nx,3*nx), u2(nx,3*nx), u3(nx,nx)
      real*4 u4(3*nx,nx), u5(3*nx,nx)

      real*4 v1(nx,3*nx), v2(nx,3*nx), v3(nx,nx)
      real*4 v4(3*nx,nx), v5(3*nx,nx)

      real*4 w1(nx,3*nx), w2(nx,3*nx), w3(nx,nx)
      real*4 w4(3*nx,nx), w5(3*nx,nx)

c gcmfaces with halos 
      real*4 u1h(nx+2,3*nx+2), u2h(nx+2,3*nx+2)
      real*4 u3h(nx+2,nx+2)
      real*4 u4h(3*nx+2,nx+2), u5h(3*nx+2,nx+2)

      real*4 v1h(nx+2,3*nx+2), v2h(nx+2,3*nx+2)
      real*4 v3h(nx+2,nx+2)
      real*4 v4h(3*nx+2,nx+2), v5h(3*nx+2,nx+2)

c ------------------------------------
c Zero out gcmfaces version of fluxes 
      u1(:,:) = 0.
      u2(:,:) = 0.
      u3(:,:) = 0.
      u4(:,:) = 0.
      u5(:,:) = 0.
      
      v1(:,:) = 0.
      v2(:,:) = 0.
      v3(:,:) = 0.
      v4(:,:) = 0.
      v5(:,:) = 0.

c Convert uv gcmfaces with halos 
      call exch_uv_llc(u1,u2,u3,u4,u5, v1,v2,v3,v4,v5,
     $     u1h,u2h,u3h,u4h,u5h, v1h,v2h,v3h,v4h,v5h)

c Convert msk2d to gcmfaces
      call convert2gcmfaces(msk2d, w1,w2,w3,w4,w5)

c Convergence
      u1h(2:nx+1,2:3*nx+1) = u1h(2:nx+1,2:3*nx+1) + w1
      u1h(3:nx+2,2:3*nx+1) = u1h(3:nx+2,2:3*nx+1) - w1
      v1h(2:nx+1,2:3*nx+1) = v1h(2:nx+1,2:3*nx+1) + w1
      v1h(2:nx+1,3:3*nx+2) = v1h(2:nx+1,3:3*nx+2) - w1

      u2h(2:nx+1,2:3*nx+1) = u2h(2:nx+1,2:3*nx+1) + w2
      u2h(3:nx+2,2:3*nx+1) = u2h(3:nx+2,2:3*nx+1) - w2
      v2h(2:nx+1,2:3*nx+1) = v2h(2:nx+1,2:3*nx+1) + w2
      v2h(2:nx+1,3:3*nx+2) = v2h(2:nx+1,3:3*nx+2) - w2     

      u3h(2:nx+1,2:nx+1) = u3h(2:nx+1,2:nx+1) + w3
      u3h(3:nx+2,2:nx+1) = u3h(3:nx+2,2:nx+1) - w3
      v3h(2:nx+1,2:nx+1) = v3h(2:nx+1,2:nx+1) + w3
      v3h(2:nx+1,3:nx+2) = v3h(2:nx+1,3:nx+2) - w3

      u4h(2:3*nx+1,2:nx+1) = u4h(2:3*nx+1,2:nx+1) + w4
      u4h(3:3*nx+2,2:nx+1) = u4h(3:3*nx+2,2:nx+1) - w4
      v4h(2:3*nx+1,2:nx+1) = v4h(2:3*nx+1,2:nx+1) + w4
      v4h(2:3*nx+1,3:nx+2) = v4h(2:3*nx+1,3:nx+2) - w4

      u5h(2:3*nx+1,2:nx+1) = u5h(2:3*nx+1,2:nx+1) + w5
      u5h(3:3*nx+2,2:nx+1) = u5h(3:3*nx+2,2:nx+1) - w5
      v5h(2:3*nx+1,2:nx+1) = v5h(2:3*nx+1,2:nx+1) + w5
      v5h(2:3*nx+1,3:nx+2) = v5h(2:3*nx+1,3:nx+2) - w5

c Reflect halos back to range
      call adj_exch_uv_llc(u1,u2,u3,u4,u5, v1,v2,v3,v4,v5,
     $     u1h,u2h,u3h,u4h,u5h, v1h,v2h,v3h,v4h,v5h)
      
c Convert to native
      call convert4gcmfaces(msk2dx, u1,u2,u3,u4,u5)
      call convert4gcmfaces(msk2dy, v1,v2,v3,v4,v5)

      return
      end subroutine native_uv_conv_smpl_flx_msk
c 
c ============================================================
c 
      subroutine adj_exch_uv_llc(u1,u2,u3,u4,u5, v1,v2,v3,v4,v5,
     $     u1h,u2h,u3h,u4h,u5h, v1h,v2h,v3h,v4h,v5h)

c Adjoint of exch_uv_llc. 
c Reflect halos of vector field back to range.
c All arrays are gcmfaces arrays. 

      integer nx, ny, nr
      parameter (nx=90, ny=1170, nr=50)

c gcmfaces version
      real*4 u1(nx,3*nx), u2(nx,3*nx), u3(nx,nx)
      real*4 u4(3*nx,nx), u5(3*nx,nx)

      real*4 v1(nx,3*nx), v2(nx,3*nx), v3(nx,nx)
      real*4 v4(3*nx,nx), v5(3*nx,nx)

c gcmfaces with halos 
      real*4 u1h(nx+2,3*nx+2), u2h(nx+2,3*nx+2)
      real*4 u3h(nx+2,nx+2)
      real*4 u4h(3*nx+2,nx+2), u5h(3*nx+2,nx+2)

      real*4 v1h(nx+2,3*nx+2), v2h(nx+2,3*nx+2)
      real*4 v3h(nx+2,nx+2)
      real*4 v4h(3*nx+2,nx+2), v5h(3*nx+2,nx+2)

c Temporary storage of just halos 
      real*4 u1hx(2,3*nx+2), u1hy(nx+2,2)
      real*4 u2hx(2,3*nx+2), u2hy(nx+2,2)
      real*4 u3hx(2,nx+2),   u3hy(nx+2,2)
      real*4 u4hx(2,nx+2),   u4hy(3*nx+2,2)
      real*4 u5hx(2,nx+2),   u5hy(3*nx+2,2)

      real*4 v1hx(2,3*nx+2), v1hy(nx+2,2)
      real*4 v2hx(2,3*nx+2), v2hy(nx+2,2)
      real*4 v3hx(2,nx+2),   v3hy(nx+2,2)
      real*4 v4hx(2,nx+2),   v4hy(3*nx+2,2)
      real*4 v5hx(2,nx+2),   v5hy(3*nx+2,2)

c ------------------------------------

c Initialize temporary storage 
      u1hx(:,:) = 0.
      u1hy(:,:) = 0.
      u2hx(:,:) = 0.
      u2hy(:,:) = 0.
      u3hx(:,:) = 0.
      u3hy(:,:) = 0.
      u4hx(:,:) = 0.
      u4hy(:,:) = 0.
      u5hx(:,:) = 0.
      u5hy(:,:) = 0.

      v1hx(:,:) = 0.
      v1hy(:,:) = 0.
      v2hx(:,:) = 0.
      v2hy(:,:) = 0.
      v3hx(:,:) = 0.
      v3hy(:,:) = 0.
      v4hx(:,:) = 0.
      v4hy(:,:) = 0.
      v5hx(:,:) = 0.
      v5hy(:,:) = 0.

c Save halos in temporary array, with directional adjustment 
c for exchange
      v1hx(1,:) =  + u1h(1,:)  ! u1 exchanged as v1 for face 5
      u1hx(2,:) =  + u1h(nx+2,:)
      v1hy(:,2) =  - u1h(:,3*nx+2)

      u1hx(1,:) =  - v1h(1,:)  ! -v1 exchanged as u1 for face 5 
      v1hx(2,:) =  + v1h(nx+2,:)
      u1hy(:,2) =  + v1h(:,3*nx+2) 
c
      u2hx(1,:) =  + u2h(1,:)
      v2hx(2,:) =  + u2h(nx+2,:)
      u2hy(:,2) =  + u2h(:,3*nx+2)

      v2hx(1,:) =  + v2h(1,:)
      u2hx(2,:) =  - v2h(nx+2,:)
      v2hy(:,2) =  + v2h(:,3*nx+2)
c
      v3hx(1,:) =  + u3h(1,:)
      u3hx(2,:) =  + u3h(nx+2,:)
      u3hy(:,1) =  + u3h(:,1)
      v3hy(:,2) =  - u3h(:,nx+2)
   
      u3hx(1,:) =  - v3h(1,:)    
      v3hx(2,:) =  + v3h(nx+2,:)    
      v3hy(:,1) =  + v3h(:,1)    
      u3hy(:,2) =  + v3h(:,nx+2)    
c
      u4hx(1,:) =  + u4h(1,:)
      v4hy(:,1) =  - u4h(:,1)
      u4hy(:,2) =  + u4h(:,nx+2)

      v4hx(1,:) =  + v4h(1,:)
      u4hy(:,1) =  + v4h(:,1)
      v4hy(:,2) =  + v4h(:,nx+2)
c
      v5hx(1,:) =  + u5h(1,:)    
      u5hy(:,1) =  + u5h(:,1) 
      v5hy(:,2) =  - u5h(:,nx+2) 

      u5hx(1,:) =  - v5h(1,:)    
      v5hy(:,1) =  + v5h(:,1) 
      u5hy(:,2) =  + v5h(:,nx+2) 

c Correct vector halos for exchange, using temporarily saved fields
      u1h(1,:)      = u1hx(1,:) 
      u1h(nx+2,:)   = u1hx(2,:) 
      u1h(:,1)      = u1hy(:,1)
      u1h(:,3*nx+2) = u1hy(:,2) 

      u2h(1,:)      = u2hx(1,:)  
      u2h(nx+2,:)   = u2hx(2,:)
      u2h(:,1)      = u2hy(:,1)
      u2h(:,3*nx+2) = u2hy(:,2)

      u3h(1,:)    = u3hx(1,:)
      u3h(nx+2,:) = u3hx(2,:)
      u3h(:,1)    = u3hy(:,1)
      u3h(:,nx+2) = u3hy(:,2)

      u4h(1,:)      = u4hx(1,:)
      u4h(3*nx+2,:) = u4hx(2,:)
      u4h(:,1)      = u4hy(:,1)
      u4h(:,nx+2)   = u4hy(:,2)

      u5h(1,:)      = u5hx(1,:)
      u5h(3*nx+2,:) = u5hx(2,:)
      u5h(:,1)      = u5hy(:,1)
      u5h(:,nx+2)   = u5hy(:,2)
c 
      v1h(1,:)      = v1hx(1,:)
      v1h(nx+2,:)   = v1hx(2,:)
      v1h(:,1)      = v1hy(:,1)
      v1h(:,3*nx+2) = v1hy(:,2)

      v2h(1,:)      = v2hx(1,:)
      v2h(nx+2,:)   = v2hx(2,:)
      v2h(:,1)      = v2hy(:,1)
      v2h(:,3*nx+2) = v2hy(:,2)

      v3h(1,:)    = v3hx(1,:)
      v3h(nx+2,:) = v3hx(2,:)
      v3h(:,1)    = v3hy(:,1)
      v3h(:,nx+2) = v3hy(:,2)

      v4h(1,:)      = v4hx(1,:)
      v4h(3*nx+2,:) = v4hx(2,:)
      v4h(:,1)      = v4hy(:,1)
      v4h(:,nx+2)   = v4hy(:,2)

      v5h(1,:)      = v5hx(1,:)
      v5h(3*nx+2,:) = v5hx(2,:)
      v5h(:,1)      = v5hy(:,1)
      v5h(:,nx+2)   = v5hy(:,2)
      
c Reflect halo to values inside faces
c (adjoint of exch_t_n_llc)
      call adj_exch_t_n_llc(u1,u2,u3,u4,u5, u1h,u2h,u3h,u4h,u5h)
      call adj_exch_t_n_llc(v1,v2,v3,v4,v5, v1h,v2h,v3h,v4h,v5h)
      
      return
      end subroutine adj_exch_uv_llc
c 
c ============================================================
c 
      subroutine adj_exch_t_n_llc(c1,c2,c3,c4,c5,
     $     c1h,c2h,c3h,c4h,c5h)

c Adjoint of exch_t_n_llc.
c Add halo values to values inside faces.

      integer nx, ny, nr
      parameter (nx=90, ny=1170, nr=50)

c gcmfaces version
      real*4 c1(nx,3*nx), c2(nx,3*nx), c3(nx,nx)
      real*4 c4(3*nx,nx), c5(3*nx,nx)

c gcmfaces with halos 
      real*4 c1h(nx+2,3*nx+2), c2h(nx+2,3*nx+2)
      real*4 c3h(nx+2,nx+2)
      real*4 c4h(3*nx+2,nx+2), c5h(3*nx+2,nx+2)

c ------------------------------------

c First fill interior (non-halo)
      c1(:,:) = c1h(2:nx+1,2:3*nx+1) 
      c2(:,:) = c2h(2:nx+1,2:3*nx+1)
      c3(:,:) = c3h(2:nx+1,2:nx+1)  
      c4(:,:) = c4h(2:3*nx+1,2:nx+1)
      c5(:,:) = c5h(2:3*nx+1,2:nx+1)

c Add from halo
      do j=1,3*nx
         c5(3*nx+1-j,nx) = c5(3*nx+1-j,nx) + c1h(1,j+1) 
         c2(1,j) = c2(1,j) + c1h(nx+2,j+1) 

         c1(nx,j) = c1(nx,j) + c2h(1,j+1) 
         c4(3*nx+1-j,1) = c4(3*nx+1-j,1) + c2h(nx+2,j+1) 

         c2(nx,3*nx+1-j) = c2(nx,3*nx+1-j) + c4h(j+1,1) 
         c5(j,1) = c5(j,1) + c4h(j+1,nx+2) 

         c4(j,nx) = c4(j,nx) + c5h(j+1,1) 
         c1(1,3*nx+1-j) = c1(1,3*nx+1-j) + c5h(j+1,nx+2) 
      enddo

      do i=1,nx
         c3(1,nx+1-i) = c3(1,nx+1-i) + c1h(i+1,3*nx+2) 
         c3(i,1) = c3(i,1) + c2h(i+1,3*nx+2) 
         c3(nx,i) = c3(nx,i) + c4h(1,i+1) 
         c3(nx+1-i,nx) = c3(nx+1-i,nx) + c5h(1,i+1) 

         c1(nx+1-i,3*nx) = c1(nx+1-i,3*nx) + c3h(1,i+1) 
         c2(i,3*nx) = c2(i,3*nx) + c3h(i+1,1)
         c4(1,i) = c4(1,i) + c3h(nx+2,i+1)
         c5(1,nx+1-i) = c5(1,nx+1-i) + c3h(i+1,nx+2)
      enddo

      return
      end subroutine adj_exch_t_n_llc
c 
c ============================================================
c 
      subroutine native_w_conv_smpl_flx_msk(msk3d, msk3dz)

c Create mask (msk3dz) to extract vertical convergent fluxes
c along boundary of region defined by mask msk3d. Global sum of
c resulting masked fluxes would equal convergence into masked region.
      
c model arrays
      integer nx, ny, nr
      parameter (nx=90, ny=1170, nr=50)

      real*4 msk3d(nx,ny,nr)

      real*4 msk3dz(nx,ny,nr)

c ------------------------------------

      do k=1,nr-1
         msk3dz(:,:,k)   = msk3dz(:,:,k)   - msk3d(:,:,k)
         msk3dz(:,:,k+1) = msk3dz(:,:,k+1) + msk3d(:,:,k)
      enddo
      msk3dz(:,:,nr)   = msk3dz(:,:,nr)   - msk3d(:,:,nr)

      return
      end subroutine native_w_conv_smpl_flx_msk
c 
c ============================================================
c 
      subroutine budg_smpl(fin, totv_inv, 
     $     n3d, f3d, i3d, j3d, k3d, b3d, fmsk, i31, 
     $     budg, fout)

c Simple flux convergence computation 
c 
c Read 3d flux time-series from file "fin" 
c Extracts fluxes using mask in sparse storage mode (sparse3d) 
c Output extracted fluxes to file "fout"
c Adds volume sum to budget term "budg"
      
c model arrays
      integer nx, ny, nr
      parameter (nx=90, ny=1170, nr=50)

      parameter(nmonths=312, nyrs=26, yr1=1992, d2s=86400.)

      character*256 fin, fout

      real*4 totv_inv

      integer n3d
      real*4 f3d(n3d), b3d(n3d)
      integer i3d(n3d), j3d(n3d), k3d(n3d)
      character fmsk
      integer i31 ! array index in emu_budg.sum

      real*4 budg(nmonths) 

c 
      character*256 f_inputdir   ! directory where tool files are 
      common /tool/f_inputdir
      character*256 file_in, file_out, file_dum, fvar  ! file names 

      character*256 f_srcdir  ! directory where state output is 
      integer istart, iend  ! start and end month of budget
      integer ipar        ! parallel run ID
      character*256 fpar  ! string(ipar)
      common /source_dir/f_srcdir, istart, iend, ipar, fpar

      real*4 dum3d(nx,ny,nr)

c ------------------------------------
c ID flux files 
      file_in = trim(f_srcdir) // '/' //
     $     trim(fin) // '/' // trim(fin) // '.*.data'
      file_out = './do_budg.files' // '_' // trim(fpar)
      call file_search(file_in,file_out,nfiles)
      if (nfiles .ne. nmonths) then
         write(6,*) trim(file_in)
         write(6,*) 'nfiles ne nmonths: ',nfiles,nmonths
         stop
      endif
      open (71, file=trim(file_out), action='read')

c boundary flux output
      open (72, file=trim(fout), action='write', access='stream')
      write(72) fmsk 
      write(72) i31 

      do im=1,nmonths
c Read flux
         read(71,"(a)") file_dum
         if (im.ge.istart .and. im.le.iend) then
         open (73, file=trim(file_dum), action='read', access='stream')
         read (73) dum3d
         close(73)

c Compute convergence of horizontal advection 
         do i=1,n3d
            b3d(i) = f3d(i) *
     $           dum3d(i3d(i),j3d(i),k3d(i))
     $           * totv_inv 
            budg(im) = budg(im) + b3d(i)
         enddo

         write(72) b3d
         endif
      enddo

      close(71)
      close(72)

      return
      end subroutine budg_smpl
c 
c ============================================================
c 
      subroutine wrt_tint(budg, fname, dt, fid)
c Integrate tendency in time and output to file 
      parameter(nmonths=312, nyrs=26, yr1=1992, d2s=86400.)
      
      real*4 budg(nmonths), dt(nmonths)
      character*12  fname 
      integer fid

      real*4 tint(nmonths), tdum 

c ------------------------------------
c Integrate in time 
      tint(:) = 0.
      tint(1) = budg(1) *dt(1)
      do im=2,nmonths
         tint(im)  = tint(im-1)  + budg(im)*dt(im)
      enddo

c Reset time-integral reference to im=2
      tdum = tint(2)
      tint(:) = tint(:) - tdum

c Output 
      write(fid) fname
      write(fid) tint 

      return
      end subroutine wrt_tint
