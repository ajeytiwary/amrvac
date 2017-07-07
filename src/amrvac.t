!> AMRVAC solves a set of hyperbolic equations
!> \f$\vec{u}_t + \nabla_x \cdot \vec{f}(\vec{u}) = \vec{s}\f$
!> using adaptive mesh refinement.
program amrvac

  use mod_global_parameters
  use mod_input_output
  use mod_physics, only: phys_check_params
  use mod_usr_methods, only: usr_before_main_loop
  use mod_ghostcells_update
  use mod_usr
  use mod_initialize
  use mod_particles

  integer          :: itin
  double precision :: time0, time_in, tin

  call comm_start()

  time_advance = .false.
  time0        = MPI_WTIME()
  time_bc      = zero

  ! read command line arguments first
  call read_arguments()

  ! the user_init routine should load a physics module
  call usr_init()

  call initialize_amrvac()

  if (restart_from_file /= undefined) then
     ! restart from previous file or dat file conversion
     ! get input data from previous AMRVAC run
     itin=it
     tin=global_time

     {#IFDEF RAY
     call init_rays
     }

     ! read in dat file
     call read_snapshot()

     ! modify initial condition
     if (firstprocess) call modify_IC

     ! reset AMR grid
     if (resetgrid) call settree

     ! select active grids
     call selectgrids

     ! update ghost cells
     call getbc(global_time,0.d0,0,nwflux+nwaux)

     if(use_particles) then
       call read_particles_snapshot
       if(convert) then
         call handle_particles()
         call time_spent_on_particles()
         call comm_finalize
         stop
       end if
     end if

     if (convert) then
        if (npe/=1.and.(.not.(index(convert_type,'mpi')>=1)) &
             .and. convert_type .ne. 'user')  &
             call mpistop("non-mpi conversion only uses 1 cpu")
        call generate_plotfile
        call comm_finalize
        stop
     end if

     if (restart_reset_time) then
       ! reset it and global_time to original values
       it           = itin
       global_time  = tin
     end if

  else
     {#IFDEF RAY
     call init_rays
     }

     ! form and initialize all grids at level one
     call initlevelone

     ! select active grids
     call selectgrids

     ! update ghost cells
     call getbc(global_time,0.d0,0,nwflux+nwaux)

     ! set up and initialize finer level grids, if needed
     call settree

     if (use_particles) call particles_create()

  end if

  ! set up boundary flux conservation arrays
  if (levmax>levmin) call allocateBflux

  if (mype==0) then
     print*,'-------------------------------------------------------------------------------'
     write(*,'(a,f17.3,a)')' Startup phase took : ',MPI_WTIME()-time0,' sec'
     print*,'-------------------------------------------------------------------------------'
  end if

  ! an interface to allow user to do special things before the main loop
  if (associated(usr_before_main_loop)) &
       call usr_before_main_loop()

  time_advance=.true.

  ! do time integration of all grids on all levels
  call timeintegration()

  if (mype==0) then
     print*,'-------------------------------------------------------------------------------'
     write(*,'(a,f17.3,a)')' Finished AMRVAC in : ',MPI_WTIME()-time0,' sec'
     print*,'-------------------------------------------------------------------------------'
  end if

  time_advance=.false.

  call comm_finalize

contains

  subroutine timeintegration()
    use mod_timing
    use mod_advance, only: advance, process
    use mod_forest, only: nleafs_active
    use mod_global_parameters
    use mod_input_output, only: saveamrfile
    use mod_ghostcells_update

    integer :: level, ifile, fixcount, ncells_block, igrid, iigrid
    integer(kind=8) ncells_update
    logical :: save_now, crashall
    double precision :: time_last_print

    time_in=MPI_WTIME()
    time_last_print = -bigdouble
    fixcount=1

    n_saves(filelog_:fileout_) = snapshotini

    do ifile=nfile,1,-1
       tsavelast(ifile)=global_time
       itsavelast(ifile)=it
    end do

    itmin=it
    ! the next two are used to keep track of the performance during runtime:
    itTimeLast=it
    timeLast=MPI_WTIME()

    !  ------ start of integration loop. ------------------
    if (mype==0) then
      write(*, '(A,ES9.2,A)') ' Start integrating, print status every ', &
           time_between_print, ' seconds'
      write(*, '(A10,A12,A12,A12)') 'it', 'time', 'dt', 'wc-time(s)'
    end if

    timeloop0=MPI_WTIME()
    time_bc=0.d0
    ncells_block={(ixGhi^D-2*nghostcells)*}
    ncells_update=0
    time_evol : do
       call setdt()
       if(fixprocess) call process(it,global_time)

       timeio0=MPI_WTIME()

       if (timeio0 - time_last_print > time_between_print) then
         time_last_print = timeio0
         if (mype == 0) then
           write(*, '(I10,ES12.3,ES12.3,ES12.3)') it, global_time, dt, timeio0 - time_in
         end if
       end if

       do ifile=nfile,1,-1
         if(timetosave(ifile)) call saveamrfile(ifile)
       end do

       ! save a snapshot when a file name 'savenow' is present
       if (mype==0) inquire(file='savenow',exist=save_now)
       if (npe>1) call MPI_BCAST(save_now,1,MPI_LOGICAL,0,icomm,ierrmpi)

       if (save_now) then
          if(mype==0) write(*,'(a,i7,a,i7,a,es12.4)') ' save a snapshot No.',&
               snapshotnext,' at it=',it,' global_time=',global_time
          call saveamrfile(1)
          call saveamrfile(2)
          call MPI_FILE_DELETE('savenow',MPI_INFO_NULL,ierrmpi)
       endif
       timeio_tot=timeio_tot+(MPI_WTIME()-timeio0)

       ! exit time loop criteria
       if (it>=itmax) exit time_evol
       if (global_time>=time_max) exit time_evol

       call advance(it)

       ! if met unphysical values, save the last good status and crash the run
       call MPI_ALLREDUCE(crash,crashall,1,MPI_LOGICAL,MPI_LOR,icomm,ierrmpi)
       if (crashall) then
         do iigrid=1,igridstail; igrid=igrids(iigrid);
           pw(igrid)%w=pw(igrid)%wold
         end do
         call saveamrfile(1)
         call saveamrfile(2)
         call mpistop("Crash Error: small value encountered")
       end if

       ! resetting of tree BEFORE IO and setdt
       timegr0=MPI_WTIME()
       if(ditregrid>1) then
          if(fixcount<ditregrid) then
             fixcount=fixcount+1
          else
             if (refine_max_level>1 .and. .not.(fixgrid(0))) call resettree
             fixcount=1
          endif
       else
          if (refine_max_level>1 .and. .not.(fixgrid(0))) call resettree
       endif
       timegr_tot=timegr_tot+(MPI_WTIME()-timegr0)

       it = it + 1
       global_time = global_time + dt

       if(it>9000000)then
          it = slowsteps+10
          itmin=0
          itsavelast(:)=0
       end if
       ncells_update=ncells_update+ncells_block*nleafs_active
    end do time_evol

    timeloop=MPI_WTIME()-timeloop0

    if (mype==0) then
       write(*,'(a,f12.3,a)')' Total timeloop took        : ',timeloop,' sec'
       write(*,'(a,f12.3,a)')' Time spent on Regrid+Update: ',timegr_tot,' sec'
       write(*,'(a,f12.2,a)')'                  Percentage: ',100.0*timegr_tot/timeloop,' %'
       write(*,'(a,f12.3,a)')' Time spent on IO in loop   : ',timeio_tot,' sec'
       write(*,'(a,f12.2,a)')'                  Percentage: ',100.0*timeio_tot/timeloop,' %'
       write(*,'(a,f12.3,a)')' Time spent on BC           : ',time_bc,' sec'
       write(*,'(a,f12.2,a)')'                  Percentage: ',100.0*time_bc/timeloop,' %'
       write(*,'(a,f12.3,a)')' Time spent on run          : ',timeloop-timeio_tot,' sec'
       write(*,'(a,es12.3 )')' Cells_updated / cpu / sec  : ',dble(ncells_update)*dble(nstep)/dble(npe)/timeloop
    end if

    timeio0=MPI_WTIME()
    do ifile=nfile,1,-1
       if(itsavelast(ifile)<it)call saveamrfile(ifile)
    enddo
    if (mype==0) call MPI_FILE_CLOSE(log_fh,ierrmpi)
    timeio_tot=timeio_tot+(MPI_WTIME()-timeio0)


    if (mype==0) then
       write(*,'(a,f12.3,a)')' Total time spent on IO     : ',timeio_tot,' sec'
       write(*,'(a,f12.3,a)')' Total timeintegration took : ',MPI_WTIME()-time_in,' sec'
    end if

    {#IFDEF RAY
    call time_spent_on_rays
    }

    if(use_particles) call time_spent_on_particles

  end subroutine timeintegration

  !> Save times are defined by either tsave(isavet(ifile),ifile) or
  !> itsave(isaveit(ifile),ifile) or dtsave(ifile) or ditsave(ifile)
  !> Other conditions may be included.
  logical function timetosave(ifile)
    use mod_global_parameters

    integer:: ifile
    logical:: oksave
    !-----------------------------------------------------------------------------
    oksave=.false.
    if (it==itsave(isaveit(ifile),ifile)) then
       oksave=.true.
       isaveit(ifile)=isaveit(ifile)+1
    end if
    if (it==itsavelast(ifile)+ditsave(ifile)) oksave=.true.

    if (global_time>=tsave(isavet(ifile),ifile)) then
       oksave=.true.
       isavet(ifile)=isavet(ifile)+1
    end if
    if (global_time>=tsavelast(ifile)+dtsave(ifile)-smalldouble)then
       oksave=.true.
       n_saves(ifile) = n_saves(ifile) + 1
    endif

    if (oksave) then
       tsavelast(ifile) =global_time
       itsavelast(ifile)=it
    end if
    timetosave=oksave

    return
  end function timetosave

  !> Return true if the AMR grid should not be adapted any more. This is
  !> controlled by tfixgrid or itfixgrid. Other conditions may be included.
  !> @todo Fix dummy argument?
  logical function fixgrid(dummy)
    use mod_global_parameters
    integer :: dummy              !< Unused dummy argument

    fixgrid= (global_time>=tfixgrid .or. it>=itfixgrid)
  end function fixgrid

end program amrvac
