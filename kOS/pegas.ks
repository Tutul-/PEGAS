//	If no boot file was loaded, this check will immediately crash PEGAS, saving time that would otherwise be wasted on loading libraries.
IF NOT (DEFINED vehicle) OR NOT (DEFINED sequence) OR NOT (DEFINED controls) OR NOT (DEFINED mission) {
	PRINT "".
	PRINT "No boot file loaded! Crashing...".
	PRINT "".
	SET _ TO sequence.
	SET _ TO controls.
	SET _ TO vehicle.
	SET _ TO mission.
}

//	Load settings and libraries.
RUN pegas_settings.
IF cserVersion = "new" {
	RUN pegas_cser_new.
} ELSE {
	RUN pegas_cser.
}
RUN pegas_upfg.
RUN pegas_util.
RUN pegas_misc.
RUN pegas_comm.

//	The following is absolutely necessary to run UPFG fast enough.
SET CONFIG:IPU TO kOS_IPU.

//	Initialize global flags and constants
GLOBAL g0 IS 9.8067.				//	PEGAS will launch from any planet or moon - "g0" is a standard constant for thrust computation and shall not be changed!
GLOBAL upfgStage IS -1.				//	Seems wrong (we use "vehicle[upfgStage]") but first run of stageEventHandler increments this automatically
GLOBAL stageEventFlag IS FALSE.
GLOBAL systemEvents IS LIST().
GLOBAL systemEventPointer IS -1.	//	Same deal as with "upfgStage"
GLOBAL systemEventFlag IS FALSE.
GLOBAL userEventPointer IS -1.		//	As above
GLOBAL userEventFlag IS FALSE.
GLOBAL commsEventFlag IS FALSE.
GLOBAL throttleSetting IS 0.		//	This is what actually controls the throttle,
GLOBAL throttleDisplay IS 0.		//	and this is what to display on the GUI - see throttleControl() for details.
GLOBAL steeringVector IS LOOKDIRUP(SHIP:FACING:FOREVECTOR, SHIP:FACING:TOPVECTOR).
GLOBAL steeringRoll IS 0.
GLOBAL upfgConverged IS FALSE.
GLOBAL stagingInProgress IS FALSE.


//	PREFLIGHT ACTIVITIES
//	Update mission struct and set up UPFG target
missionSetup().
SET upfgTarget TO targetSetup().
//	Calculate time to launch
SET currentTime TO TIME.
SET timeToOrbitIntercept TO orbitInterceptTime().
GLOBAL liftoffTime IS currentTime + timeToOrbitIntercept - controls["launchTimeAdvance"].
IF timeToOrbitIntercept < controls["launchTimeAdvance"] { SET liftoffTime TO liftoffTime + SHIP:BODY:ROTATIONPERIOD. }
//	Calculate launch azimuth if not specified
IF NOT mission:HASKEY("launchAzimuth") {
	mission:ADD("launchAzimuth", launchAzimuth()).
}
//	Set up the system for flight
setSystemEvents().		//	Set up countdown messages
setUserEvents().		//	Initialize vehicle sequence
setVehicle().			//	Complete vehicle definition (as given by user)
setComms(). 			//	Setting up communications

// Atmospheric and gravity turn variable
IF SHIP:BODY:ATM:EXISTS {
	SET maxQ TO FALSE.
	SET previousQ TO 0.
	SET broke30s TO FALSE.
	SET turnStart TO ALTITUDE + 100.
	SET turnExponent TO 0.7.
	SET atmoHeight TO SHIP:BODY:ATM:HEIGHT.
	SET turnEnd TO atmoHeight * 0.9.
	SET controls["upfgActivation"] TO 999. // Recalculate UPFG activation later
}

//	PEGAS TAKES CONTROL OF THE MISSION
createUI().
//	Prepare control for vertical ascent
LOCK THROTTLE TO throttleSetting.
LOCK STEERING TO steeringVector.
// -1 = standby (is it really necessary?)
//  0 = vertical launch to clear the tower or to get high enough before pitching
//	1 = commence the gravity turn (simple system best suited for atmospheric flight)
//	2 = hold to prograde and be ready for UPFG initialization
// 666 is an abort sequence and trigger ABORT system
SET ascentFlag TO -1.	//	-1 = standy, 0 = vertical, 1 = gravity turn, 2 = hold prograde, 666 = ABORT!
ON ABORT SET ascentFlag TO 666.
//	Main loop - wait on launch pad, lift-off and passive guidance
UNTIL ABORT {
	//	Sequence handling
	IF systemEventFlag = TRUE { systemEventHandler(). }
	IF   userEventFlag = TRUE {   userEventHandler(). }
	IF  commsEventFlag = TRUE {  commsEventHandler(). }
	
	SET throttleDisplay TO throttleSetting.
	
	IF ascentFlag = -1 {
		// First launch, set throttle to max
		IF SHIP:MAXTHRUST = 0 { SET throttleSetting TO 1. }
		SET ascentFlag TO 0.
	}
	ELSE IF ascentFlag = 0 {
		// The vehicle is going straight up for the first meters
		IF ALTITUDE >= turnStart {
			IF SHIP:BODY:ATM:EXISTS { SET ascentFlag TO 1. }
			ELSE { SET ascentFlag TO 2. }
			textPrint("Gravity turn", 8, 9, 21, "L").
			pushUIMessage( "Starting gravity turn." ).
		}
	}
	ELSE IF ascentFlag = 1 {
		// Ship throttle control
		SET throttleSetting TO max(0.1, min(1, 1 - ((SHIP:DYNAMICPRESSURE * 200) / (SHIP:MASS * (SHIP:BODY:MU / (SHIP:BODY:RADIUS + ALTITUDE) ^ 2))))).
		
		// Display fake MAXQ informations (only find out at the end of that sequence)
		IF NOT maxQ AND previousQ > SHIP:DYNAMICPRESSURE {
			pushUIMessage("Max Q").
			SET maxQ TO TRUE.
		}
		SET previousQ TO  SHIP:DYNAMICPRESSURE.
		
		// Ship pitch control
		SET trajectoryPitch TO max(90-(((ALTITUDE-turnStart)/(turnEnd-turnStart))^turnExponent*90),0).
		SET steerPitch TO trajectoryPitch.
		
		//Keep time to apoapsis > 30s during ascent once it is above 30s
		IF broke30s AND ETA:APOAPSIS < 30 SET steerPitch TO steerPitch+(30-ETA:APOAPSIS).
		ELSE IF ETA:APOAPSIS > 30 AND NOT broke30s SET broke30s TO TRUE.
		
		// Ship compass heading control
		IF ABS(SHIP:OBT:INCLINATION - ABS(mission["inclination"])) > 2 {
			SET steerHeading TO mission["launchAzimuth"].
		}
		ELSE { // Feedback loop once close to desired inclination
			IF mission["inclination"] >= 0 {
				IF VANG(VXCL(SHIP:UP:VECTOR, SHIP:FACING:VECTOR), SHIP:NORTH:VECTOR) <= 90 {
					SET steerHeading TO (90-mission["inclination"]) - 2*(ABS(mission["inclination"]) - SHIP:OBT:INCLINATION).
				}
				ELSE {
					SET steerHeading TO (90-mission["inclination"]) + 2*(ABS(mission["inclination"]) - SHIP:OBT:INCLINATION).
				}.
			}
			ELSE IF mission["inclination"] < 0 {
				SET steerHeading TO (90-mission["inclination"]) + 2*(ABS(mission["inclination"]) - SHIP:OBT:INCLINATION).
			}.
		}.
		
		SET ascentSteer TO HEADING(steerHeading, steerPitch).
		
		// Don't pitch too far off surface prograde while under high dynamic pressure
		IF SHIP:Q > 0 SET angleLimit TO MAX(3, MIN(90, 5*LN(0.9/SHIP:Q))).
		ELSE SET angleLimit TO 90.
		SET angleToPrograde TO VANG(SHIP:SRFPROGRADE:VECTOR,ascentSteer:VECTOR).
		IF angleToPrograde > angleLimit {
			SET ascentSteerLimited TO (angleLimit/angleToPrograde * (ascentSteer:VECTOR:NORMALIZED - SHIP:SRFPROGRADE:VECTOR:NORMALIZED)) + SHIP:SRFPROGRADE:VECTOR:NORMALIZED.
			SET ascentSteer TO ascentSteerLimited:DIRECTION.
		}.
		SET steeringVector TO ascentSteer.
	
		IF SHIP:VERTICALSPEED > 0 AND (liftoffTime:SECONDS + controls["upfgActivation"]) > 30 {
			LOCAL upfgDelay IS ((turnEnd * 0.9) / SHIP:VERTICALSPEED).
			IF upfgDelay < controls["upfgActivation"] { SET controls["upfgActivation"] TO upfgDelay. }
		}
	}
	ELSE IF ascentFlag = 2 {
		SET velocityAngle TO 90-VANG(SHIP:UP:VECTOR, SHIP:VELOCITY:SURFACE).
		SET steeringVector TO aimAndRoll(HEADING(mission["launchAzimuth"],velocityAngle):VECTOR, steeringRoll).
		pushUIMessage("Holding prograde at " + ROUND(mission["launchAzimuth"],1) + " deg azimuth.", 1, PRIORITY_LOW).
	}
	ELSE IF ascentFlag = 666 {
		UNLOCK STEERING.
		UNLOCK THROTTLE.
		SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
		TOGGLE ABORT.
		BREAK.
	}
	
	// Angle to desired steering > 30deg (i.e. steering control loss)
	IF VANG(SHIP:FACING:VECTOR, steeringVector:VECTOR) > 30 AND TIME:SECONDS >= liftoffTime:SECONDS + 5 {
		SET ascentFlag TO 666.
		pushUIMessage("Ship lost steering control!", 10, PRIORITY_HIGH).
	}
	
	// Abort if falling back toward surface (i.e. insufficient thrust)
	IF SHIP:VERTICALSPEED < -1.0 AND TIME:SECONDS >= liftoffTime:SECONDS + 5 {
		SET ascentFlag TO 666.
		pushUIMessage("Insufficient vertical velocity!", 10, PRIORITY_HIGH).
	}
	
	//	The passive guidance loop ends a few seconds before actual ignition of the first UPFG-controlled stage.
	//	This is to give UPFG time to converge. Actual ignition occurs via stagingEvents.
	IF TIME:SECONDS >= liftoffTime:SECONDS + controls["upfgActivation"] - upfgConvergenceDelay {
		pushUIMessage( "Initiating UPFG..." ).
		BREAK.
	}
	//	UI - recalculate UPFG target solely for printing relative angle
	SET upfgTarget["normal"] TO targetNormal(mission["inclination"], mission["LAN"]).
	refreshUI().
	WAIT 0.
}


//	ACTIVE GUIDANCE
IF NOT ABORT {
	createUI().
	//	Initialize UPFG
	initializeVehicle().
	SET upfgState TO acquireState().
	SET upfgInternal TO setupUPFG().
}
//	Main loop - iterate UPFG (respective function controls attitude directly)
UNTIL ABORT {
	//	Sequence handling
	IF systemEventFlag = TRUE { systemEventHandler(). }
	IF   userEventFlag = TRUE {   userEventHandler(). }
	IF  stageEventFlag = TRUE {  stageEventHandler(). }
	IF  commsEventFlag = TRUE {  commsEventHandler(). }
	//	Update UPFG target and vehicle state
	SET upfgTarget["normal"] TO targetNormal(mission["inclination"], mission["LAN"]).
	SET upfgState TO acquireState().
	//	Iterate UPFG and preserve its state
	SET upfgInternal TO upfgSteeringControl(vehicle, upfgStage, upfgTarget, upfgState, upfgInternal).
	//	Manage throttle, with the exception of initial portion of guided flight (where we're technically still flying the first stage).
	IF upfgStage >= 0 { throttleControl(). }
	//	For the final seconds of the flight, just hold attitude and wait.
	IF upfgConverged AND upfgInternal["tgo"] < upfgFinalizationTime { BREAK. }
	//	UI
	refreshUI().
	WAIT 0.
}
//	Final orbital insertion loop
IF NOT ABORT {
	pushUIMessage( "Holding attitude: burn finalization!" ).
	SET previousTime TO TIME:SECONDS.
}
UNTIL ABORT {
	LOCAL finalizeDT IS TIME:SECONDS - previousTime.
	SET previousTime TO TIME:SECONDS.
	SET upfgInternal["tgo"] TO upfgInternal["tgo"] - finalizeDT.
	IF upfgInternal["tgo"] < finalizeDT { BREAK. }	//	Exit loop before entering the next refresh cycle
													//	We could have done "tgo < 0" but this would mean that the previous loop tgo was 0.01 yet we still didn't break
	refreshUI().
	WAIT 0.
}


//	EXIT
UNLOCK STEERING.
UNLOCK THROTTLE.
SET SHIP:CONTROL:PILOTMAINTHROTTLE TO 0.
WAIT 0.
IF NOT ABORT {
	missionValidation().
}
ELSE {
	pushUIMessage("~~~~~Launch aborted!~~~~~").
	HUDTEXT("Launch Aborted!",5,2,100,RED,False).
}
refreshUI().
WAIT 0.