#import "ChicaGaitEngineBridge.h"

#include "apk_model.h"
#include "pulse_conversion.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <vector>

namespace {

enum class TimedAnimationKind {
    None,
    PoseRamp,
    BodyRamp,
    ShapeRamp,
    CogLean,
};

struct TimedAnimation {
    TimedAnimationKind kind = TimedAnimationKind::None;
    apk_model::BodyState start;
    apk_model::BodyState target;
    std::vector<int> movingLegs;
    apk_model::Pose cogStart;
    apk_model::Pose cogTarget;
    double lift = 0.0;
    double layerBlend = 0.0;
    double durationMs = 1.0;
};

struct Engine {
    apk_model::RobotConfig config = apk_model::makeDefaultConfig();
    apk_model::WalkState state;
    std::array<apk_model::Pose, 4> layers = {};
    TimedAnimation timed;
    apk_model::Pose setVelocity;
    double sweepAngle = 0.0;
    double sweepDR = 0.0;
    double sweepDS = 0.0;
    std::array<int, 18> lastPulses = {};
    // Persistent last-committed joint angles per leg. Active legs are refreshed
    // every IK flush; PARKED (disabled) legs keep their frozen tuck angles
    // because inverseKinematics skips inactive legs. Forward-kinematics off this
    // array re-seats the feet on leg re-enable (original z0.a.a(null)->z0.j.a()),
    // fixing the parked legs' stale stored world position after the body has
    // drifted during a walk.
    std::array<std::array<double, 3>, 6> lastAngles = {};
    // Which legs are active (used). Hexapod = all 6; quad = the 4 enabled legs.
    // walkStep needs this so body IK only solves the active legs (parked legs
    // are tucked at disabled-Z and unreachable, which otherwise makes every
    // body-translation IK fail -> no travel) and so the gait-20 remap targets
    // the correct legs. Mirrors the original z0.a.c()/f7054d enabled mask.
    std::array<bool, 6> activeLegs = {true, true, true, true, true, true};
    apk_model::BodyState walkLayerFadeBody;
    bool walkLayerFadeActive = false;

    Engine()
    {
        apk_model::initializeWalkState(config, state);
        lastPulses.fill(1500);
        for (auto& a : lastAngles) a = {0.0, 90.0, 120.0};
    }
};

int apkGaitFromJava(int javaGait)
{
    if (javaGait == 20) return 20;  // quad gait (Quad phase table)
    if (javaGait >= 5 && javaGait <= 10) return javaGait;
    switch (javaGait) {
        case 2: return 9;
        case 3: return 6;
        case 4: return 7;
        default: return 5;
    }
}

std::array<int, 18> toPulses(const std::array<std::array<double, 3>, 6>& angles)
{
    std::array<int, 18> pulses = {};
    const ChicaServoConfig& cfg = chica_apk_servo_config();
    for (int leg = 0; leg < 6; ++leg) {
        for (int joint = 0; joint < 3; ++joint) {
            int pin = cfg.pin[leg][joint];
            pulses[pin] = chica_apk_angle_to_pulse(angles[leg][joint], leg, joint);
        }
    }
    return pulses;
}

std::array<int, 18> toPulsesFromPose(Engine& engine)
{
    // Seed from the persisted angles so PARKED legs (skipped by IK below) keep
    // their frozen tuck angles; the IK refreshes only the active legs.
    std::array<std::array<double, 3>, 6> angles = engine.lastAngles;
    // Use the active-leg mask, not all-true: in quad the 2 disabled legs are
    // parked/tucked at disabled-Z and do NOT translate with the gait, so once
    // the body walks forward they become unreachable and an all-true IK fails,
    // making this return the previous pulses forever (the quad "stall"/freeze).
    // The original solves IK only over the enabled legs (z0.a.c()/f7054d).
    std::array<bool, 6> active = engine.activeLegs;
    apk_model::Pose combined = {};
    for (const auto& layer : engine.layers) {
        combined = apk_model::addPose(combined, layer);
    }
    // Quad CoG layer (original layer[2]) lives in the walk state; include it in
    // the combined flush like the original j.e does with all four layers.
    combined = apk_model::addPose(combined, engine.state.cog_layer);
    engine.state.animation_layer = combined;
    if (!apk_model::inverseKinematics(engine.config, engine.state.body, combined, active, angles)) {
        return engine.lastPulses;
    }
    engine.lastAngles = angles;  // persist (active refreshed, parked legs preserved)
    engine.lastPulses = toPulses(angles);
    return engine.lastPulses;
}

std::vector<int> allLegsVector()
{
    return std::vector<int>(apk_model::ApkLegOrder.begin(), apk_model::ApkLegOrder.end());
}

std::array<apk_model::Vec3, 6> neutralFeet(double radius,
                                           double z,
                                           double cornerAngleDeg,
                                           double elongation,
                                           const std::vector<int>& active)
{
    return apk_model::makeNeutralFeet(radius, z, cornerAngleDeg, elongation, active);
}

double poseMagnitude(const apk_model::Vec3& value)
{
    return std::sqrt((value.x * value.x) + (value.y * value.y) + (value.z * value.z));
}

void normalizePoseVectors(apk_model::Pose& pose)
{
    double xyzMag = poseMagnitude(pose.xyz);
    if (xyzMag > 1.0) {
        pose.xyz.x /= xyzMag;
        pose.xyz.y /= xyzMag;
        pose.xyz.z /= xyzMag;
    }
    double uvwMag = poseMagnitude(pose.uvw);
    if (uvwMag > 1.0) {
        pose.uvw.x /= uvwMag;
        pose.uvw.y /= uvwMag;
        pose.uvw.z /= uvwMag;
    }
}

void scalePoseComponents(apk_model::Pose& pose, double scale = 1.0)
{
    pose.xyz.x *= 60.0 * scale;
    pose.xyz.y *= 100.0 * scale;
    pose.xyz.z *= 100.0 * scale;
    pose.uvw.x *= 28.0 * scale;
    pose.uvw.y *= 18.0 * scale;
    pose.uvw.z *= 18.0 * scale;
}

void clampPose(apk_model::Pose& pose, double scale = 1.0)
{
    double x = 60.0 * scale, y = 100.0 * scale, z = 100.0 * scale;
    double u = 28.0 * scale, v = 18.0 * scale, w = 18.0 * scale;
    pose.xyz.x = std::min(x, std::max(-x, pose.xyz.x));
    pose.xyz.y = std::min(y, std::max(-y, pose.xyz.y));
    pose.xyz.z = std::min(z, std::max(-z, pose.xyz.z));
    pose.uvw.x = std::min(u, std::max(-u, pose.uvw.x));
    pose.uvw.y = std::min(v, std::max(-v, pose.uvw.y));
    pose.uvw.z = std::min(w, std::max(-w, pose.uvw.z));
}

void scalePoseInPlace(apk_model::Pose& pose, double amount)
{
    pose.xyz.x *= amount;
    pose.xyz.y *= amount;
    pose.xyz.z *= amount;
    pose.uvw.x *= amount;
    pose.uvw.y *= amount;
    pose.uvw.z *= amount;
}

apk_model::Pose subtractPose(const apk_model::Pose& left, const apk_model::Pose& right)
{
    return {
        {left.xyz.x - right.xyz.x, left.xyz.y - right.xyz.y, left.xyz.z - right.xyz.z},
        {left.uvw.x - right.uvw.x, left.uvw.y - right.uvw.y, left.uvw.z - right.uvw.z},
    };
}

apk_model::Pose lerpPose(const apk_model::Pose& from, const apk_model::Pose& to, double t)
{
    return {
        {
            from.xyz.x + ((to.xyz.x - from.xyz.x) * t),
            from.xyz.y + ((to.xyz.y - from.xyz.y) * t),
            from.xyz.z + ((to.xyz.z - from.xyz.z) * t),
        },
        {
            from.uvw.x + ((to.uvw.x - from.uvw.x) * t),
            from.uvw.y + ((to.uvw.y - from.uvw.y) * t),
            from.uvw.z + ((to.uvw.z - from.uvw.z) * t),
        },
    };
}

apk_model::Vec3 lerpVec(const apk_model::Vec3& from, const apk_model::Vec3& to, double t)
{
    return {
        from.x + ((to.x - from.x) * t),
        from.y + ((to.y - from.y) * t),
        from.z + ((to.z - from.z) * t),
    };
}

void scalePose(apk_model::Pose& pose, double amount)
{
    pose.xyz.x *= amount;
    pose.xyz.y *= amount;
    pose.xyz.z *= amount;
    pose.uvw.x *= amount;
    pose.uvw.y *= amount;
    pose.uvw.z *= amount;
}

apk_model::Pose originalAnimationPose(const Engine& engine, double phase, int animation)
{
    double angle = 3.14159265358979323846 * phase * 2.0;
    apk_model::Pose pose = {};
    switch (animation) {
        case 1:
            pose.xyz.z = (-std::cos(angle) * 60.0) + 30.0;
            pose.uvw.z = std::sin(angle) * 15.0;
            break;
        case 2:
            pose.xyz.x = -std::cos(angle) * 40.0;
            pose.uvw.y = std::sin(angle) * 15.0;
            break;
        case 3:
            pose.xyz.x = -std::cos(angle) * 40.0;
            pose.uvw.x = -std::sin(angle) * 15.0;
            break;
        case 4:
            pose.xyz.y = -std::cos(angle) * 60.0;
            pose.uvw.z = -std::sin(angle) * 15.0;
            break;
        case 5:
            pose.xyz.x = -std::cos(angle) * 40.0;
            pose.uvw.y = std::cos(angle) * 15.0;
            pose.uvw.z = -7.0;
            break;
        case 6:
            pose.xyz.x = -std::cos(angle) * 40.0;
            pose.xyz.y = std::sin(angle) * 50.0;
            break;
        case 7:
            pose.xyz.x = -std::cos(angle) * 40.0;
            pose.xyz.y = std::sin(angle) * 50.0;
            pose.uvw.y = std::cos(angle) * 12.0;
            pose.uvw.z = std::sin(angle) * 12.0;
            break;
        default: {
            // anim0 body bob = half the ENABLED-leg foot-z spread. Excluding
            // disabled legs is essential in quad: they tuck ~65mm above the body
            // and would otherwise inflate the spread ~4x (body rides very high).
            double minZ = 1.7976931348623157E308;
            double maxZ = -1.7976931348623157E308;
            for (int leg : apk_model::ApkLegOrder) {
                if (!engine.activeLegs[leg]) continue;
                minZ = std::min(minZ, engine.state.body.feet[leg].z);
                maxZ = std::max(maxZ, engine.state.body.feet[leg].z);
            }
            if (minZ <= maxZ) pose.xyz.z = (maxZ - minZ) / 2.0;
            break;
        }
    }
    scalePose(pose, 1.0);
    return pose;
}

bool beginPoseRamp(Engine& engine,
                   const std::vector<int>& requested,
                   double threshold,
                   double lift,
                   double layerBlend,
                   double durationMs)
{
    TimedAnimation timed;
    timed.kind = TimedAnimationKind::PoseRamp;
    timed.start = engine.state.body;
    timed.target = timed.start;
    timed.lift = lift;
    timed.layerBlend = layerBlend;
    timed.durationMs = std::max(1.0, durationMs);

    for (int leg : requested) {
        if (leg < 0 || leg >= 6) continue;
        apk_model::Vec3 neutral = apk_model::neutralFootForBody(engine.config, timed.start, {}, leg);
        double dx = neutral.x - timed.start.feet[leg].x;
        double dy = neutral.y - timed.start.feet[leg].y;
        if (threshold < 0.0 || ((dx * dx) + (dy * dy)) > (threshold * threshold)) {
            // Only commit the legs that actually move to neutral. Setting
            // target.feet for legs *inside* the threshold (which stay parked on
            // the servos) would leave state.body recording them at neutral while
            // the hardware holds them where they are. That divergence (up to
            // `threshold` mm) snaps in on the next walk, because beginWalkSession
            // reuses state.body. Legs not moved keep target == start (the actual
            // position), so state.body stays consistent with what was published.
            timed.target.feet[leg] = neutral;
            timed.movingLegs.push_back(leg);
        }
    }

    if (timed.movingLegs.empty()) {
        engine.timed = {};
        return false;
    }
    engine.timed = timed;
    return true;
}

bool beginBodyRamp(Engine& engine, double bodyZ, double durationMs)
{
    TimedAnimation timed;
    timed.kind = TimedAnimationKind::BodyRamp;
    timed.start = engine.state.body;
    timed.target = timed.start;
    timed.target.body.xyz.z = bodyZ;
    timed.durationMs = std::max(1.0, durationMs);
    engine.timed = timed;
    return true;
}

bool beginBodyDeltaRamp(Engine& engine, double bodyZDelta, double durationMs)
{
    TimedAnimation timed;
    timed.kind = TimedAnimationKind::BodyRamp;
    timed.start = engine.state.body;
    timed.target = timed.start;
    timed.target.body.xyz.z += bodyZDelta;
    timed.durationMs = std::max(1.0, durationMs);
    engine.timed = timed;
    return true;
}

bool beginShapeRamp(Engine& engine,
                    double radius,
                    double z,
                    double cornerAngleDeg,
                    double elongation,
                    double durationMs,
                    const std::vector<int>& requested)
{
    TimedAnimation timed;
    timed.kind = TimedAnimationKind::ShapeRamp;
    timed.start = engine.state.body;
    timed.target = timed.start;
    const std::vector<int> allLegs = allLegsVector();
    const std::vector<int>& legs = requested.empty() ? allLegs : requested;
    auto feet = neutralFeet(radius, z, cornerAngleDeg, elongation, allLegs);
    for (int leg : legs) {
        if (leg < 0 || leg >= 6) continue;
        // Place the shape under the *current* body, not at the world origin. The
        // body pose drifts as the robot walks (state.body.body accumulates the
        // travelled distance), so origin-relative neutral feet would drag the
        // legs back toward where the body started — the "block only works at the
        // origin" bug. This mirrors neutralFootForBody (which the home pose ramp
        // uses), so shape ramps land under the body wherever it currently is.
        apk_model::Vec3 foot = feet[leg];
        apk_model::rotateDegrees(foot, timed.start.body.uvw.x, 0.0, 0.0);
        foot.x += timed.start.body.xyz.x;
        foot.y += timed.start.body.xyz.y;
        timed.target.feet[leg] = foot;
    }
    timed.durationMs = std::max(1.0, durationMs);
    engine.timed = timed;
    return true;
}

std::array<int, 18> sampleTimedAnimation(Engine& engine, double elapsedMs)
{
    if (engine.timed.kind == TimedAnimationKind::None) {
        return toPulsesFromPose(engine);
    }

    double elapsed = std::max(0.0, elapsedMs);
    double t = std::min(1.0, elapsed / engine.timed.durationMs);
    apk_model::BodyState next = engine.timed.start;

    if (engine.timed.kind == TimedAnimationKind::CogLean) {
        // p3.a.M single-leg quad branch: layer2 = lerp(start, target, r5.g(t))
        // flushed every frame; the swing ramp follows as a separate phase.
        double eased = std::sin(t * M_PI / 2.0);
        engine.state.cog_layer = lerpPose(engine.timed.cogStart, engine.timed.cogTarget, eased);
        std::array<int, 18> pulses = toPulsesFromPose(engine);
        if (t >= 1.0) {
            engine.state.cog_layer = engine.timed.cogTarget;
            engine.timed = {};
        }
        return pulses;
    }

    if (engine.timed.kind == TimedAnimationKind::PoseRamp) {
        for (int leg : engine.timed.movingLegs) {
            next.feet[leg] = apk_model::swingTrajectory(
                    engine.timed.start.feet[leg],
                    engine.timed.target.feet[leg],
                    t,
                    engine.timed.lift);
        }
        if (engine.timed.layerBlend > 0.0) {
            apk_model::Pose layerTarget = originalAnimationPose(engine, t, 0);
            engine.layers[1] = lerpPose(engine.layers[1], layerTarget, engine.timed.layerBlend);
        }
        engine.state.body = next;
    } else {
        next.body = lerpPose(engine.timed.start.body, engine.timed.target.body, t);
        for (int leg = 0; leg < 6; ++leg) {
            next.feet[leg] = lerpVec(engine.timed.start.feet[leg], engine.timed.target.feet[leg], t);
        }
        engine.state.body = next;
    }

    std::array<int, 18> pulses = toPulsesFromPose(engine);
    if (t >= 1.0) {
        engine.state.body = engine.timed.target;
        engine.timed = {};
    }
    return pulses;
}

std::array<int, 18> stepSetPose(Engine& engine, apk_model::Pose target, double dtMs)
{
    normalizePoseVectors(target);
    scalePoseComponents(target, engine.config.femur_scale);
    apk_model::Pose delta = subtractPose(target, engine.layers[3]);
    scalePoseInPlace(delta, std::max(0.0, dtMs) / 1000.0);
    engine.setVelocity = apk_model::addPose(engine.setVelocity, delta);
    scalePoseInPlace(engine.setVelocity, 0.92);
    engine.layers[3] = apk_model::addPose(engine.layers[3], engine.setVelocity);
    clampPose(engine.layers[3], engine.config.femur_scale);
    return toPulsesFromPose(engine);
}

// Continuous angular sweep set-pose (the original's p3.a.G, worker case 2).
// dive/setrotate/block hold the stick and the body orbits at a speed set by the
// stick magnitude, advancing an angle each step and writing the rotating pose
// into layer 3 directly (no settling integrator). dR/dS are the original's
// aVar.R()/S() (= the primary stick pair). z5 picks the pose form.
std::array<int, 18> stepSetSweep(Engine& engine, double dR, double dS, bool z5, double dtMs,
                               bool filterTarget = true)
{
    // Smooth the stick toward its target (the original's worker lerps the target
    // pose by 0.05 each step before handing it to G), so joystick moves ease in
    // instead of snapping.
    if (filterTarget) {
        engine.sweepDR += 0.05 * (dR - engine.sweepDR);
        engine.sweepDS += 0.05 * (dS - engine.sweepDS);
        dR = engine.sweepDR;
        dS = engine.sweepDS;
    }
    double mag = std::sqrt((dR * dR) + (dS * dS));
    double rate = std::min(1.0, std::max(-1.0, (dR + dS) * 8.0)) * 360.0 * mag;
    engine.sweepAngle += (std::max(0.0, dtMs) / 1000.0) * rate;
    // p3.a.G wraps once, including after an unusually long frame interval.
    if (engine.sweepAngle >= 360.0) engine.sweepAngle -= 360.0;
    else if (engine.sweepAngle < 0.0) engine.sweepAngle += 360.0;
    double a = (engine.sweepAngle * M_PI) / 180.0;
    double sa = std::sin(a);
    double ca = std::cos(a);
    apk_model::Pose p = {};
    if (z5) {
        // dive form: y-translation + z-yaw
        p.xyz = {dR * sa, dS * sa, 0.0};
        p.uvw = {0.0, dR * ca, -dS * ca};
    } else {
        // flex form: circular x/y translation
        p.xyz = {-dS * sa, dS * ca, 0.0};
        p.uvw = {0.0, dR * ca, -dR * sa};
    }
    normalizePoseVectors(p);
    // rotation scale (the original's j.f7126e uses min(R,S) so xyz is uniform 60,
    // not the static set-pose's 60/100/100).
    double sxyz = 60.0 * engine.config.femur_scale;
    double suvw = 18.0 * engine.config.femur_scale;
    p.xyz.x *= sxyz; p.xyz.y *= sxyz; p.xyz.z *= sxyz;
    p.uvw.x *= suvw; p.uvw.y *= suvw; p.uvw.z *= suvw;
    engine.layers[3] = p;
    return toPulsesFromPose(engine);
}

double levelLayerMagnitude(const Engine& engine)
{
    return poseMagnitude(engine.layers[3].xyz) + (poseMagnitude(engine.layers[3].uvw) * 4.0);
}

double layerMagnitude(const apk_model::Pose& pose)
{
    return poseMagnitude(pose.xyz) + (poseMagnitude(pose.uvw) * 4.0);
}

std::array<int, 18> layerFadeContext(Engine& engine, NSMutableArray<NSNumber *> *context,
                                    double amount, bool finish)
{
    if (context.count != 30) return engine.lastPulses;
    std::array<double, 30> c;
    for (NSUInteger i = 0; i < c.size(); ++i) c[i] = context[i].doubleValue;
    apk_model::Pose layer = {{c[0], c[1], c[2]}, {c[3], c[4], c[5]}};
    const double magnitude = layerMagnitude(layer);
    if (finish) layer = {};
    else if (magnitude > 0.0 && amount < magnitude) scalePoseInPlace(layer, (magnitude - amount) / magnitude);
    engine.layers[0] = layer;
    engine.state.body.body = {{c[6], c[7], c[8]}, {c[9], c[10], c[11]}};
    for (int leg = 0; leg < 6; ++leg) engine.state.body.feet[leg] = {c[12 + 3 * leg], c[13 + 3 * leg], c[14 + 3 * leg]};
    c[0] = layer.xyz.x; c[1] = layer.xyz.y; c[2] = layer.xyz.z;
    c[3] = layer.uvw.x; c[4] = layer.uvw.y; c[5] = layer.uvw.z;
    for (NSUInteger i = 0; i < 6; ++i) context[i] = @(c[i]);
    return toPulsesFromPose(engine);
}

double beginWalkLayerFade(Engine& engine)
{
    apk_model::Pose combined = {};
    for (const auto& layer : engine.layers) {
        combined = apk_model::addPose(combined, layer);
    }
    // p3.a.p() folds ALL layers (incl. the quad CoG layer) into the fade.
    combined = apk_model::addPose(combined, engine.state.cog_layer);
    engine.state.cog_layer = {};
    engine.layers = {};
    engine.layers[0] = combined;
    engine.state.animation_layer = combined;
    engine.walkLayerFadeBody = engine.state.body;
    engine.walkLayerFadeActive = true;
    return layerMagnitude(combined);
}

std::array<int, 18> stepWalkLayerFade(Engine& engine, double amount)
{
    if (!engine.walkLayerFadeActive) {
        return toPulsesFromPose(engine);
    }
    engine.state.body = engine.walkLayerFadeBody;
    double magnitude = layerMagnitude(engine.layers[0]);
    if (magnitude > 0.0 && amount < magnitude) {
        scalePoseInPlace(engine.layers[0], (magnitude - std::max(0.0, amount)) / magnitude);
    }
    return toPulsesFromPose(engine);
}

std::array<int, 18> finishWalkLayerFade(Engine& engine)
{
    if (engine.walkLayerFadeActive) {
        engine.state.body = engine.walkLayerFadeBody;
    }
    engine.layers[0] = {};
    engine.state.animation_layer = {};
    engine.walkLayerFadeActive = false;
    return toPulsesFromPose(engine);
}

std::array<int, 18> applyLevelPose(Engine& engine, double x, double y)
{
    engine.layers[3].uvw.y = std::min(30.0, std::max(-30.0, x * 20.0));
    engine.layers[3].uvw.z = std::min(30.0, std::max(-30.0, y * 20.0));
    return toPulsesFromPose(engine);
}

std::array<int, 18> decayLevelPose(Engine& engine, double factor)
{
    scalePoseInPlace(engine.layers[3], factor);
    if (levelLayerMagnitude(engine) <= 0.1) {
        engine.layers[3] = {};
    }
    return toPulsesFromPose(engine);
}

std::array<int, 18> raiseCalibrationFeet(Engine& engine, double deltaZ)
{
    for (int leg : apk_model::ApkLegOrder) {
        engine.state.body.feet[leg].z += deltaZ;
    }
    return toPulsesFromPose(engine);
}

void lowerCalibrationUntouched(Engine& engine, const std::array<bool, 6>& contacted, double deltaZ)
{
    for (int leg : apk_model::ApkLegOrder) {
        if (!contacted[leg]) {
            engine.state.body.feet[leg].z += deltaZ;
        }
    }
}

NSArray<NSNumber *> *toNSArray(const std::array<int, 18>& pulses)
{
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:pulses.size()];
    for (int pulse : pulses) {
        [out addObject:@(pulse)];
    }
    return out;
}

std::vector<int> toIntVector(NSArray<NSNumber *> *legs)
{
    std::vector<int> out;
    if (legs == nil) return allLegsVector();
    for (NSNumber *value in legs) {
        int leg = value.intValue;
        if (leg >= 0 && leg < 6) out.push_back(leg);
    }
    if (out.empty()) return allLegsVector();
    return out;
}

} // namespace

@implementation ChicaGaitEngineBridge {
    Engine *_engine;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _engine = new Engine();
        [self setStockServoConfig];
    }
    return self;
}

- (void)dealloc
{
    delete _engine;
}

- (NSArray<NSNumber *> *)enterConstructorPose
{
    std::array<std::array<double, 3>, 6> angles = {};
    for (int leg = 0; leg < 6; ++leg) {
        angles[leg] = {0.0, 90.0, 120.0};
    }
    _engine->state.initialized = true;
    _engine->state.body = {};
    _engine->state.animation_layer = {};
    _engine->layers = {};
    _engine->timed = {};
    _engine->setVelocity = {};
    _engine->state.phase = 0.0;
    _engine->state.anchors = {};
    _engine->state.anchor_active = {};
    apk_model::forwardKinematics(_engine->config, angles, _engine->state.animation_layer, _engine->state.body);
    _engine->lastPulses = toPulses(angles);
    return toNSArray(_engine->lastPulses);
}

- (NSArray<NSNumber *> *)enterNeutralPoseWithBodyZ:(double)bodyZ
{
    _engine->state.initialized = true;
    _engine->state.body = {};
    _engine->state.body.body.xyz.z = bodyZ;
    _engine->state.body.feet = _engine->config.neutral_feet;
    _engine->state.animation_layer = {};
    _engine->layers = {};
    _engine->timed = {};
    _engine->setVelocity = {};
    _engine->state.phase = 0.0;
    _engine->state.anchors = {};
    _engine->state.anchor_active = {};
    _engine->lastPulses = toPulsesFromPose(*_engine);
    return toNSArray(_engine->lastPulses);
}

- (NSArray<NSNumber *> *)stepWithGait:(NSInteger)gait
                            animation:(NSInteger)animation
                              forward:(double)forward
                               strafe:(double)strafe
                                 turn:(double)turn
                              deltaMs:(double)deltaMs
                       allowNewAnchors:(BOOL)allowNewAnchors
{
    apk_model::WalkCommand command;
    command.forward = forward;
    command.left = strafe;
    command.turn = turn;
    std::array<bool, 6> active = _engine->activeLegs;
    int apkGait = apkGaitFromJava(static_cast<int>(gait));
    _engine->state.animation_layer = _engine->layers[0];
    apk_model::walkStep(_engine->config,
                        _engine->state,
                        command,
                        apkGait,
                        static_cast<int>(animation),
                        deltaMs,
                        allowNewAnchors,
                        active);
    _engine->layers[0] = _engine->state.animation_layer;
    // Emit through the shared all-layers flush (state.body + layer0..3) so a live
    // level or set-pose correction (layer[3]) stays applied *while walking*. The
    // original combines every layer in one servo flush for both walk and stop; a
    // walk-only IK that folds in layer[0] alone makes the overlay correction
    // invisible during the walk and then "pop" in the instant the walk stops
    // (the stop/fade/level paths all use toPulsesFromPose). With no overlay layer
    // active this is identical to the walk-only IK.
    _engine->lastPulses = toPulsesFromPose(*_engine);
    return toNSArray(_engine->lastPulses);
}

- (NSArray<NSNumber *> *)stepSetPoseWithX:(double)x
                                        y:(double)y
                                        z:(double)z
                                        u:(double)u
                                        v:(double)v
                                        w:(double)w
                                  deltaMs:(double)deltaMs
{
    apk_model::Pose target = {{x, y, z}, {u, v, w}};
    _engine->lastPulses = stepSetPose(*_engine, target, deltaMs);
    return toNSArray(_engine->lastPulses);
}

- (NSArray<NSNumber *> *)stepSetSweepWithDR:(double)dR
                                         dS:(double)dS
                                         z5:(BOOL)z5
                                    deltaMs:(double)deltaMs
{
    _engine->lastPulses = stepSetSweep(*_engine, dR, dS, z5 ? true : false, deltaMs);
    return toNSArray(_engine->lastPulses);
}

- (NSArray<NSNumber *> *)clearSetPose
{
    _engine->layers[3] = {};
    _engine->setVelocity = {};
    _engine->sweepAngle = 0.0;
    _engine->sweepDR = 0.0;
    _engine->sweepDS = 0.0;
    _engine->lastPulses = toPulsesFromPose(*_engine);
    return toNSArray(_engine->lastPulses);
}

- (NSArray<NSNumber *> *)stepSetWorkerWithState:(NSMutableArray<NSNumber *> *)localState
                                       target:(NSArray<NSNumber *> *)localTarget
                                    sweepMode:(NSInteger)sweepMode
                                      deltaMs:(double)deltaMs
{
    if (localState.count != 7 || localTarget.count != 6) return toNSArray(_engine->lastPulses);
    std::array<double, 7> state;
    std::array<double, 6> target;
    for (NSUInteger i = 0; i < state.size(); ++i) state[i] = localState[i].doubleValue;
    for (NSUInteger i = 0; i < target.size(); ++i) target[i] = localTarget[i].doubleValue;
    // Calls are serialized on the main actor. Each worker owns its B velocity
    // and G angle while publishing into the same layer 3, like Android.
    const auto savedVelocity = _engine->setVelocity;
    const double savedAngle = _engine->sweepAngle;
    _engine->setVelocity = {{state[0], state[1], state[2]}, {state[3], state[4], state[5]}};
    _engine->sweepAngle = state[6];
    if (sweepMode == 0) {
        _engine->lastPulses = stepSetPose(*_engine,
                {{target[0], target[1], target[2]}, {target[3], target[4], target[5]}}, deltaMs);
    } else {
        _engine->lastPulses = stepSetSweep(*_engine, target[0], target[1], sweepMode == 1, deltaMs, false);
    }
    const auto& v = _engine->setVelocity;
    state = {v.xyz.x, v.xyz.y, v.xyz.z, v.uvw.x, v.uvw.y, v.uvw.z, _engine->sweepAngle};
    for (NSUInteger i = 0; i < state.size(); ++i) localState[i] = @(state[i]);
    _engine->setVelocity = savedVelocity;
    _engine->sweepAngle = savedAngle;
    return toNSArray(_engine->lastPulses);
}

- (void)keepSetPose
{
    // p3.a.N folds the manual layer into layer 0 without emitting a frame.
    _engine->layers[0] = apk_model::addPose(_engine->layers[0], _engine->layers[3]);
    _engine->layers[3] = {};
}

- (NSMutableArray<NSNumber *> *)beginLayerFadeContext
{
    apk_model::Pose combined = {};
    for (const auto& layer : _engine->layers) combined = apk_model::addPose(combined, layer);
    combined = apk_model::addPose(combined, _engine->state.cog_layer);
    _engine->state.cog_layer = {};
    _engine->layers = {};
    _engine->layers[0] = combined;
    const auto& b = _engine->state.body;
    std::array<double, 30> context = {
        combined.xyz.x, combined.xyz.y, combined.xyz.z, combined.uvw.x, combined.uvw.y, combined.uvw.z,
        b.body.xyz.x, b.body.xyz.y, b.body.xyz.z, b.body.uvw.x, b.body.uvw.y, b.body.uvw.z,
    };
    for (int leg = 0; leg < 6; ++leg) {
        context[12 + 3 * leg] = b.feet[leg].x;
        context[13 + 3 * leg] = b.feet[leg].y;
        context[14 + 3 * leg] = b.feet[leg].z;
    }
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:context.size()];
    for (double value : context) [out addObject:@(value)];
    return out;
}

- (NSArray<NSNumber *> *)stepLayerFadeContext:(NSMutableArray<NSNumber *> *)context amount:(double)amount
{
    _engine->lastPulses = layerFadeContext(*_engine, context, amount, false);
    return toNSArray(_engine->lastPulses);
}

- (NSArray<NSNumber *> *)finishLayerFadeContext:(NSMutableArray<NSNumber *> *)context
{
    _engine->lastPulses = layerFadeContext(*_engine, context, 0.0, true);
    return toNSArray(_engine->lastPulses);
}

- (void)reset
{
    apk_model::initializeWalkState(_engine->config, _engine->state);
    _engine->layers = {};
    _engine->timed = {};
    _engine->setVelocity = {};
    toPulsesFromPose(*_engine);
}

- (BOOL)hasActiveWalkAnchors
{
    for (bool active : _engine->state.anchor_active) {
        if (active) return YES;
    }
    return NO;
}

- (void)beginWalkSession
{
    _engine->state.phase = 0.0;
    _engine->state.anchors = {};
    _engine->state.anchor_active = {};
}

- (double)beginWalkLayerFade
{
    return ::beginWalkLayerFade(*_engine);
}

- (NSArray<NSNumber *> *)stepWalkLayerFade:(double)amount
{
    _engine->lastPulses = ::stepWalkLayerFade(*_engine, amount);
    return toNSArray(_engine->lastPulses);
}

- (NSArray<NSNumber *> *)finishWalkLayerFade
{
    _engine->lastPulses = ::finishWalkLayerFade(*_engine);
    return toNSArray(_engine->lastPulses);
}

- (void)configureModeWithRadius:(double)radius
                 cornerAngleDeg:(double)cornerAngleDeg
                      elongation:(double)elongation
                     legSittingZ:(double)legSittingZ
                       swingLift:(double)swingLift
                  walkAnimFactor:(double)walkAnimFactor
{
    [self configureModeWithRadius:radius
                   cornerAngleDeg:cornerAngleDeg
                       elongation:elongation
                      legSittingZ:legSittingZ
                        swingLift:swingLift
                   walkAnimFactor:walkAnimFactor
                             legs:@[@0, @3, @1, @4, @2, @5]];
}

- (void)configureModeWithRadius:(double)radius
                 cornerAngleDeg:(double)cornerAngleDeg
                      elongation:(double)elongation
                     legSittingZ:(double)legSittingZ
                       swingLift:(double)swingLift
                  walkAnimFactor:(double)walkAnimFactor
                            legs:(NSArray<NSNumber *> *)legs
{
    _engine->config.leg_radius = radius;
    _engine->config.corner_leg_angle_deg = cornerAngleDeg;
    _engine->config.elongation = elongation;
    _engine->config.leg_sitting_z = legSittingZ;
    // Per-mode gait params (original j.f7129h / j.f7131j set on mode change).
    _engine->config.swing_lift = swingLift;
    _engine->config.walk_anim_factor = walkAnimFactor;
    std::vector<int> activeVec = toIntVector(legs);
    _engine->config.neutral_feet = neutralFeet(radius, legSittingZ, cornerAngleDeg, elongation, activeVec);
    _engine->activeLegs = {false, false, false, false, false, false};
    for (int leg : activeVec) {
        if (leg >= 0 && leg < 6) _engine->activeLegs[leg] = true;
    }
}

- (void)configureGeometryWithCoxa:(double)coxaLen
                            femur:(double)femurLen
                            tibia:(double)tibiaLen
                           l1ToR1:(double)l1ToR1
                           l1ToL3:(double)l1ToL3
                           l2ToR2:(double)l2ToR2
                   legConnectionZ:(double)legConnectionZ
                      legSittingZ:(double)legSittingZ
{
    apk_model::RobotConfig& c = _engine->config;
    c.coxa_len = coxaLen;
    c.femur_len = femurLen;
    c.tibia_len = tibiaLen;
    c.femur_scale = ((femurLen + 80.0) / 2.0) / 80.0;
    c.l1_to_r1 = l1ToR1;
    c.l1_to_l3 = l1ToL3;
    c.l2_to_r2 = l2ToR2;
    c.leg_connection_z = legConnectionZ;
    c.leg_sitting_z = legSittingZ;

    double hfw = l1ToR1 / 2.0;
    double hl = l1ToL3 / 2.0;
    double hmw = l2ToR2 / 2.0;
    double z = legConnectionZ;
    c.mounts[0] = {-hfw, hl, z};
    c.mounts[1] = {-hmw, 0.0, z};
    c.mounts[2] = {-hfw, -hl, z};
    c.mounts[3] = {hfw, hl, z};
    c.mounts[4] = {hmw, 0.0, z};
    c.mounts[5] = {hfw, -hl, z};

    c.neutral_feet = neutralFeet(c.leg_radius, c.leg_sitting_z, c.corner_leg_angle_deg, c.elongation, allLegsVector());
}

- (void)setServoConfigWithCalibration:(NSArray<NSNumber *> *)calibration
                           coxaAttach:(NSArray<NSNumber *> *)coxaAttach
                          femurAttach:(double)femurAttach
                          tibiaAttach:(double)tibiaAttach
                                 pins:(NSArray<NSNumber *> *)pins
{
    if (calibration.count < 36 || coxaAttach.count < 6 || pins.count < 18) {
        return;
    }
    ChicaServoConfig cfg{};
    for (int leg = 0; leg < 6; ++leg) {
        cfg.coxaAttach[leg] = coxaAttach[leg].doubleValue;
        for (int joint = 0; joint < 3; ++joint) {
            int idx = leg * 3 + joint;
            cfg.calibration[leg][joint][0] = calibration[idx * 2].intValue;
            cfg.calibration[leg][joint][1] = calibration[idx * 2 + 1].intValue;
            cfg.pin[leg][joint] = pins[idx].intValue;
        }
    }
    cfg.femurAttach = femurAttach;
    cfg.tibiaAttach = tibiaAttach;
    chica_apk_set_servo_config(cfg);
}

- (void)setStockServoConfig
{
    ChicaServoConfig cfg{};
    const int defaultPins[6][3] = {
        {15, 16, 17}, {9, 10, 11}, {3, 4, 5},
        {12, 13, 14}, {6, 7, 8}, {0, 1, 2},
    };
    const double coxaAttach[6] = {-8.0, 0.0, 8.0, -8.0, 0.0, 8.0};
    for (int leg = 0; leg < 6; ++leg) {
        cfg.coxaAttach[leg] = coxaAttach[leg];
        for (int joint = 0; joint < 3; ++joint) {
            cfg.calibration[leg][joint][0] = 2000;
            cfg.calibration[leg][joint][1] = 1000;
            cfg.pin[leg][joint] = defaultPins[leg][joint];
        }
    }
    cfg.femurAttach = 35.0;
    cfg.tibiaAttach = 68.0;
    chica_apk_set_servo_config(cfg);
}

- (BOOL)beginCogLeanRampWithLeg:(NSInteger)leg durationMs:(double)durationMs
{
    apk_model::Vec3 delta{};
    if (!apk_model::quadCogLeanDelta(_engine->state.body, _engine->activeLegs,
                                     static_cast<int>(leg), delta)) {
        return NO;
    }
    _engine->timed = {};
    _engine->timed.kind = TimedAnimationKind::CogLean;
    _engine->timed.cogStart = _engine->state.cog_layer;
    _engine->timed.cogTarget = _engine->state.cog_layer;
    _engine->timed.cogTarget.xyz.x = delta.x;
    _engine->timed.cogTarget.xyz.y = delta.y;
    _engine->timed.durationMs = std::max(1.0, durationMs);
    return YES;
}

- (NSArray<NSNumber *> *)sampleTimedAnimation:(double)elapsedMs
{
    _engine->lastPulses = sampleTimedAnimation(*_engine, elapsedMs);
    return toNSArray(_engine->lastPulses);
}

- (BOOL)beginPoseRampToNeutralWithLegs:(NSArray<NSNumber *> *)legs
                             threshold:(double)threshold
                                  lift:(double)lift
                            layerBlend:(double)layerBlend
                            durationMs:(double)durationMs
{
    return beginPoseRamp(*_engine, toIntVector(legs), threshold, lift, layerBlend, durationMs) ? YES : NO;
}

- (BOOL)beginBodyZRamp:(double)bodyZ durationMs:(double)durationMs
{
    return beginBodyRamp(*_engine, bodyZ, durationMs) ? YES : NO;
}

- (BOOL)beginBodyZDeltaRamp:(double)bodyZDelta durationMs:(double)durationMs
{
    return beginBodyDeltaRamp(*_engine, bodyZDelta, durationMs) ? YES : NO;
}

- (BOOL)beginShapeRampWithRadius:(double)radius
                               z:(double)z
                  cornerAngleDeg:(double)cornerAngleDeg
                      elongation:(double)elongation
                      durationMs:(double)durationMs
{
    return beginShapeRamp(*_engine, radius, z, cornerAngleDeg, elongation, durationMs, {}) ? YES : NO;
}

- (BOOL)beginShapeRampForLegs:(NSArray<NSNumber *> *)legs
                       radius:(double)radius
                            z:(double)z
               cornerAngleDeg:(double)cornerAngleDeg
                   elongation:(double)elongation
                   durationMs:(double)durationMs
{
    return beginShapeRamp(*_engine, radius, z, cornerAngleDeg, elongation, durationMs, toIntVector(legs)) ? YES : NO;
}

- (void)reseatFeetFromForwardKinematics
{
    // Original z0.a.a(null) -> z0.j.a(): on leg re-enable, recompute EVERY foot
    // from the current servo angles. Active legs round-trip to their existing
    // position; PARKED legs (whose angles were frozen at the tuck while the body
    // drifted through a walk) snap to their real body-framed location. This
    // undoes the parked-leg stale-position drift so a following shape-ramp starts
    // from where the legs physically are.
    apk_model::forwardKinematics(_engine->config, _engine->lastAngles,
                                 _engine->state.animation_layer, _engine->state.body);
}

- (NSArray<NSNumber *> *)legJointPositions
{
    std::array<std::array<apk_model::Vec3, 4>, 6> joints;
    apk_model::forwardKinematicsJoints(_engine->config, _engine->lastAngles,
                                       _engine->state.animation_layer,
                                       _engine->state.body, joints);
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:72];
    for (int leg = 0; leg < 6; ++leg) {
        for (int j = 0; j < 4; ++j) {
            [out addObject:@(joints[leg][j].x)];
            [out addObject:@(joints[leg][j].y)];
            [out addObject:@(joints[leg][j].z)];
        }
    }
    return out;
}

- (NSArray<NSNumber *> *)applyLevelPoseWithX:(double)x y:(double)y
{
    _engine->lastPulses = applyLevelPose(*_engine, x, y);
    return toNSArray(_engine->lastPulses);
}

- (NSArray<NSNumber *> *)decayLevelPose:(double)factor
{
    _engine->lastPulses = decayLevelPose(*_engine, factor);
    return toNSArray(_engine->lastPulses);
}

- (double)levelPoseMagnitude
{
    return levelLayerMagnitude(*_engine);
}

- (NSArray<NSNumber *> *)calibrationRaiseAll:(double)deltaZ
{
    _engine->lastPulses = raiseCalibrationFeet(*_engine, deltaZ);
    return toNSArray(_engine->lastPulses);
}

- (void)beginCalibration
{
    _engine->state.body.body = {};
    _engine->state.body.feet = _engine->config.neutral_feet;
}

- (NSArray<NSNumber *> *)calibrationCurrentPulses
{
    _engine->lastPulses = toPulsesFromPose(*_engine);
    return toNSArray(_engine->lastPulses);
}

- (void)calibrationLowerUntouched:(NSArray<NSNumber *> *)contacted deltaZ:(double)deltaZ
{
    std::array<bool, 6> flags = {};
    for (NSUInteger i = 0; i < contacted.count && i < 6; ++i) {
        flags[i] = contacted[i].boolValue;
    }
    lowerCalibrationUntouched(*_engine, flags, deltaZ);
}

- (NSArray<NSNumber *> *)calibrationPoseTargetPulses
{
    std::array<int, 18> target = {};
    target.fill(1500);
    const ChicaServoConfig& cfg = chica_apk_servo_config();
    const double angles[3] = {0.0, 90.0, 90.0};
    for (int leg = 0; leg < 6; ++leg) {
        for (int joint = 0; joint < 3; ++joint) {
            int pin = cfg.pin[leg][joint];
            target[pin] = chica_apk_angle_to_pulse(angles[joint], leg, joint);
        }
    }
    return toNSArray(target);
}

@end
