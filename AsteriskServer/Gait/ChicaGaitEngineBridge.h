#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ChicaGaitEngineBridge : NSObject

- (NSArray<NSNumber *> *)enterConstructorPose;
- (NSArray<NSNumber *> *)enterNeutralPoseWithBodyZ:(double)bodyZ NS_SWIFT_NAME(enterNeutralPose(bodyZ:));
- (NSArray<NSNumber *> *)stepWithGait:(NSInteger)gait
                            animation:(NSInteger)animation
                              forward:(double)forward
                               strafe:(double)strafe
                                 turn:(double)turn
                             deltaMs:(double)deltaMs
                      allowNewAnchors:(BOOL)allowNewAnchors;
- (NSArray<NSNumber *> *)stepSetPoseWithX:(double)x
                                        y:(double)y
                                        z:(double)z
                                        u:(double)u
                                        v:(double)v
                                        w:(double)w
                                  deltaMs:(double)deltaMs NS_SWIFT_NAME(stepSetPose(x:y:z:u:v:w:deltaMs:));
- (NSArray<NSNumber *> *)stepSetSweepWithDR:(double)dR
                                         dS:(double)dS
                                         z5:(BOOL)z5
                                    deltaMs:(double)deltaMs NS_SWIFT_NAME(stepSetSweep(dR:dS:z5:deltaMs:));
- (NSArray<NSNumber *> *)clearSetPose;
// Worker-local velocity and sweep angle (7 values); target axes x,y,z,u,v,w.
- (NSArray<NSNumber *> *)stepSetWorkerWithState:(NSMutableArray<NSNumber *> *)state
                                       target:(NSArray<NSNumber *> *)target
                                    sweepMode:(NSInteger)sweepMode
                                      deltaMs:(double)deltaMs NS_SWIFT_NAME(stepSetWorker(state:target:sweepMode:deltaMs:));
- (void)keepSetPose;
// Each fade owns a snapshot of its layer, body and feet (30 values).
- (NSMutableArray<NSNumber *> *)beginLayerFadeContext;
- (NSArray<NSNumber *> *)stepLayerFadeContext:(NSMutableArray<NSNumber *> *)context
                                      amount:(double)amount NS_SWIFT_NAME(stepLayerFadeContext(_:amount:));
- (NSArray<NSNumber *> *)finishLayerFadeContext:(NSMutableArray<NSNumber *> *)context;
- (void)reset;
- (BOOL)hasActiveWalkAnchors;
- (void)beginWalkSession;
- (double)beginWalkLayerFade;
- (NSArray<NSNumber *> *)stepWalkLayerFade:(double)amount;
- (NSArray<NSNumber *> *)finishWalkLayerFade;

// Mode placement (radius / corner angle / elongation / sitting Z). The
// legs: variant only re-seats the listed legs (quad mode disabled legs).
- (void)configureModeWithRadius:(double)radius
                 cornerAngleDeg:(double)cornerAngleDeg
                      elongation:(double)elongation
                     legSittingZ:(double)legSittingZ
                       swingLift:(double)swingLift
                  walkAnimFactor:(double)walkAnimFactor;
- (void)configureModeWithRadius:(double)radius
                 cornerAngleDeg:(double)cornerAngleDeg
                      elongation:(double)elongation
                     legSittingZ:(double)legSittingZ
                       swingLift:(double)swingLift
                  walkAnimFactor:(double)walkAnimFactor
                            legs:(NSArray<NSNumber *> *)legs NS_SWIFT_NAME(configureMode(radius:cornerAngleDeg:elongation:legSittingZ:swingLift:walkAnimFactor:legs:));

// Body geometry from chica.config (mirrors ChicaGaitEngine.configureGeometry).
- (void)configureGeometryWithCoxa:(double)coxaLen
                            femur:(double)femurLen
                            tibia:(double)tibiaLen
                           l1ToR1:(double)l1ToR1
                           l1ToL3:(double)l1ToL3
                           l2ToR2:(double)l2ToR2
                   legConnectionZ:(double)legConnectionZ
                      legSittingZ:(double)legSittingZ NS_SWIFT_NAME(configureGeometry(coxa:femur:tibia:l1ToR1:l1ToL3:l2ToR2:legConnectionZ:legSittingZ:));

// Per-servo calibration / attach angles / pin map from chica.config (mirrors
// ChicaGaitEngine.setServoConfig). calibration = 36 ints ([leg*3+joint]*2 +
// {lo,hi}), coxaAttach = 6 doubles, pins = 18 ints ([leg*3+joint]).
- (void)setServoConfigWithCalibration:(NSArray<NSNumber *> *)calibration
                           coxaAttach:(NSArray<NSNumber *> *)coxaAttach
                          femurAttach:(double)femurAttach
                          tibiaAttach:(double)tibiaAttach
                                 pins:(NSArray<NSNumber *> *)pins NS_SWIFT_NAME(setServoConfig(calibration:coxaAttach:femurAttach:tibiaAttach:pins:));
- (void)setStockServoConfig;

// Timed-animation ramps (mirror the ChicaGaitEngine native ramp helpers). begin*
// stage a ramp and return NO when there is nothing to move; sampleTimedAnimation
// produces the frame for a given elapsed time and finalizes at completion.
- (BOOL)beginCogLeanRampWithLeg:(NSInteger)leg
                     durationMs:(double)durationMs NS_SWIFT_NAME(beginCogLeanRamp(leg:durationMs:));
- (NSArray<NSNumber *> *)sampleTimedAnimation:(double)elapsedMs NS_SWIFT_NAME(sampleTimedAnimation(elapsedMs:));
- (BOOL)beginPoseRampToNeutralWithLegs:(NSArray<NSNumber *> *)legs
                             threshold:(double)threshold
                                  lift:(double)lift
                            layerBlend:(double)layerBlend
                            durationMs:(double)durationMs NS_SWIFT_NAME(beginPoseRampToNeutral(legs:threshold:lift:layerBlend:durationMs:));
- (BOOL)beginBodyZRamp:(double)bodyZ durationMs:(double)durationMs NS_SWIFT_NAME(beginBodyZRamp(bodyZ:durationMs:));
- (BOOL)beginBodyZDeltaRamp:(double)bodyZDelta durationMs:(double)durationMs NS_SWIFT_NAME(beginBodyZDeltaRamp(bodyZDelta:durationMs:));
- (BOOL)beginShapeRampWithRadius:(double)radius
                               z:(double)z
                  cornerAngleDeg:(double)cornerAngleDeg
                      elongation:(double)elongation
                      durationMs:(double)durationMs NS_SWIFT_NAME(beginShapeRamp(radius:z:cornerAngleDeg:elongation:durationMs:));
- (BOOL)beginShapeRampForLegs:(NSArray<NSNumber *> *)legs
                       radius:(double)radius
                            z:(double)z
               cornerAngleDeg:(double)cornerAngleDeg
                   elongation:(double)elongation
                   durationMs:(double)durationMs NS_SWIFT_NAME(beginShapeRampForLegs(legs:radius:z:cornerAngleDeg:elongation:durationMs:));
// Re-seat every foot from the current per-leg servo angles via forward
// kinematics. Mirrors the original z0.a.a(null) -> z0.j.a() on leg re-enable:
// parked (disabled) legs stay frozen at their tuck angles while the body drifts
// during a walk, so their stored world position goes stale (~travelled distance
// behind the body). FK snaps them back under the CURRENT body (active legs are
// unchanged). Call before the exit shape-ramp so it starts from the real pose.
- (void)reseatFeetFromForwardKinematics NS_SWIFT_NAME(reseatFeetFromForwardKinematics());

// Level (self-leveling) layer.
- (NSArray<NSNumber *> *)applyLevelPoseWithX:(double)x y:(double)y NS_SWIFT_NAME(applyLevelPose(x:y:));
- (NSArray<NSNumber *> *)decayLevelPose:(double)factor NS_SWIFT_NAME(decayLevelPose(factor:));
- (double)levelPoseMagnitude;

// Calibration (auto leg-height search).
- (void)beginCalibration;
- (NSArray<NSNumber *> *)calibrationRaiseAll:(double)deltaZ NS_SWIFT_NAME(calibrationRaiseAll(deltaZ:));
- (NSArray<NSNumber *> *)calibrationCurrentPulses;
- (void)calibrationLowerUntouched:(NSArray<NSNumber *> *)contacted deltaZ:(double)deltaZ NS_SWIFT_NAME(calibrationLowerUntouched(contacted:deltaZ:));
// Pulses for the calibration constructor pose (angles 0,90,90), honoring config.
- (NSArray<NSNumber *> *)calibrationPoseTargetPulses;

// Full per-leg joint chain in world coordinates for the visualizer, computed
// from the CURRENT pose via forward kinematics. Returns 72 numbers, leg-major:
// for each leg 0..5, four joints (mount, hip, knee, foot) as x, y, z.
- (NSArray<NSNumber *> *)legJointPositions;

@end

NS_ASSUME_NONNULL_END
