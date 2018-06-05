#!/usr/bin/env julia

using RobotOS
@rosimport barc.msg: ECU, pos_info, mpc_solution
@rosimport geometry_msgs.msg: Vector3
rostypegen()
using barc.msg
using geometry_msgs.msg
using JuMP
using Ipopt
using JLD

include("barc_lib/classes.jl")
include("barc_lib/LMPC/MPC_models.jl")
include("barc_lib/LMPC/functions.jl")
include("barc_lib/LMPC/solveMpcProblem.jl")
include("barc_lib/simModel.jl")

function SE_callback(msg::pos_info,lapStatus::LapStatus,posInfo::PosInfo)
    #=
    Inputs: 
        1. pos_info: ROS topic msg type
        2. lapStatus: user defined type from class.jl
        3. posInfo: user defined type from class.jl
    =#
    posInfo.s       = pos_info.s
    posInfo.ey      = pos_info.ey
    posInfo.epsi    = pos_info.epsi
    posInfo.v       = pos_info.v
    posInfo.x       = pos_info.x
    posInfo.y       = pos_info.y
    posInfo.vx      = pos_info.v_x
    posInfo.vy      = pos_info.v_y
    posInfo.psi     = pos_info.psi
    posInfo.psiDot  = pos_info.psiDot
    posInfo.ax      = pos_info.a_x
    posInfo.ay      = pos_info.a_y
    posInfo.a       = pos_info.u_a
    posInfo.df      = pos_info.u_df
    
    if posInfo.s <= lapStatus.s_lapTrigger && lapStatus.switchLap
        lapStatus.nextLap = true
        lapStatus.switchLap = false
    elseif posInfo.s > lapStatus.s_lapTrigger
        lapStatus.switchLap = true
    end
end

function main()
    println("Starting LMPC node.")
    const BUFFERSIZE       = 500
    const LMPC_LAP         = 30

    const PF_FLAG          = false  # true:only pF,     false:1 warm-up lap and LMPC
    const GP_LOCAL_FLAG    = false  # true:local GPR
    const GP_FULL_FLAG     = false  # true:full GPR
    
    const N                = get_param("controller/N")
    const delay_df         = get_param("controller/delay_df")
    const delay_a          = get_param("controller/delay_a")
    
    if PF_FLAG
        file_name = "PF"
    else
        if GP_LOCAL_FLAG
            file_name = "KIN_LOCAL_GP"
        elseif GP_FULL_FLAG
            file_name = "KIN_FULL_GP"
        end
    end
    if get_param("sim_flag")
        folder_name = "simulations"
    else
        folder_name = "experiments"
    end

    track_data       = createTrack("basic")
    track            = Track(track_data)
    lapStatus        = LapStatus(1,1,false,false,0.3)
    mpcSol           = MpcSol()
    modelParams      = ModelParams()
    mpcParams        = MpcParams()
    selectedStates   = SelectedStates()
    oldSS            = SafeSetData()
    posInfo          = PosInfo()

    mpcSol_to_pub    = mpc_solution()    # MPC SOLUTION PUBLISHING MESSAGE INITIALIZATION
    cmd              = ECU()             # CONTROL SIGNAL MESSAGE INITIALIZATION
    

    # NODE INITIALIZATION
    init_node("mpc_traj")
    loop_rate   = Rate(50.0)
    pub         = Publisher("ecu", ECU, queue_size=1)::RobotOS.Publisher{barc.msg.ECU}
    mpcSol_pub  = Publisher("mpc_solution", mpc_solution, queue_size=1)::RobotOS.Publisher{barc.msg.mpc_solution}
    s1          = Subscriber("pos_info", pos_info, SE_callback, (acc_f,lapStatus,mpcSol,oldTraj,z_est,x_est),queue_size=1)::RobotOS.Subscriber{barc.msg.pos_info}

    num_lap             = LMPC_LAP+1+max(selectedStates.Nl,selectedStates.feature_Nl)
    solHistory          = SolHistory(BUFFERSIZE,mpcParams.N,6,num_lap)
    selectHistory       = zeros(BUFFERSIZE,num_lap,selectedStates.Nl*selectedStates.Np,6)
    GP_vy_History       = zeros(BUFFERSIZE,num_lap,mpcParams.N)
    GP_psidot_History   = zeros(BUFFERSIZE,num_lap,mpcParams.N)
    statusHistory       = Array{ASCIIString}(BUFFERSIZE,num_lap)

    mdl_pF           = MpcModel_pF(mpcParams_pF,modelParams)
    mdl_kin          = MpcModel_convhull_kin(mpcParams_4s,modelParams,selectedStates)
    
    if !PF_FLAG
        # FUNCTION DUMMY CALLS: this is important to call all the functions that will be used before for initial compiling
        data = load("$(homedir())/simulations/dummy_function/oldSS.jld") # oldSS.jld is a dummy data for initialization
        oldSS_dummy = data["oldSS"]
        lapStatus_dummy = LapStatus(1+max(selectedStates.feature_Nl,selectedStates.Nl),1,false,false,0.3)
        selectedStates_dummy=find_SS(oldSS_dummy,selectedStates,5.2,z_prev,lapStatus_dummy,modelParams,mpcParams,track)
        z = rand(1,6); u = rand(1,2)
        selectedStates_dummy.selStates=s6_to_s4(selectedStates_dummy.selStates)
        (~,~,~)=solveMpcProblem_convhull_kin(mdl_kin,mpcSol,rand(4),rand(mpcParams.N+1,4),rand(mpcParams.N,2),selectedStates_dummy,track,rand(mpcParams.N),rand(mpcParams.N))
        (~,~,~)=find_SS_dist(solHistory,rand(1,6),rand(1,2),lapStatus,selectedStates)
    end

    if GP_LOCAL_FLAG || GP_FULL_FLAG
        # FEATURE DATA READING FOR GPR # THIS PART NEEDS TO BE COMMENTED OUT FOR THE FIRST TIME LMPC FOR GP DATA COLLECTING
        if PF_FLAG
            file_GP_name = "KIN"
        end
        if get_param("sim_flag")
	        data = load("$(homedir())/simulations/Feature_Data/FeatureData_GP-$(file_GP_name).jld")
	    else
	        data = load("$(homedir())/experiments/Feature_Data/FeatureData_GP-$(file_GP_name).jld")
	    end
        num_spare            = 30 # THE NUMBER OF POINTS SELECTED FOR SPARE GP
        feature_GP_z         = data["feature_GP_z"]
        feature_GP_u         = data["feature_GP_u"]
        feature_GP_vy_e      = data["feature_GP_vy_e"]
        feature_GP_psidot_e  = data["feature_GP_psidot_e"]
        feature_GP_z         = feature_GP_z[1:num_spare:end,:]
        feature_GP_u         = feature_GP_u[1:num_spare:end,:]
        feature_GP_vy_e      = feature_GP_vy_e[1:num_spare:end]
        feature_GP_psidot_e  = feature_GP_psidot_e[1:num_spare:end]

        GP_e_vy_prepare      = GP_prepare(feature_GP_vy_e,feature_GP_z,feature_GP_u)
        GP_e_psi_dot_prepare = GP_prepare(feature_GP_psidot_e,feature_GP_z,feature_GP_u)
        GP_feature           = hcat(feature_GP_z,feature_GP_u)

        GP_full_vy(rand(1,6),rand(1,2),GP_feature,GP_e_vy_prepare)
        GP_full_psidot(rand(1,6),rand(1,2),GP_feature,GP_e_vy_prepare)
    else # THIS IS FOR COLLECTING FEATURE DATA FOR GPR
        feature_GP_z         = zeros(10000,6)
        feature_GP_u         = zeros(10000,2)
        feature_GP_vy_e      = zeros(10000)
        feature_GP_psidot_e  = zeros(10000)
        k = 1
    end
    
    if PF_FLAG
        lapStatus.currentLap = 1
    else
        lapStatus.currentLap = 1+max(selectedStates.feature_Nl,selectedStates.Nl)
        if get_param("sim_flag")
            data  = load("$(homedir())/simulations/path_following.jld")
        else
            data  = load("$(homedir())/experiments/path_following.jld")
        end
        oldSS = data["oldSS"]
        solHistory = data["solHistory"]
    end

    counter = 0
    while ! is_shutdown()
        if z_est[6] > 0    
            # LAP SWITCHING
            if lapStatus.nextLap
                println("Finishing one lap at iteration ",lapStatus.currentIt)
                if PF_FLAG || (!PF_FLAG && lapStatus.currentLap > 1+max(selectedStates.feature_Nl,selectedStates.Nl)) 
                    # IN CONSISTANT WITH THE DATA SAVING PART: AVOIDING SAVING THE DATA FOR THE FIRST WARM UP LAP IN LMPC
                    # SAFE SET COST UPDATE
                    oldSS.oldCost[lapStatus.currentLap]     = lapStatus.currentIt-1
                    solHistory.cost[lapStatus.currentLap]   = lapStatus.currentIt-1
                    oldSS.cost2target[:,lapStatus.currentLap] = lapStatus.currentIt - oldSS.cost2target[:,lapStatus.currentLap]
                end 

                lapStatus.nextLap = false

                setvalue(mdl_pF.z_Ol[1:mpcParams.N,1],mpcSol.z[2:mpcParams.N+1,1]-track.s)
                setvalue(mdl_pF.z_Ol[mpcParams.N+1,1],mpcSol.z[mpcParams.N+1,1]-track.s)
                setvalue(mdl_convhull.z_Ol[1:mpcParams.N,1],mpcSol.z[2:mpcParams.N+1,1]-track.s)
                setvalue(mdl_convhull.z_Ol[mpcParams.N+1,1],mpcSol.z[mpcParams.N+1,1]-track.s)

                if z_prev[1,1]>track.s
                    z_prev[:,1] -= track.s
                end

                lapStatus.currentLap += 1
                lapStatus.currentIt = 1

                if GP_FULL_FLAG && GP_HISTORY_FLAG # USING DATA FROM PREVIOUS LAPS TO DO FULL GPR
                    # CONSTRUCT GP_related from solHistory
                    GP_e_vy_prepare      = GP_prepare(feature_GP_vy_e,feature_GP_z,feature_GP_u)
                    GP_e_psi_dot_prepare = GP_prepare(feature_GP_psidot_e,feature_GP_z,feature_GP_u)
                    GP_feature           = hcat(feature_GP_z,feature_GP_u)
                end # THIS PART IS STILL NOT READY

                if lapStatus.currentLap > num_lap # to save the data at the end before error pops up
                    # DATA SAVING
                    run_time = Dates.format(now(),"yyyy-mm-dd-H:M")
                    log_path = "$(homedir())/$(folder_name)/LMPC-$(file_name)-$(run_time).jld"
                    save(log_path,"log_cvx",log_cvx,"log_cvy",log_cvy,"log_cpsi",log_cpsi,"GP_vy_History",GP_vy_History,"GP_psidot_History",GP_psidot_History,
				                  "oldTraj",oldTraj,"selectedStates",selectedStates,"oldSS",oldSS,"solHistory",solHistory,
				                  "selectHistory",selectHistory,"selectFeatureHistory",selectFeatureHistory,"statusHistory",statusHistory,
				                  "track",track,"modelParams",modelParams,"mpcParams",mpcParams)
                    # COLLECT ONE STEP PREDICTION ERROR FOR GPR
                    if !GP_LOCAL_FLAG && !GP_FULL_FLAG
                        run_time = Dates.format(now(),"yyyy-mm-dd-H:M")
                        if get_param("sim_flag")
                        	log_path = "$(homedir())/simulations/Feature_Data/FeatureData_GP-$(file_name).jld"
                        else
                        	log_path = "$(homedir())/experiments/Feature_Data/FeatureData_GP-$(file_name).jld"
                        end
                        feature_GP_z        = feature_GP_z[1:k-1,:]
				        feature_GP_u        = feature_GP_u[1:k-1,:]
				        feature_GP_vy_e     = feature_GP_vy_e[1:k-1]
				        feature_GP_psidot_e = feature_GP_psidot_e[1:k-1]
                        save(log_path,"feature_GP_z",feature_GP_z,"feature_GP_u",feature_GP_u,"feature_GP_vy_e",feature_GP_vy_e,"feature_GP_psidot_e",feature_GP_psidot_e) 
                    end
                end
            end

            # MPC CONTROLLER OPTIMIZATION
            if lapStatus.currentLap<=1+max(selectedStates.feature_Nl,selectedStates.Nl) # pF CONTROLLER
                # (xDot, yDot, psiDot, ePsi, eY, s, acc_f)
                z_curr = [z_est[6],z_est[5],z_est[4],z_est[1],z_est[2],z_est[3]]
                z_kin = [z_est[6],z_est[5],z_est[4],sqrt(z_est[1]^2+z_est[2]^2)]
                (mpcSol.z,mpcSol.u,sol_status) = solveMpcProblem_pathFollow(mdl_pF,mpcParams_pF,modelParams,mpcSol,z_kin,z_prev,u_prev,track)
            else # LMPC CONTROLLER
                # FOR QUICK LMPC STARTING, the next time, change the path following lap number to 1 and change the initial lapStatus to selectedStates.
                if PF_FLAG
                    if get_param("sim_flag")
                    	save("$(homedir())/simulations/path_following.jld","oldSS",oldSS,"solHistory",solHistory)
				    else
                    	save("$(homedir())/experiments/path_following.jld","oldSS",oldSS,"solHistory",solHistory)
				    end
                end
                
                # (xDot, yDot, psiDot, ePsi, eY, s, acc_f)
                z_curr = [z_est[6],z_est[5],z_est[4],z_est[1],z_est[2],z_est[3]]
                if LMPC_KIN_FLAG
                    tic()
                	z_curr = [z_est[6],z_est[5],z_est[4],z_est[1],z_est[2],z_est[3]]
	                z_kin = [z_est[6],z_est[5],z_est[4],sqrt(z_est[1]^2+z_est[2]^2)]
	                GP_e_vy     = zeros(mpcParams.N)
                    GP_e_psidot = zeros(mpcParams.N)
                    z_to_iden = vcat(z_kin',z_prev[3:end,:])
                    u_to_iden = vcat(u_prev[2:end,:],u_prev[end,:])
                    for i = 1:mpcParams.N
                        if GP_LOCAL_FLAG
                            GP_e_vy[i]      = regre(z_to_iden[i,:],u_to_iden[i,:],feature_GP_vy_e,feature_GP_z,feature_GP_u)
                            GP_e_psidot[i]  = regre(z_to_iden[i,:],u_to_iden[i,:],feature_GP_vy_e,feature_GP_z,feature_GP_u)
                        elseif GP_FULL_FLAG
                            GP_e_vy[i]      = GP_full_vy(z_to_iden[i,:],u_to_iden[i,:],GP_feature,GP_e_vy_prepare)
                            GP_e_psidot[i]  = GP_full_psidot(z_to_iden[i,:],u_to_iden[i,:],GP_feature,GP_e_psi_dot_prepare)
                        else
                            GP_e_vy[i]      = 0
                            GP_e_psidot[i]  = 0
                        end
                    end
                    # SAFESET SELECTION
                    selectedStates=find_SS(oldSS,selectedStates,z_curr[1],z_prev,lapStatus,modelParams,mpcParams_4s,track)
                    selectedStates.selStates=s6_to_s4(selectedStates.selStates)
                    # println(selectedStates)
                	(mpcSol.z,mpcSol.u,sol_status) = solveMpcProblem_convhull_kin(mdl_kin,mpcSol,z_kin,z_prev,u_prev,selectedStates,track,GP_e_vy,GP_e_psidot)
                    println(mpcSol.u)
                    toc()
                
                end # end of IF:IDEN_MODEL/DYN_LIN_MODEL/IDEN_KIN_LIN_MODEL

                # COLLECT ONE STEP PREDICTION ERROR FOR GPR 
                if !GP_LOCAL_FLAG && !GP_FULL_FLAG && lapStatus.currentIt>1
                    feature_GP_z[k,:]       = solHistory.z[lapStatus.currentIt-1,lapStatus.currentLap,1,:]
                    feature_GP_u[k,:]       = u_prev[1,:]
                    feature_GP_vy_e[k]      = z_curr[5]-solHistory.z[lapStatus.currentIt-1,lapStatus.currentLap,2,5]
                    feature_GP_psidot_e[k]  = z_curr[6]-solHistory.z[lapStatus.currentIt-1,lapStatus.currentLap,2,6]
                    k += 1 
                end
                
                # BACK-UP FOR POSSIBLE NON-OPTIMAL SOLUTION
                # sol_status_dummy = "$sol_status"
                # if sol_status_dummy[1] != 'O'
                #     mpcSol.u=copy(u_prev)
                #     if LMPC_FLAG || LMPC_DYN_FLAG
                #         (mpcSol.z,~,~)=car_pre_dyn(z_curr,mpcSol.u,track,modelParams,6)
                #     else
                #         (mpcSol.z,~,~)=car_pre_dyn(z_curr,mpcSol.u,track,modelParams,4)
                #     end
                # end 
            end # end of IF:pF/LMPC
            # tic()
            # DATA WRITING AND COUNTER UPDATE
            # log_cvx[lapStatus.currentIt,:,:,lapStatus.currentLap]   = mpcCoeff.c_Vx       
            # log_cvy[lapStatus.currentIt,:,:,lapStatus.currentLap]   = mpcCoeff.c_Vy       
            # log_cpsi[lapStatus.currentIt,:,:,lapStatus.currentLap]  = mpcCoeff.c_Psi

            n_state = size(mpcSol.z,2)

            mpcSol.a_x = mpcSol.u[1+mpcParams.delay_a,1] 
            mpcSol.d_f = mpcSol.u[1+mpcParams.delay_df,2]

            mpcSol.a_x = mpcSol.u[1,1]
            mpcSol.d_f = mpcSol.u[1,2]
            if length(mpcSol.df_his)==1
                mpcSol.df_his[1] = mpcSol.u[1+mpcParams.delay_df,2]
            else
                # INPUT DELAY HISTORY UPDATE
                mpcSol.df_his[1:end-1] = mpcSol.df_his[2:end]
                mpcSol.df_his[end] = mpcSol.u[1+mpcParams.delay_df,2]
            end

            if length(mpcSol.a_his)==1
                mpcSol.a_his[1] = mpcSol.u[1+mpcParams.delay_a,1]
            else
                # INPUT DELAY HISTORY UPDATE
                mpcSol.a_his[1:end-1] = mpcSol.a_his[2:end]
                mpcSol.a_his[end] = mpcSol.u[1+mpcParams.delay_a,1]
            end
            
            if (PF_FLAG || (!PF_FLAG && lapStatus.currentLap > 1+max(selectedStates.feature_Nl,selectedStates.Nl)))
                # println("saving history data")
                if counter >= 5
                    solHistory.z[lapStatus.currentIt,lapStatus.currentLap,:,1:n_state]=mpcSol.z
                    solHistory.z[lapStatus.currentIt,lapStatus.currentLap,1,4:6]=z_curr[4:6]  # [z_est[1],z_est[2],z_est[3]] # THIS LINE IS REALLY IMPORTANT FOR SYS_ID FROM pF
                    # solHistory.z[lapStatus.currentIt,lapStatus.currentLap,1,4:6]=[z_true[3],z_true[4],z_true[6]] # THIS LINE IS REALLY IMPORTANT FOR SYS_ID FROM pF
                    solHistory.u[lapStatus.currentIt,lapStatus.currentLap,:,:]=mpcSol.u

                    # SAFESET DATA SAVING BASED ON CONTROLLER'S FREQUENCY
                    oldSS.oldSS[lapStatus.currentIt,:,lapStatus.currentLap]=z_curr # [z_est[6],z_est[5],z_est[4],z_est[1],z_est[2],z_est[3]]
                    # oldSS_true.oldSS[lapStatus.currentIt,:,lapStatus.currentLap]=xyFrame_to_trackFrame(z_true,track)
                    oldSS.cost2target[lapStatus.currentIt,lapStatus.currentLap]=lapStatus.currentIt
                    counter = 0
                    lapStatus.currentIt += 1
                end
            end

            statusHistory[lapStatus.currentIt,lapStatus.currentLap] = "$sol_status"
            if !LMPC_DYN_FLAG && !LMPC_KIN_FLAG && !PF_FLAG && lapStatus.currentLap > 1+max(selectedStates.feature_Nl,selectedStates.Nl) 
                selectFeatureHistory[lapStatus.currentIt,lapStatus.currentLap,:,:] = z_iden_plot
            end
            if (!PF_FLAG && lapStatus.currentLap > 1+max(selectedStates.feature_Nl,selectedStates.Nl))
                if !LMPC_FLAG && !LMPC_DYN_FLAG
                    selectHistory[lapStatus.currentIt,lapStatus.currentLap,:,1:4] = selectedStates.selStates
                else
                    selectHistory[lapStatus.currentIt,lapStatus.currentLap,:,:] = selectedStates.selStates
                end
            end
            if !GP_LOCAL_FLAG || !GP_FULL_FLAG
                GP_vy_History[lapStatus.currentIt,lapStatus.currentLap,:] = GP_e_vy
                GP_psidot_History[lapStatus.currentIt,lapStatus.currentLap,:] = GP_e_psidot
            end

            # VISUALIZATION COORDINATE CALCULATION FOR view_trajectory.jl NODE
            (z_x,z_y) = trackFrame_to_xyFrame(mpcSol.z,track)
            mpcSol_to_pub.z_x = z_x
            mpcSol_to_pub.z_y = z_y
            # println(selectedStates.selStates)
            (SS_x,SS_y) = trackFrame_to_xyFrame(selectedStates.selStates,track)
            mpcSol_to_pub.SS_x = SS_x
            mpcSol_to_pub.SS_y = SS_y
            mpcSol_to_pub.z_vx = mpcSol.z[:,4]
            mpcSol_to_pub.SS_vx = selectedStates.selStates[:,4]
            mpcSol_to_pub.z_s = mpcSol.z[:,1]
            mpcSol_to_pub.SS_s = selectedStates.selStates[:,1]
            # FORECASTING POINTS FROM THE DYNAMIC MODEL
            
            # if length(z_curr)==6
            #     (z_fore,~,~) = car_pre_dyn_true(z_curr,mpcSol.u,track,modelParams,6)
            #     (z_fore_x,z_fore_y) = trackFrame_to_xyFrame(z_fore,track)
            #     mpcSol_to_pub.z_fore_x = z_fore_x
            #     mpcSol_to_pub.z_fore_y = z_fore_y
            # end

            cmd.servo   = convert(Float32,mpcSol.d_f)
            cmd.motor   = convert(Float32,mpcSol.a_x)
            publish(pub, cmd)
            publish(mpcSol_pub, mpcSol_to_pub)

            z_prev      = copy(mpcSol.z)
            u_prev      = copy(mpcSol.u)
            # toc()
            println("$sol_status Current Lap: ", lapStatus.currentLap, ", It: ", lapStatus.currentIt, " v: $(z_est[1])")
            # lapStatus.currentIt += 1
        else
            println("No estimation data received!")
        end
        counter += 1
        println(counter)
        rossleep(loop_rate)
    end # END OF THE WHILE LOOP
    # THIS IS FOR THE LAST NO FINISHED LAP
    solHistory.cost[lapStatus.currentLap]   = lapStatus.currentIt-1
    # DATA SAVING
    run_time = Dates.format(now(),"yyyy-mm-dd-H:M")
    log_path = "$(homedir())/$(folder_name)/LMPC-$(file_name)-$(run_time).jld"
    save(log_path,"log_cvx",log_cvx,"log_cvy",log_cvy,"log_cpsi",log_cpsi,"GP_vy_History",GP_vy_History,"GP_psidot_History",GP_psidot_History,
                  "oldTraj",oldTraj,"selectedStates",selectedStates,"oldSS",oldSS,"solHistory",solHistory,
                  "selectHistory",selectHistory,"selectFeatureHistory",selectFeatureHistory,"statusHistory",statusHistory,
                  "track",track,"modelParams",modelParams,"mpcParams",mpcParams)
    # COLLECT ONE STEP PREDICTION ERROR FOR GPR 
    if !GP_LOCAL_FLAG && !GP_FULL_FLAG
        run_time = Dates.format(now(),"yyyy-mm-dd-H:M")
        if get_param("sim_flag")
	        log_path = "$(homedir())/simulations/Feature_Data/FeatureData_GP-$(file_name).jld"
	    else
	        log_path = "$(homedir())/experiments/Feature_Data/FeatureData_GP-$(file_name).jld"
	    end
        # CUT THE FRONT AND REAR TAIL BEFORE SAVING THE DATA
        feature_GP_z        = feature_GP_z[1:k-1,:]
        feature_GP_u        = feature_GP_u[1:k-1,:]
        feature_GP_vy_e     = feature_GP_vy_e[1:k-1]
        feature_GP_psidot_e = feature_GP_psidot_e[1:k-1]
        save(log_path,"feature_GP_z",feature_GP_z,"feature_GP_u",feature_GP_u,
                      "feature_GP_vy_e",feature_GP_vy_e,"track",track,
                      "feature_GP_psidot_e",feature_GP_psidot_e) 
    end
    println("Exiting LMPC node. Saved data to $log_path.")
end

if ! isinteractive()
    main()
end
