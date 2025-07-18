      program set_samp
c -----------------------------------------------------
c Program for Sampling Tool (V4r4)
c Set up data.ecco for sampling model output by do_samp.f. 
c     
c 19 February 2024, Ichiro Fukumori (fukumori@jpl.nasa.gov)
c -----------------------------------------------------
      external StripSpaces
c files
      character*256 f_statedir   ! directory with state
      common /tool/f_statedir
      character*130 file_in, file_out  ! file names 
c
      character*256 f_command
      logical f_exist
      character*6 f0, f1  ! For different OBJF variables 

c model arrays
      integer nx, ny, nr
      parameter (nx=90, ny=1170, nr=50)
      real*4 xc(nx,ny), yc(nx,ny), rc(nr), bathy(nx,ny), ibathy(nx,ny)
      common /grid/xc, yc, rc, bathy, ibathy

      real*4 rf(nr), drf(nr)
      real*4 hfacc(nx,ny,nr), hfacw(nx,ny,nr), hfacs(nx,ny,nr)
      real*4 dxg(nx,ny), dyg(nx,ny), dvol3d(nx,ny,nr), rac(nx,ny)
      integer kmt(nx,ny)
      common /grid2/rf, drf, hfacc, hfacw, hfacs,
     $     kmt, dxg, dyg, dvol3d, rac
      
c Objective function 
      integer nvar, mvar    ! number of OBJF variables 
      parameter (nvar=5)    
      character*72 f_var(nvar), f_unit(nvar)
      common /objfvar/f_var, f_unit

c Strings for naming output directory
      character*256 floc_time ! OBJF time-period
      character*256 floc_var  ! first variable defined as OBJF 
      character*256 floc_loc  ! location (mask) of first OBJF variable
      character*256 dir_out   ! output directory
      common /floc/floc_time, floc_var, floc_loc, dir_out

      character*256 dir_run   ! run directory
      character*256 fcwd      ! current working directory

      integer date_time(8)  ! arrrays for date 
      character*10 bb(3)
      character*256 fdate 
c 
      character*1 fmd ! Monthly or Daily time-series 

c OBJF 
      parameter(ndays=9497)
      real*4 objf(ndays)
      real*4 mobjf
      integer nrec

      parameter(nmonths=312) ! max number of months of V4r4
      real*4 tmask(nmonths)
      character*256 fmask

c --------------
c Read directory where emu_ref is (for grid info)
      call getarg(1,f_statedir)

c --------------
c Get model grid info
      call grid_info
      
c --------------
c Variable name
      f_var(1) = 'SSH'
      f_var(2) = 'OBP'   
      f_var(3) = 'THETA'    
      f_var(4) = 'SALT'     
      f_var(5) = 'UV'   

      f_unit(1) = '(m)'
      f_unit(2) = '(equivalent sea level m)'   
      f_unit(3) = '(deg C)'    
      f_unit(4) = '(PSU)'     
      f_unit(5) = '(m/s)'   

c --------------
c Interactive specification of perturbation 
      write (6,"(/,a)") 'Evaluating model time-series ... '
      write (6,"(/,a)") 'Define objective function (OBJF) ... '

c --------------
c Save OBJF information for reference. 
      file_out = 'set_samp.info'
      open (51, file=file_out, action='write')
      write(51,"(a)") '***********************'
      write(51,"(a)") 'Output of set_samp.f'
      write(51,"(a)")
     $     'Sampling objective function (OBJF) specification'
      write(51,"(a,/)") '***********************'

c --------------
c Monthly mean or daily mean 
      fmd = 'x'
      do while (fmd.ne.'m' .and. fmd.ne.'M' .and.
     $     fmd.ne.'d' .and. fmd.ne.'D') 

         write (6,"(/,3x,a)") 'Select Monthly or Daily mean ... (m/d)?'
         write (6,"(3x,a)")
     $        '(NOTE: daily mean available for SSH and OBP only.)'
         read(5,*) fmd

         if (fmd.ne.'m' .and. fmd.ne.'M' .and.
     $     fmd.ne.'d' .and. fmd.ne.'D') then
            write (6,"(3x,a)") 'Invalid choice ... '
         endif

      enddo

      write(6,"(/,3x,a,a)") 'fmd = ',fmd
      write(51,"(/,3x,a,a)") 'fmd = ',fmd
      
      if (fmd.eq.'d' .or. fmd.eq.'D') then 
         write(6,"(3x,a)") '==> Sampling daily means ... '
         write(51,"(3x,a)") '==> Sampling daily means ... '
         mvar = 2 
         floc_time = 'd'
         f_command = 'sed -i -e '//
     $        '"s|OBJF_PRD|day|g" data.ecco'
      else
         write(6,"(3x,a)") '==> Sampling MONTHLY means ... '
         write(51,"(3x,a)") '==> Sampling MONTHLY means ... '
         mvar = nvar
         floc_time = 'm'
         f_command = 'sed -i -e '//
     $        '"s|OBJF_PRD|month|g" data.ecco'
      endif
      call execute_command_line(f_command, wait=.true.)

c Create dummy temporal mask
      fmask='objf_mask_T'
      INQUIRE(FILE=trim(fmask), EXIST=f_exist)
      if (f_exist) then
         f_command = 'rm -f ' // trim(fmask)
         call execute_command_line(f_command, wait=.true.)
      endif
      open(60,file=fmask,form='unformatted',access='stream')
      write(60) tmask
      close(60)

c --------------
c Define OBJF's VARIABLE 
      write (6,"(/,a)") 'Available VARIABLES are ... '
      do i=1,mvar
         write (6,"(3x,i2,') ',a,1x,a)")
     $        i,trim(f_var(i)),trim(f_unit(i))
      enddo

c Loop among OBJF variables 
      nobjf = 0 ! number of OBJF variables 
      iobjf = 1
      write(f1,"(i1)") 1 
      call StripSpaces(f1)

      do while (iobjf .ge. 1 .and. iobjf .le. mvar) 

         write (6,"(/,a)") '------------------'
         write (6,"(3x,a,i1,a,i1,a,i1,a)")
     $     'Choose OBFJ variable (v in Eq 1 of Guide) # ',
     $        nobjf+1,' ... (1-',mvar,')?'
         write(6,"(3x,a)") '(Enter 0 to end variable selection)'

         read (5,*) iobjf

         if (iobjf.ge.1 .and. iobjf.le.mvar) then 
c Process OBJF variable 
         nobjf = nobjf + 1

         write(6,"(3x,a,i2,1x,a,a)") 'OBJF variable ',
     $        nobjf, 'is ',trim(f_var(iobjf))

         write(51,"(/,a)") '------------------'
         write(51,"(a,i2,a,a)") 'OBJF variable # ',nobjf
         write(51,"(3x,'iobjf = ',i2)") iobjf
         write(51,"(3x,a,a,1x,a/)") ' --> OBJF variable : ',
     $        trim(f_var(iobjf)),trim(f_unit(iobjf))

c Create data.ecco entries for new variable, if not the first
         if (nobjf .ne. 1) then 
            write(f0,"(i2)") nobjf-1
            write(f1,"(i2)") nobjf

            call StripSpaces(f0)
            call StripSpaces(f1)

c Duplicate entries for new variable in data.ecco 
c e.g., sed -e '/(1)/{p;s|(1)|(2)|}' data.ecco 
            f_command = 'sed -i -e '//
     $        '"/(' // trim(f0) // ')/{p;s|(' // trim(f0) //
     $         ')|(' // trim(f1) // ')|}" data.ecco'
            call execute_command_line(f_command, wait=.true.)
         else
            write(floc_var,"(i2)") iobjf
            call StripSpaces(floc_var)
         endif

c Define new OBJF variable 
         call objf_var(f1,iobjf,floc_loc)

         else if (nobjf .eq. 0) then
            write(6,*) 'Invalid selection ... '
            write(6,*) 'No variable selected ... TERMINATING'
            stop 1
         endif 

      end do  ! End defining OBJF 

      close (51)

c Create string for output directory
      write(f_command,1001) trim(floc_time),
     $     trim(floc_var), trim(floc_loc), nobjf
 1001 format(a,"_",a,"_",a,"_",i2)
      call StripSpaces(f_command)

      file_out = 'set_samp.out'
      open (52, file=file_out, action='write')
      write(52,"(a)") trim(f_command)
      close(52) 

      stop
      end program set_samp
      
