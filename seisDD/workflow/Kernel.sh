#!/bin/bash

ulimit -s unlimited

source parameter
export user=$(whoami)

if [ $system == 'slurm' ]; then
    # Submit directory
    export SUBMIT_DIR=$SLURM_SUBMIT_DIR
    echo "$SLURM_JOB_NODELIST"  >  ./job_info/NodeList
    echo "$SLURM_JOBID"  >  ./job_info/JobID
elif [ $system == 'pbs' ]; then
    # Submit directory
    export SUBMIT_DIR=$PBS_O_WORKDIR
    echo "$PBS_NODEFILE"  >  ./job_info/NodeList
    echo "$PBS_JOBID"  >  ./job_info/JobID
fi
cd $SUBMIT_DIR
#################### input parameters ###################################################
# directories
export SCRIPTS_DIR="$package_path/scripts" 
export SUBMIT_RESULT="$SUBMIT_DIR/RESULTS/$job/Scale${Wscale}_${measurement_list}_${misfit_type_list}"  # final results
if [ -z "$working_path" ]; then
    export working_path=$SUBMIT_DIR
fi
export WORKING_DIR="$working_path/$Job_title"  # directory on local nodes, where specfem runs

echo "Submit job << $Job_title >> in : $SUBMIT_DIR  "
echo "Working directory: $WORKING_DIR"
echo "FINAL results in :  $SUBMIT_RESULT"

#########################################################################################
STARTTIME=$(date +%s)
echo "start time is :  $(date +"%T")"

if $ReStart; then
    echo
    echo "Re-Starting job ..." 
    echo "Clean up result/working directories ..."
    rm -rf $SUBMIT_RESULT $WORKING_DIR
    mkdir -p $SUBMIT_RESULT $WORKING_DIR
else
    echo
    echo "Continue with current job ..."
fi 

echo 
echo "prepare data ..."
velocity_dir=$target_velocity_dir
if [ $system == 'slurm' ]; then
    srun -n $ntasks -c $NPROC_SPECFEM -l -W 0 $SCRIPTS_DIR/prepare_data.sh $velocity_dir 2> ./job_info/error_target
elif [ $system == 'pbs' ]; then 
    pbsdsh -n $ntasks -c $NPROC_SPECFEM -l -W 0 $SCRIPTS_DIR/prepare_data.sh $velocity_dir 2> ./job_info/error_target
fi

echo
echo "prepare starting model ..."
cp -r $initial_velocity_dir    $SUBMIT_RESULT/m_current

echo
echo "********************************************************************************************************"
echo "       Welcome job << $job >> " 
echo "       Scale: '$Wscale'; measurement: '${measurement_list}'; misfit_type: '${misfit_type_list}' " 
echo "********************************************************************************************************"

echo "Forward/Adjoint simulation for current model ...... "
velocity_dir=$SUBMIT_RESULT/m_current
compute_adjoint=true
if [ $system == 'slurm' ]; then
    srun -n $ntasks -c $NPROC_SPECFEM -l -W 0 $SCRIPTS_DIR/Adjoint.sh $velocity_dir $compute_adjoint 2> ./job_info/error_current
elif [ $system == 'pbs' ]; then
    pbsdsh -n $ntasks -c $NPROC_SPECFEM -l -W 0 $SCRIPTS_DIR/Adjoint.sh $velocity_dir $compute_adjoint 2> ./job_info/error_current
fi

echo
echo "sum data misfit ...... "
mkdir -p $SUBMIT_RESULT/data_misfit
step_length=0.0
iter=1
./bin/data_misfit.exe $iter $step_length $compute_adjoint $NPROC_SPECFEM $WORKING_DIR $SUBMIT_RESULT 2> ./job_info/error_sum_misfit

file=$SUBMIT_RESULT/data_misfit/search_status.dat
is_cont=$(awk -v "line=1" 'NR==line { print $1 }' $file)
is_done=$(awk -v "line=2" 'NR==line { print $1 }' $file)
is_brak=$(awk -v "line=3" 'NR==line { print $1 }' $file)
step_length=$(awk -v "line=4" 'NR==line { print $1 }' $file)
optimal_step_length=$(awk -v "line=5" 'NR==line { print $1 }' $file)
if [ $is_brak -eq 1 ]; then
    echo "stop due to small data misfit!"
    exit
else
    echo "continue to calculate misfit kernel!"
fi

echo 
echo "sum event kernel ...... "
mkdir -p $SUBMIT_RESULT/misfit_kernel
# prepare necessary files for kernel sum and smoothing
if [ $solver == 'specfem2D' ]; then
    cp -r $SUBMIT_RESULT/m_current/proc*_NSPEC_ibool.bin $SUBMIT_RESULT/misfit_kernel/
    cp -r $SUBMIT_RESULT/m_current/proc*_jacobian.bin $SUBMIT_RESULT/misfit_kernel/
    cp -r $SUBMIT_RESULT/m_current/proc*_x.bin $SUBMIT_RESULT/misfit_kernel/
    cp -r $SUBMIT_RESULT/m_current/proc*_z.bin $SUBMIT_RESULT/misfit_kernel/
elif [ $solver == 'specfem3D' ]; then
    rm -rf OUTPUT_FILES
    mkdir OUTPUT_FILES
    mkdir OUTPUT_FILES/DATABASES_MPI
    cp $SUBMIT_RESULT/misfit_kernel/proc*external_mesh.bin OUTPUT_FILES/DATABASES_MPI/
fi
mpirun -np $NPROC_SPECFEM ./bin/sum_kernel.exe $kernel_list,$precond_list $WORKING_DIR $SUBMIT_RESULT 2> ./job_info/error_sum_kernel

if $smooth ; then
    echo 
    echo "smooth misfit kernel ... "
    mpirun -np $NPROC_SPECFEM ./bin/xsmooth_sem $sigma_x $sigma_z $kernel_list,$precond_list $SUBMIT_RESULT/misfit_kernel/ $SUBMIT_RESULT/misfit_kernel/ $GPU_MODE 2> ./job_info/error_smooth_kernel
fi

echo
echo "******************finish all for scale $Wscale **************"

cp -r $SUBMIT_DIR/parameter $SUBMIT_RESULT/

echo
echo " clean up local nodes (wait) ...... "
if ! $DISPLAY_DETAILS ; then
    rm -rf $working_path/$Job_title
    rm -rf OUTPUT_FILES
fi

ENDTIME=$(date +%s)
Ttaken=$(($ENDTIME - $STARTTIME))
echo
echo "finish time is : $(date +"%T")" 
echo "RUNTIME is :  $(($Ttaken / 3600)) hours ::  $(($(($Ttaken%3600))/60)) minutes  :: $(($Ttaken % 60)) seconds."

echo
echo "******************well done*******************************"

cp -r $SUBMIT_DIR/job_info/output $SUBMIT_RESULT/
